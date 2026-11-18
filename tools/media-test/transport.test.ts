import assert from 'node:assert/strict';
import { test } from 'node:test';
import { cycleTransport, HOST_RECEIVER_STATS_POLL_MS, type TransportSnapshot } from './transport.ts';

const edgeTolerance = 48_000 * HOST_RECEIVER_STATS_POLL_MS / 1000;

// Receiver statistics from the three-marker uplink of GitHub Actions run 44185189024.
// Times are offsets in microseconds from the first report. Packet loss and removals were constant.
const uplink: TransportSnapshot[] = ([
  [2880, 0, 1551, 0], [10080, 122855, 1551, 0], [13440, 246800, 1551, 0],
  [20160, 353189, 1551, 0], [24480, 463436, 1551, 0], [28320, 570345, 1551, 0],
  [35040, 678758, 1551, 0], [40320, 782810, 1551, 0], [44640, 885187, 1551, 0],
  [50400, 992790, 1551, 0], [56640, 1116380, 1551, 0], [60960, 1229715, 1551, 0],
  [66240, 1348986, 1551, 0], [72960, 1459597, 1551, 0], [77760, 1640223, 2157, 0],
  [83040, 1772917, 2157, 0], [88800, 1885680, 2157, 120], [94080, 1991700, 2157, 507],
  [98400, 2096611, 2157, 507], [104160, 2200850, 2157, 507], [108960, 2304792, 2157, 507],
  [114240, 2407554, 2157, 507], [119040, 2510229, 2157, 507], [124320, 2613643, 2157, 507],
  [129600, 2718163, 2157, 507], [134400, 2822880, 2157, 507], [137760, 2925853, 2157, 507],
] as const).map(([sample, timestamp, concealedSamples, insertedSamples]) => ({
  sample, timestamp, concealedSamples, insertedSamples,
  packetsLost: 0, removedSamples: 1644, streamID: 'uplink',
}));

test('hosted uplink replay accepts both edge cycles while rejecting the concealed middle cycle', () => {
  // Bounds include clipped pre-roll and the full post-roll margin, derived from the recorded PCM.
  const bounds = [[0, 42720], [41616, 91536], [87936, 137856]] as const;
  assert.deepEqual(bounds.map(([start, end]) => cycleTransport(uplink, start, end).state),
    ['unavailable', 'impaired', 'unavailable']);
  const cycles = bounds.map(([start, end]) => cycleTransport(uplink, start, end, edgeTolerance));
  assert.deepEqual(cycles.map(cycle => cycle.state), ['clean', 'impaired', 'clean']);
  assert.equal(cycles[1]!.lost, 0);
  assert.equal(cycles[1]!.concealed, 606);
  assert.equal(cycles[1]!.inserted, 507);
});

test('nearest samples need a real and continuous counter interval within one poll of both edges', () => {
  const before = { ...uplink[0]!, sample: edgeTolerance };
  const end = 42_720;
  const after = { ...uplink[1]!, sample: end - edgeTolerance };
  const assess = (rows: TransportSnapshot[]) => cycleTransport(rows, 0, end, edgeTolerance).state;
  assert.equal(assess([before, after]), 'clean');
  assert.equal(assess([{ ...before, sample: before.sample + 1 }, after]), 'unavailable');
  assert.equal(assess([before, { ...after, sample: after.sample - 1 }]), 'unavailable');
  assert.equal(assess([before]), 'unavailable');
  assert.equal(assess([before, { ...after, sample: before.sample }]), 'unavailable');
  assert.equal(assess([before, { ...after, timestamp: before.timestamp }]), 'unavailable');
  assert.equal(assess([before, { ...after, streamID: 'replacement' }]), 'unavailable');
  assert.equal(assess([before, { ...after, concealedSamples: after.concealedSamples - 1 }]), 'unavailable');
  assert.equal(assess([before, { ...after, packetsLost: 1 }]), 'impaired');
  assert.equal(assess([before, { ...after, concealedSamples: after.concealedSamples + 1 }]), 'impaired');
});
