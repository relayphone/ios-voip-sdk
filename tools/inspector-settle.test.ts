import assert from 'node:assert/strict';
import { test } from 'node:test';
import { idleCPU, intelligenceService, settleHost, settleStreak, stopIntelligenceService } from './inspector-settle.ts';

// Selected Apple service rows captured from /bin/launchctl list on macOS.
const launchctlSample = `PID\tStatus\tLabel
-\t0\tcom.apple.SafariHistoryServiceAgent
-\t-9\tcom.apple.progressd
42454\t-9\tcom.apple.intelligencetasksd`;

test('parses the captured launchctl list with tabs and negative exit status', () => {
  assert.equal(intelligenceService(launchctlSample), 'com.apple.intelligencetasksd');
});

test('disables the service before bootout using the runtime binary, retaining the list capture', () => {
  const operations: string[] = [];
  const messages: string[] = [];
  let captured = '';
  stopIntelligenceService('source-id', message => messages.push(message), (command, args, options) => {
    assert.equal(command, 'xcrun');
    assert.equal(options?.timeout, 30);
    assert.deepEqual(args.slice(0, 4), ['simctl', 'spawn', 'source-id', '/bin/launchctl']);
    operations.push(args[4]!);
    if (args[4] === 'list') return launchctlSample;
    assert.equal(args[5], 'system/com.apple.intelligencetasksd');
    return '';
  }, output => { captured = output; });
  assert.deepEqual(operations, ['list', 'disable', 'bootout']);
  assert.equal(captured, launchctlSample);
  assert.match(messages.join('\n'), /disable com.apple.intelligencetasksd succeeded/);
  assert.match(messages.join('\n'), /bootout com.apple.intelligencetasksd succeeded/);
});

test('a failed disable still attempts bootout, and missing services or lookup errors only warn', () => {
  const operations: string[] = [];
  const messages: string[] = [];
  stopIntelligenceService('source-id', message => messages.push(message), (_command, args) => {
    operations.push(args[4]!);
    if (args[4] === 'list') return launchctlSample;
    if (args[4] === 'disable') throw new Error('disable unavailable');
    return '';
  });
  assert.deepEqual(operations, ['list', 'disable', 'bootout']);
  assert.match(messages.join('\n'), /warning:intelligencetasksd disable/);
  for (const output of ['PID\tStatus\tLabel', undefined]) {
    stopIntelligenceService('source-id', message => messages.push(message), (_command, args) => {
      assert.equal(args[4], 'list');
      if (output === undefined) throw new Error('lookup unavailable');
      return output;
    });
  }
  assert.match(messages.join('\n'), /service not found/);
  assert.match(messages.join('\n'), /warning:intelligencetasksd lookup/);
});

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
