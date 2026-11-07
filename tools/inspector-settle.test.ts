import assert from 'node:assert/strict';
import { test } from 'node:test';
import { idleCPU, intelligenceService, settleHost, settleStreak } from './inspector-settle.ts';

test('uses the second top interval and rejects missing or invalid readings', () => {
  assert.equal(idleCPU('CPU usage: 1% user, 2% sys, 97% idle\nCPU usage: 40.2% user, 29.8% sys, 30.0% idle'), 30);
  assert.equal(idleCPU('CPU usage: 0% user, 0% sys, 100% idle'), undefined);
  assert.equal(idleCPU('unavailable'), undefined);
  assert.equal(idleCPU('CPU usage: 100% idle\nCPU usage: 101% idle'), undefined);
});

test('finds only the intelligencetasksd program in launchctl list, including a stopped service', () => {
  assert.equal(intelligenceService('PID Status Label\n123 0 com.apple.other\n- 78 com.apple.intelligencetasksd\n'),
    'com.apple.intelligencetasksd');
  assert.equal(intelligenceService('123 0 com.apple.intelligencetasksd.helper'), undefined);
  assert.equal(intelligenceService('123 0 com.apple.notintelligencetasksd\n123 0 com.apple.intelligencetasksdOther'), undefined);
  assert.equal(intelligenceService('PID Status Label'), undefined);
});

test('settle rule requires three consecutive valid readings at or above 30%', () => {
  let streak = 0;
  for (const idle of [30, 50, 29.9, 100, undefined, NaN, 101, 30, 30, 30]) {
    streak = settleStreak(streak, idle);
  }
  assert.equal(streak, 3);
  assert.equal(settleStreak(2, undefined), 0);
  assert.equal(settleStreak(2, 29.99), 0);
});

test('settles at three ten-second samples and resets after a failed sample', async () => {
  let time = 0;
  let samples = 0;
  const duration = await settleHost(() => {
    if (++samples === 2) throw new Error('top failed');
    return 30;
  }, () => time, async ms => { time += ms; });
  assert.equal(duration, 50_000);
  assert.equal(samples, 5);
});

test('caps unsettled hosts at ten minutes and also bounds slow sampling', async () => {
  for (const slow of [false, true]) {
    let time = 0;
    await assert.rejects(settleHost(remaining => {
      if (slow) time += remaining;
      return slow ? 100 : 29;
    }, () => time, async ms => { time += ms; }), /within 600s/);
    assert.equal(time, 600_000);
  }
});
