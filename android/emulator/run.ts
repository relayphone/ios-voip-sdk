import { execFileSync, spawn } from 'node:child_process';
import { appendFileSync, closeSync, existsSync, openSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { performance } from 'node:perf_hooks';
import { setTimeout as delay } from 'node:timers/promises';
import { withEarpiece } from './earpiece.ts';

interface Emulator {
  warm(): Promise<void>;
  stop(): Promise<void>;
}

function verifyExample(apk: string): void {
  const packageName = 'com.example.voipconversations';
  adb(['install', '-r', apk], 45_000);
  adb(['shell', 'pm', 'grant', packageName, 'android.permission.POST_NOTIFICATIONS']);
  const run = `android-${Date.now()}`;
  adb(['shell', 'am', 'start', '-W', '-a', 'android.intent.action.VIEW',
    '-d', `conversations-example://journey?runID=${run}`, packageName], 25_000);
  const deadline = performance.now() + 60_000;
  while (performance.now() < deadline) {
    const line = adb(['logcat', '-d', '-s', 'ReactNativeJS:I']).split('\n').find(entry =>
      entry.includes(`VoIPJourney ${run} `));
    if (line?.includes(' passed')) {
      console.log(line);
      return;
    }
    if (line) throw new Error(line);
    adb(['shell', 'sleep', '1']);
  }
  throw new Error('The Expo example did not report the calling journeys');
}

function verifyPush(apk: string, output: string): void {
  adb(['install', '-r', apk], 45_000);
  const log = openSync(join(output, 'push-logcat.txt'), 'w');
  const logcat = spawn(adbPath(), ['-s', serial, 'logcat', '-b', 'all', '-T', '1'],
    { stdio: ['ignore', log, log] });
  logcat.on('error', (error) => console.warn(`Could not capture push logcat: ${error.message}`));
  closeSync(log);
  try {
    const result = adb(['shell', 'am', 'instrument', '-w',
      'com.example.voipconversations.test/androidx.test.runner.AndroidJUnitRunner'], 150_000);
    console.log(result);
    if (!/^OK \(1 test\)$/mu.test(result)) throw new Error('Expo push instrumentation failed');
  } finally {
    logcat.kill();
  }
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
const adbPath = () => join(process.env.ANDROID_HOME!, 'platform-tools', 'adb');
const adb = (args: string[], timeout = 5_000) => execFileSync(
  adbPath(), ['-s', serial, ...args],
  { encoding: 'utf8', timeout, maxBuffer: 8 * 1024 * 1024, killSignal: 'SIGKILL', stdio: ['ignore', 'pipe', 'pipe'] },
).trim();

async function prepareCallStyle(): Promise<void> {
  if (adb(['shell', 'getprop', 'ro.build.version.sdk']) !== '34') return;

  // The Android 14 image can drop CallStyle notifications during a resource overlay refresh.
  // Apply a fixed system palette before installing the app and wait for Android to resolve it.
  const theme = JSON.stringify({
    'android.theme.customization.color_source': 'preset',
    'android.theme.customization.system_palette': '676767',
    'android.theme.customization.theme_style': 'MONOCHROMATIC',
  });
  adb(['shell', 'settings', '--user', '0', 'put', 'secure', 'theme_customization_overlay_packages', `'${theme}'`]);
  const deadline = performance.now() + 30_000;
  while (performance.now() < deadline) {
    const accent = adb(['shell', 'cmd', 'overlay', 'lookup', '--user', '0', 'android', 'android:color/system_accent1_500']);
    if (/^#ff([0-9a-f]{2})\1\1$/iu.test(accent)) {
      adb(['shell', 'am', 'wait-for-broadcast-barrier', '--flush-application-threads'], 30_000);
      return;
    }
    await delay(250);
  }
  throw new Error('Android 14 did not apply the preset notification test palette');
}

function startEmulator(output: string, attempt: number): Emulator {
  const started = performance.now();
  const log = openSync(join(output, `emulator-${attempt}.log`), 'w');
  const child = spawn(join(process.env.ANDROID_HOME!, 'emulator', 'emulator'), [
    '-avd', 'telecom', '-port', '5554', '-no-window', '-no-snapshot', '-no-audio', '-no-boot-anim',
    '-writable-system', '-accel', 'on', '-gpu', 'swiftshader', '-cores', '4', '-memory', '4096',
  ], { stdio: ['ignore', log, log] });
  closeSync(log);

  let launchError: Error | undefined;
  let exited = false;
  child.on('error', (error) => { launchError = error; });
  const closed = new Promise<void>((resolve) => child.once('close', () => {
    exited = true;
    resolve();
  }));

  const bootID = () => adb(['shell', 'cat', '/proc/sys/kernel/random/boot_id']);

  async function waitForBoot(previousBoot?: string): Promise<void> {
    const deadline = performance.now() + 180_000;
    while (performance.now() < deadline) {
      if (launchError) throw launchError;
      if (exited) throw new Error(`Emulator exited with ${child.exitCode ?? child.signalCode}`);
      try {
        if (adb(['shell', 'getprop', 'sys.boot_completed']) === '1' &&
            (previousBoot === undefined || bootID() !== previousBoot)) return;
      } catch {
        // ADB can be offline while Android starts.
      }
      await delay(2_000);
    }
    throw new Error('Android did not finish booting within 180 seconds');
  }

  async function reboot() {
    const previousBoot = bootID();
    adb(['reboot']);
    await waitForBoot(previousBoot);
  }

  function rootADB() {
    adb(['root']);
    adb(['wait-for-device'], 30_000);
  }

  async function provisionEarpiece() {
    const remote = '/vendor/etc/primary_audio_policy_configuration.xml';
    const original = adb(['shell', 'cat', remote]);
    const updated = withEarpiece(original);
    if (updated === original) return;

    rootADB();
    adb(['disable-verity'], 30_000);
    await reboot();
    rootADB();
    adb(['remount', 'vendor'], 30_000);
    const local = join(output, 'primary_audio_policy_configuration.xml');
    writeFileSync(local, updated + '\n');
    adb(['push', local, remote]);
    adb(['shell', 'restorecon', remote]);
    await reboot();
    if (adb(['shell', 'cat', remote]) !== updated) {
      throw new Error('Emulator earpiece configuration did not survive reboot');
    }
  }

  return {
    async warm() {
      let bootedAt: number | undefined;
      let ready = false;
      try {
        await waitForBoot();
        bootedAt = performance.now();
        await provisionEarpiece();
        adb(['shell', 'input', 'keyevent', 'KEYCODE_WAKEUP']);
        adb(['shell', 'wm', 'dismiss-keyguard']);
        const home = adb(['shell', 'am', 'start', '-W', '-a', 'android.intent.action.MAIN',
          '-c', 'android.intent.category.HOME'], 20_000);
        if (!/^Status: ok$/m.test(home)) throw new Error(`Launcher did not start: ${home}`);
        if (adb(['shell', 'service', 'check', 'telecom']) !== 'Service telecom: found') {
          throw new Error('Telecom service is unavailable');
        }
        await prepareCallStyle();
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
        writeFileSync(join(output, `logcat-${attempt}.txt`), adb(['logcat', '-d', '-t', '5000']));
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
        if (process.env.EXPO_CALL_JOURNEY_APK) verifyExample(process.env.EXPO_CALL_JOURNEY_APK);
        if (process.env.EXPO_PUSH_TEST_APK) verifyPush(process.env.EXPO_PUSH_TEST_APK, process.env.EMULATOR_OUTPUT!);
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
