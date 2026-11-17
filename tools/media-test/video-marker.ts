import { createHash } from 'node:crypto';
export interface VideoMarker { fixture: string; direction: 0 | 1; epoch: number; counter: number; sourceTimeUs: number }
const integer = (v: number, max = Number.MAX_SAFE_INTEGER) => Number.isSafeInteger(v) && v >= 0 && v <= max;
export function videoIdentity(marker: VideoMarker): string {
  videoBytes(marker);
  return JSON.stringify([marker.fixture.toLowerCase(), marker.direction, marker.epoch, marker.counter, marker.sourceTimeUs]);
}
function videoBytes(m: VideoMarker): Buffer {
  if (!/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(m.fixture) || ![0, 1].includes(m.direction) ||
      !integer(m.epoch, 0xffffffff) || !integer(m.counter, 0xffffffff) || !integer(m.sourceTimeUs)) throw Error('Invalid video marker');
  const b = Buffer.alloc(44); b.set([0x56, 0x4d, 1]); b.set(Buffer.from(m.fixture.replaceAll('-', ''), 'hex'), 3);
  b[19] = m.direction; b.writeUInt32BE(m.epoch, 20); b.writeUInt32BE(m.counter, 24); b.writeBigUInt64BE(BigInt(m.sourceTimeUs), 28);
  b.set(createHash('sha256').update(b.subarray(0, 36)).digest().subarray(0, 8), 36); return b;
}
/** Same centered 24×20 marker and digest as the portable Swift VideoMarker. */
export function videoLuma(marker: VideoMarker, width = 160, height = 120): Uint8Array {
  dimensions(width, height, width);
  const bytes = videoBytes(marker), pixels = new Uint8Array(width * height).fill(128);
  const cell = Math.floor(Math.min(width / 24, height / 20)), left = Math.floor((width - cell * 24) / 2), top = Math.floor((height - cell * 20) / 2);
  for (let i = 0; i < 480; i++) {
    const bit = i < 352 ? (bytes[Math.floor(i / 8)]! >> (7 - i % 8)) & 1 : i % 2;
    for (let y = 0; y < cell; y++) pixels.fill(bit ? 235 : 16,
      (top + Math.floor(i / 24) * cell + y) * width + left + i % 24 * cell,
      (top + Math.floor(i / 24) * cell + y) * width + left + (i % 24 + 1) * cell);
  }
  return pixels;
}
function dimensions(width: number, height: number, stride: number) {
  if (!integer(width, 1920) || width < 144 || !integer(height, 1080) || height < 120 ||
      !integer(stride, 16384) || stride < width) throw Error('Invalid video geometry');
}
export function decodeVideoMarker(luma: Uint8Array, width: number, height: number, stride = width): VideoMarker {
  dimensions(width, height, stride); if (luma.length < stride * height) throw Error('Partial video plane');
  const b = Buffer.alloc(44), cell = Math.floor(Math.min(width / 24, height / 20));
  const left = Math.floor((width - cell * 24) / 2), top = Math.floor((height - cell * 20) / 2);
  for (let i = 0; i < 480; i++) {
    const x = left + i % 24 * cell + Math.floor(cell / 2), y = top + Math.floor(i / 24) * cell + Math.floor(cell / 2);
    let sum = 0; for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) sum += luma[(y + dy) * stride + x + dx]!;
    const value = Math.floor(sum / 9); if (value > 64 && value < 192) throw Error('Unreadable video cell');
    const bit = value >= 192 ? 1 : 0;
    if (i < 352) b[Math.floor(i / 8)]! |= bit << (7 - i % 8); else if (bit !== i % 2) throw Error('Invalid video orientation');
  }
  if (!b.subarray(0, 3).equals(Buffer.from([0x56, 0x4d, 1])) ||
      !b.subarray(36).equals(createHash('sha256').update(b.subarray(0, 36)).digest().subarray(0, 8))) throw Error('Invalid video digest');
  const id = b.subarray(3, 19).toString('hex');
  const marker = { fixture: `${id.slice(0, 8)}-${id.slice(8, 12)}-${id.slice(12, 16)}-${id.slice(16, 20)}-${id.slice(20)}`,
    direction: b[19] as 0 | 1, epoch: b.readUInt32BE(20), counter: b.readUInt32BE(24), sourceTimeUs: Number(b.readBigUInt64BE(28)) };
  videoBytes(marker); return marker;
}
export interface VideoPlane { width: number; height: number; complete: boolean; minimum: number | null; maximum: number | null; sample: number[] }
export interface VideoImage { kind: 'source' | 'contentFree' | 'ambiguous'; marker?: VideoMarker; y: VideoPlane; u: VideoPlane; v: VideoPlane }
function plane(bytes: Uint8Array, width: number, height: number): VideoPlane {
  const complete = width > 0 && height > 0 && bytes.length === width * height;
  let minimum = 255, maximum = 0; if (complete) for (const value of bytes) { minimum = Math.min(minimum, value); maximum = Math.max(maximum, value); }
  return { width, height, complete, minimum: complete ? minimum : null, maximum: complete ? maximum : null, sample: [...bytes.subarray(0, 16)] };
}
/** Packed I420 from rtc-node's decoded VideoFrame, never transport statistics. */
export function inspectVideoImage(data: Uint8Array, width: number, height: number): VideoImage {
  const valid = integer(width, 1920) && width > 0 && integer(height, 1080) && height > 0;
  const ySize = valid ? width * height : 0, cw = valid ? Math.ceil(width / 2) : 0, ch = valid ? Math.ceil(height / 2) : 0, c = cw * ch;
  const y = plane(data.subarray(0, ySize), valid ? width : 0, valid ? height : 0);
  const u = plane(data.subarray(ySize, ySize + c), cw, ch), v = plane(data.subarray(ySize + c), cw, ch);
  const complete = y.complete && u.complete && v.complete && data.length === ySize + 2 * c;
  if (complete) { try { return { kind: 'source', marker: decodeVideoMarker(data, width, height), y, u, v }; } catch { /* Classify original pixels below. */ } }
  const uniform = (p: VideoPlane) => p.complete && p.maximum! - p.minimum! <= 4;
  const sourceGeometry = (width === 160 && height === 120) || (width === 320 && height === 240);
  return { kind: complete && !sourceGeometry && [y, u, v].every(uniform) ? 'contentFree' : 'ambiguous', y, u, v };
}
