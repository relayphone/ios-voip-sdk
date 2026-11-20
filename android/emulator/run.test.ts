import assert from 'node:assert/strict';
import { test } from 'node:test';
import { withEarpiece } from './earpiece.ts';
import { verifyOnEmulator } from './run.ts';

function fixture(bootFailures: number, productFailure?: Error) {
  const events: string[] = [];
  const bootError = new Error('emulator did not warm up');
  const run = () => verifyOnEmulator(
    (attempt) => ({
      async warm() {
        events.push(`warm ${attempt}`);
        if (attempt <= bootFailures) throw bootError;
      },
      async stop() { events.push(`stop ${attempt}`); },
    }),
    () => {
      events.push('verify');
      if (productFailure) throw productFailure;
    },
    (attempt, error) => {
      assert.equal(error, bootError);
      events.push(`report ${attempt}`);
    },
  );
  return { events, bootError, run };
}

test('a ready emulator runs verification once and stops', async () => {
  const { events, run } = fixture(0);
  await run();
  assert.deepEqual(events, ['warm 1', 'verify', 'stop 1']);
});

test('a warm-up failure permits a second boot after teardown', async () => {
  const { events, run } = fixture(1);
  await run();
  assert.deepEqual(events, ['warm 1', 'report 1', 'stop 1', 'warm 2', 'verify', 'stop 2']);
});

test('two warm-up failures fail the job before verification', async () => {
  const { events, bootError, run } = fixture(2);
  await assert.rejects(run, bootError);
  assert.deepEqual(events, ['warm 1', 'report 1', 'stop 1', 'warm 2', 'report 2', 'stop 2']);
});

test('an instrumentation failure is preserved without a retry', async () => {
  const productFailure = new Error('instrumentation assertion failed');
  const { events, run } = fixture(0, productFailure);
  await assert.rejects(run, productFailure);
  assert.deepEqual(events, ['warm 1', 'verify', 'stop 1']);
});

test('the emulator audio policy attaches both built-in outputs', () => {
  const speaker = `<module name="primary">
    <attachedDevices><item>Speaker</item><item>Built-In Mic</item></attachedDevices>
    <devicePorts>
      <devicePort tagName="Speaker" type="AUDIO_DEVICE_OUT_SPEAKER" role="sink"></devicePort>
    </devicePorts>
    <routes><route type="mix" sink="Speaker"
                   sources="primary output"/></routes>
  </module>`;
  const policy = withEarpiece(speaker);
  assert.match(policy, /<item>Earpiece<\/item>/u);
  assert.match(policy, /<devicePort tagName="Earpiece" type="AUDIO_DEVICE_OUT_EARPIECE" role="sink"\/>/u);
  assert.match(policy, /<route type="mix" sink="Earpiece" sources="primary output"\/>/u);
  assert.match(policy, /<route type="mix" sink="Speaker"/u);
  assert.equal(withEarpiece(policy), policy);
  assert.throws(() => withEarpiece('<module/>'), /missing the primary speaker/u);
});
