import { execFileSync, spawn } from 'node:child_process';
import { appendFileSync, closeSync, existsSync, openSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { performance } from 'node:perf_hooks';
import { setTimeout as delay } from 'node:timers/promises';

interface Emulator {
  warm(): Promise<void>;
  stop(): Promise<void>;
}

export async function verifyOnEmulator(
  start: (attempt: number) => Emulator,
  verify: () => void,
  reportBootFailure: (attempt: number, error: unknown) => void,
): Promise<void> {
  for (const attempt of [1, 2]) {
    const emulator = start(attempt);
    try {
      try {
        await emulator.warm();
      } catch (error) {
        reportBootFailure(attempt, error);
        if (attempt === 2) throw error;
        continue;
      }
      verify();
      return;
    } finally {
      await emulator.stop();
    }
  }
}

const serial = 'emulator-5554';
const adb = (args: string[], timeout = 5_000) => execFileSync(
  join(process.env.ANDROID_HOME!, 'platform-tools', 'adb'), ['-s', serial, ...args],
  { encoding: 'utf8', timeout, killSignal: 'SIGKILL', stdio: ['ignore', 'pipe', 'pipe'] },
).trim();

function startEmulator(output: string, attempt: number): Emulator {
  const started = performance.now();
  const log = openSync(join(output, `emulator-${attempt}.log`), 'w');
  const child = spawn(join(process.env.ANDROID_HOME!, 'emulator', 'emulator'), [
    '-avd', 'telecom', '-port', '5554', '-no-window', '-no-snapshot', '-no-audio', '-no-boot-anim',
    '-accel', 'on', '-gpu', 'swiftshader', '-cores', '4', '-memory', '4096',
  ], { stdio: ['ignore', log, log] });
  closeSync(log);

  let launchError: Error | undefined;
  let exited = false;
  child.on('error', (error) => { launchError = error; });
  const closed = new Promise<void>((resolve) => child.once('close', () => {
    exited = true;
    resolve();
  }));

  async function waitForBoot(): Promise<void> {
    const deadline = performance.now() + 180_000;
    while (performance.now() < deadline) {
      if (launchError) throw launchError;
      if (exited) throw new Error(`Emulator exited with ${child.exitCode ?? child.signalCode}`);
      try {
        if (adb(['shell', 'getprop', 'sys.boot_completed']) === '1') return;
      } catch {
        // ADB can be offline while Android starts.
      }
      await delay(2_000);
    }
    throw new Error('Android did not finish booting within 180 seconds');
  }

  return {
    async warm() {
      let bootedAt: number | undefined;
      let ready = false;
      try {
        await waitForBoot();
        bootedAt = performance.now();
        adb(['shell', 'input', 'keyevent', 'KEYCODE_WAKEUP']);
        adb(['shell', 'wm', 'dismiss-keyguard']);
        const home = adb(['shell', 'am', 'start', '-W', '-a', 'android.intent.action.MAIN',
          '-c', 'android.intent.category.HOME'], 20_000);
        if (!/^Status: ok$/m.test(home)) throw new Error(`Launcher did not start: ${home}`);
        if (adb(['shell', 'service', 'check', 'telecom']) !== 'Service telecom: found') {
          throw new Error('Telecom service is unavailable');
        }
        ready = true;
      } finally {
        const summary = process.env.GITHUB_STEP_SUMMARY;
        if (summary) {
          const finishedAt = performance.now();
          const seconds = (milliseconds: number) => `${(milliseconds / 1_000).toFixed(1)} s`;
          const boot = `${seconds((bootedAt ?? finishedAt) - started)} (${bootedAt === undefined ? 'failed' : 'passed'})`;
          const telecom = bootedAt === undefined ? 'Skipped' : `${seconds(finishedAt - bootedAt)} (${ready ? 'passed' : 'failed'})`;
          appendFileSync(summary, `\n### Emulator attempt ${attempt}\n\n| Phase | Duration and result |\n| --- | --- |\n| Android boot | ${boot} |\n| Telecom readiness | ${telecom} |\n`);
        }
      }
    },
    async stop() {
      try {
        writeFileSync(join(output, `logcat-${attempt}.txt`), adb(['logcat', '-d', '-t', '500']));
      } catch {
        // The emulator log is still available if ADB never came online.
      }
      if (exited) return;
      try {
        adb(['emu', 'kill']);
      } catch {
        child.kill('SIGTERM');
      }
      await Promise.race([closed, delay(5_000, undefined, { ref: false })]);
      if (!exited) {
        child.kill('SIGKILL');
        await closed;
      }
    },
  };
}

if (import.meta.main) {
  await verifyOnEmulator(
    (attempt) => startEmulator(process.env.EMULATOR_OUTPUT!, attempt),
    () => {
      if (!existsSync('system/build.gradle.kts')) {
        console.log('Emulator and Telecom ready. The system module has no instrumentation task yet.');
        return;
      }
      try {
        execFileSync('timeout', [
          '--kill-after=15s', '240s', './gradlew', ':system:connectedDebugAndroidTest',
          '-Pandroid.enableAdditionalTestOutput=true', '--no-daemon', '--max-workers=2', '--console=plain',
        ], { stdio: 'inherit', env: { ...process.env, ANDROID_SERIAL: serial } });
      } catch (error) {
        console.error('::error title=Product verification::Android instrumentation failed. See the Gradle log and test artifacts.');
        throw error;
      }
    },
    (attempt, error) => console.error(
      `::${attempt === 1 ? 'warning' : 'error'} title=Infrastructure::Emulator warm-up ${attempt}/2 failed: ${error}`,
    ),
  );
}
