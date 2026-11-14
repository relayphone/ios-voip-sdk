import { createMarker, emissionSamples } from "../../src/testing/marker.ts";

/** Canonical pitch-preserving splice vectors; positions refer to the original emission. */
export function detectionVector(rate: 8000 | 48000, changeMs: -40 | 40 | 80): Float32Array {
  const slots = changeMs === 80 ? [1, 2, 3, 4, 5, 6, 8, 10] : [2, 5, 8, 10];
  const marker = createMarker("parity-v2");
  let pcm = emissionSamples(marker, rate, rate / 50 * 51), shift = 0;
  const count = rate / 100, fade = rate / 400;
  for (const slot of slots) {
    const position = rate * 3 / 20 + slot * rate * 3 / 50 + rate * 9 / 200 + shift;
    const next = new Float32Array(pcm.length + (changeMs > 0 ? count : -count));
    next.set(pcm.subarray(0, position));
    if (changeMs > 0) {
      next.set(pcm.subarray(position - count, position), position);
      next.set(pcm.subarray(position), position + count);
    } else next.set(pcm.subarray(position + count), position);
    // Preserve exactly +/-10 ms. Fade the first 2.5 ms after the join in place,
    // from the unedited continuation to the incoming segment. No overlap is removed.
    // An insertion's second join already has identical continuation on both sides.
    for (let index = 0; index < fade; index++) {
      const weight = index / (fade - 1);
      next[position + index] = (1 - weight) * pcm[position + index]! + weight * next[position + index]!;
    }
    pcm = next;
    shift += changeMs > 0 ? count : -count;
  }
  return pcm;
}

export function pcm16LE(samples: Float32Array): Buffer {
  const bytes = Buffer.alloc(samples.length * 2);
  samples.forEach((value, index) => bytes.writeInt16LE(Math.round(value * 32767), index * 2));
  return bytes;
}

export function decodedPCM16(bytes: Buffer): Float32Array {
  return Float32Array.from({ length: bytes.length / 2 }, (_, index) => bytes.readInt16LE(index * 2) / 32768);
}

export const detectionVectors = [
  { rate: 8000, changeMs: 40, samples: 8480,
    sha256: "8cc156f34b514ad4f15d11420771678c3e0f1e443281e8d374ef86e70839370b" },
  { rate: 8000, changeMs: -40, samples: 7840,
    sha256: "cb31a159001ca9041fe6f1068bec30b77c3941ab467c39587616a4e140d8bdd5" },
  { rate: 8000, changeMs: 80, samples: 8800,
    sha256: "4e1daed9aa5681e48fe244f491ba5cea969ed971a06126cc8557275f49b7f124" },
  { rate: 48000, changeMs: 40, samples: 50880,
    sha256: "9df61e48608381ae9a50b8a297884397c72a18e603d3317926b0fb43d73b176a" },
  { rate: 48000, changeMs: -40, samples: 47040,
    sha256: "02030079b20fcd511fec09037b09d4852ff30fdcd9ca30f86f920d945e95a939" },
  { rate: 48000, changeMs: 80, samples: 52800,
    sha256: "62459596128b7f8e181c8ef1edd5a69039f37fdfa89a03e4f29e12d55aad7c14" },
] as const;

export const insertedDrifts = [0, 0, 0, 10, 10, 10, 20, 20, 20, 30, 30, 40] as const;
export const deletedDrifts = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, -10, -10] as const;
export const overCapDrifts = [0, 0, 10, 20, 30, 40, 50, 60, 60, 70, 70, 80] as const;
