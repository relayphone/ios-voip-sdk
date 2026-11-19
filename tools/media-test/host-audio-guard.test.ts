import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
import { test } from 'node:test';

const binary = process.env.HOST_AUDIO_GUARD_CONTROL;

test('the guard detects silent playback on the real output device', {
  skip: !binary || process.platform !== 'darwin',
  timeout: 15_000,
}, async ({ signal, skip }) => {
  const scratch = await mkdtemp(join(tmpdir(), 'host-audio-control-'));
  const silence = join(scratch, 'silence.wav');
  // One second of mono PCM16 zeros. afplay uses nonzero player volume.
  const wave = Buffer.alloc(44 + 96_000);
  wave.write('RIFF', 0);
  wave.writeUInt32LE(wave.length - 8, 4);
  wave.write('WAVEfmt ', 8);
  wave.writeUInt32LE(16, 16);
  wave.writeUInt16LE(1, 20);
  wave.writeUInt16LE(1, 22);
  wave.writeUInt32LE(48_000, 24);
  wave.writeUInt32LE(96_000, 28);
  wave.writeUInt16LE(2, 32);
  wave.writeUInt16LE(16, 34);
  wave.write('data', 36);
  wave.writeUInt32LE(wave.length - 44, 40);
  try {
    await writeFile(silence, wave);
    const guard = spawn(binary!, [], { signal, stdio: ['pipe', 'pipe', 'pipe'] });
    const guardClosed = once(guard, 'close');
    let report = '';
    guard.stderr.setEncoding('utf8').on('data', chunk => { report += chunk; });
    const stdout = createInterface({ input: guard.stdout });
    let outputTransport: string | undefined;
    const readiness = Promise.withResolvers<string>();
    stdout.on('line', line => {
      if (line.startsWith('default output transport: ')) outputTransport = line.slice('default output transport: '.length);
      if (line.startsWith('ready: ')) readiness.resolve(line);
    });
    try {
      const ready = await Promise.race([
        readiness.promise,
        guardClosed.then(() => { throw new Error(report.trim() || 'Guard exited before readiness'); }),
      ]);
      assert.notEqual(outputTransport, undefined, 'Guard did not report the default output transport');
      if (ready === 'ready: no host devices') {
        guard.stdin.end();
        assert.deepEqual(await guardClosed, [0, null]);
        skip('no host devices');
        return;
      }
      assert.equal(ready, 'ready: monitoring default host devices');
      if (outputTransport !== 'built-in') {
        guard.stdin.end();
        assert.deepEqual(await guardClosed, [0, null]);
        skip('default output is not built-in');
        return;
      }
      const player = spawn('/usr/bin/afplay', ['-v', '1', silence], { signal, stdio: 'ignore' });
      const [verdict, [exit]] = await Promise.all([guardClosed, once(player, 'close')]);
      assert.equal(exit, 0);
      assert.deepEqual(verdict, [1, null]);
      assert.match(report, /^\d{4}-\d{2}-\d{2}T\S+Z Host audio active on default (?:input and )?output device .+ \(built-in\)/);
      console.log(report.trim());
    } finally {
      stdout.close();
      guard.kill();
    }
  } finally {
    await rm(scratch, { recursive: true, force: true });
  }
});
