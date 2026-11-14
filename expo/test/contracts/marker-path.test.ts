import assert from "node:assert/strict";
import { test } from "node:test";
import { preferMarkerPath } from "../../src/testing/marker-path.ts";

test("equal-movement paths with confidence sums within 1e-9 choose earlier starts", () => {
  const earlier = { movement: 10, sum: 11, starts: [135, 190, 255] };
  const later = { movement: 10, sum: 11 + 5e-10, starts: [135, 200, 255] };
  assert.equal(preferMarkerPath(earlier, later), true);
  assert.equal(preferMarkerPath(later, earlier), false);
});

test("sum differences above 1e-9 keep higher confidence ahead of earlier starts", () => {
  const earlier = { movement: 10, sum: 11, starts: [135, 190, 255] };
  const later = { movement: 10, sum: 11 + 2e-9, starts: [135, 200, 255] };
  assert.equal(preferMarkerPath(earlier, later), false);
  assert.equal(preferMarkerPath(later, earlier), true);
});

test("movement remains the first criterion and identical ranks retain the incumbent", () => {
  const earlier = { movement: 10, sum: 11, starts: [135, 190, 255] };
  assert.equal(preferMarkerPath(earlier, { ...earlier, movement: 11, sum: 12 }), true);
  assert.equal(preferMarkerPath(earlier, earlier), false);
});
