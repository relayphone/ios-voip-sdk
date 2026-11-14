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

export const insertedDrifts = {
  8000: [0, 0, 0, 10, 10, 10, 20, 20, 30, 30, 30, 33],
  48000: [0, 0, 0, 10, 10, 10, 20, 20, 30, 30, 30, 33],
} as const;
export const deletedDrifts = {
  8000: [0, 0, 0, -7, -7, -7, -7, -7, -7, -7, -7, -7],
  48000: [0, 0, 0, -7, -7, -7, -7, -7, -7, -7, -7, -7],
} as const;
export const overCapDrifts = [0, 0, 10, 20, 30, 40, 50, 60, 60, 70, 70, 80] as const;

export type RepeatedVariant = "deleted" | "wrong" | "silent" | "alias";
/** Received continuous-tone run with a deterministic low-level render residual. */
export function repeatedVector(rate: 8000 | 48000, variant: RepeatedVariant): Float32Array {
  if (variant === "alias") {
    const marker = createMarker("wrong-each-slot"), pcm = emissionSamples(marker, rate, rate / 50 * 51);
    for (let index = rate * 81 / 100; index < rate * 87 / 100; index++)
      pcm[index] = 0.2 * Math.sin(2 * Math.PI * 950 * index / rate);
    return pcm;
  }
  const marker = createMarker("repeat-v2-8233"), pcm = emissionSamples(marker, rate, rate / 50 * 51);
  // Model the received repeated 650 Hz run without intra-run amplitude notches.
  // Source marker/emission generation and parity remain unchanged.
  for (let index = rate * 39 / 100; index < rate * 81 / 100; index++)
    pcm[index] = 0.2 * Math.sin(2 * Math.PI * 650 * (index - rate * 39 / 100) / rate);
  const position = rate * 675 / 1000, count = rate / 100, fade = rate / 400;
  const next = new Float32Array(pcm.length - count);
  next.set(pcm.subarray(0, position));
  next.set(pcm.subarray(position + count), position);
  for (let index = 0; index < fade; index++) {
    const weight = index / (fade - 1);
    next[position + index] = (1 - weight) * pcm[position + index]! + weight * next[position + index]!;
  }
  // A 400 Hz residual with slowly increasing gain makes local confidence maxima
  // move backwards through the run. A complete path retains its entry alignment.
  for (let index = 0; index < next.length; index++)
    next[index] = next[index]! + 0.002 * (1 + index / next.length) * Math.sin(2 * Math.PI * 400 * index / rate);
  if (variant === "wrong") {
    for (let index = rate * 80 / 100; index < rate * 86 / 100; index++)
      next[index] = 0.2 * Math.sin(2 * Math.PI * 1350 * index / rate);
  } else if (variant === "silent") next.fill(0, rate * 63 / 100, rate * 68 / 100);
  return next;
}

export const repeatedVectors = [
  { rate: 8000, variant: "deleted",
    sha256: "dae143f33211f6fcf9617e2e4a99de5e00831e168adafa8a7b2d8fa041811a0b" },
  { rate: 8000, variant: "wrong",
    sha256: "236233ac4ebee517862f86fda82eb5e9fe38b2168a42fd90df090ce837c0199f" },
  { rate: 8000, variant: "silent",
    sha256: "2ec6a4f8d98a1a85d5aa0bb29bd5f707c0dfd7102a78190761da7e8d19ba1531" },
  { rate: 8000, variant: "alias",
    sha256: "35770229b8db7382e249035c555d399962bcedf12cdcbd86d10367a1953a4b5e" },
  { rate: 48000, variant: "deleted",
    sha256: "67c9aaf0dc8265d63d8981ad26e800673597647ccd0bedbfe04596ee73cb9bb0" },
  { rate: 48000, variant: "wrong",
    sha256: "4afd4bfc1fe255d655c19391cc60f18e8ec95c91f04fef7a9bb059c28f9a34ea" },
  { rate: 48000, variant: "silent",
    sha256: "2f7c12aecbb02fe41c280d382587dbd7f907cb433c08483b8bfef50fdd12673c" },
  { rate: 48000, variant: "alias",
    sha256: "b94c47f58ff2975a232ef00c4f2b0b13f41b92aae53c077cfeb102d04737d612" },
] as const;
