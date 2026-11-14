interface MarkerPathRank {
  readonly movement: number;
  readonly sum: number;
  readonly starts: readonly number[];
}

/** Internal preference shared by DP prefix pruning and final path selection. */
export function preferMarkerPath(left: MarkerPathRank, right: MarkerPathRank): boolean {
  if (left.movement !== right.movement) return left.movement < right.movement;
  if (Math.abs(left.sum - right.sum) > 1e-9) return left.sum > right.sum;
  for (let index = 0; index < left.starts.length; index++) {
    if (left.starts[index] !== right.starts[index]) return left.starts[index]! < right.starts[index]!;
  }
  return false;
}
