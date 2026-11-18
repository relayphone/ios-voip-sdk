import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { dispose } from '@livekit/rtc-node';
import type { ConversationId } from '../../expo/src/conversations/types.ts';
import { createMarker } from '../../expo/src/testing/marker.ts';
import { command, deadline } from './fixture-runtime.ts';
import { startHarness, type MediaHarness } from './harness.ts';
import { prepareNativeJourney, type NativeJourneyBudget } from './native-journey.ts';
import { sampleNativeVideoClock } from './native-synthetic-video.ts';
import { NativeJourneyFailure, type NativeVideoEvent } from './native-video-evidence.ts';
import { assertNativeTeardown } from './result-receipt.ts';
import { observeSilence } from './silence-window.ts';
import { diagnoseNativeStartup } from './startup-diagnostics.ts';
import { assertDuplexAudio, assertLocalAudioDeparture, hasDuplexSamples, heldOutputReceipt, readAudioRoute, readJourneyAudio } from './video-journey-audio.ts';
import { appParticipant, assertRemoteProducer, assessJourneyVideo, readVideoSnapshot, remoteUplinkCoverage, type VideoSnapshot } from './video-journey-evidence.ts';
import { hostVideoBoundary, videoGates, type VideoSourceReceipt } from './video-observation.ts';
import type { VideoPeer } from './video-peer.ts';

const cases = ['initial-local', 'app-downgrade', 'server-remote', 'hold-resume'] as const;
type JourneyCase = typeof cases[number];
type Boundary = { event: NativeVideoEvent; sample: VideoSnapshot };
type Epoch = { enable: Boundary; number: number; peer: VideoPeer };
type Report = { scenario: JourneyCase; verdict: 'failed' | 'passed'; checkpoints: { phase: string; evidence: unknown }[] };

async function runJourney(harness: MediaHarness, mailbox: ReturnType<typeof prepareNativeJourney>, input: {
  scenario: JourneyCase; conversationId: string; clockID: string; initialPeer: VideoPeer; report: Report; budget: NativeJourneyBudget;
}) {
  const { scenario, conversationId, clockID, initialPeer, report, budget } = input;
  const keep = (phase: string, evidence: unknown) => { report.checkpoints.push({ phase, evidence }); };
  const phaseIds: string[] = [];
  const deadlineCheck = () => {
    budget.signal.throwIfAborted();
    assert.ok(performance.now() < budget.deadlineMs, '30-second video journey acquisition expired');
  };
  const request = (action: Parameters<typeof mailbox.request>[0]) => mailbox.request(action, budget);
  const sample = async () => {
    const { reply, bracket } = await sampleNativeVideoClock(mailbox, budget, clockID);
    return readVideoSnapshot(reply, bracket, harness.fixtureId);
  };
  const until = async <T>(label: string, read: () => T | undefined | Promise<T | undefined>): Promise<T> => {
    try {
      while (true) {
        deadlineCheck();
        const value = await read();
        if (value !== undefined) { deadlineCheck(); return value; }
        await delay(100, undefined, { signal: budget.signal });
      }
    } catch (error) { throw new Error(label, { cause: error }); }
  };
  const waitForEvent = async (prior: VideoSnapshot, kind: NativeVideoEvent['kind'], hasVideo: boolean,
    source: NativeVideoEvent['source'] = null): Promise<Boundary> => until(`SDK ${kind}`, async () => {
    const state = await sample();
    assert.deepEqual(state.sdk.events.slice(0, prior.sdk.events.length), prior.sdk.events, 'SDK video history changed');
    const suffix = state.sdk.events.slice(prior.sdk.events.length);
    if (!suffix.length) return;
    assert.equal(suffix.length, 1, 'Unexpected SDK event count');
    const event = suffix[0]!;
    assert.ok(event.kind === kind && event.hasVideo === hasVideo && event.connected === (kind !== 'ended') &&
      event.source === source && event.atMs >= prior.sdk.observedAtMs, 'Unexpected confirmed SDK video event');
    return { event, sample: state };
  });
  async function freshAudio(label: string) {
    const phaseId = randomUUID(), downId = `${phaseId}:downlink`;
    phaseIds.push(phaseId, downId);
    await harness.act({ type: 'capture' });
    await harness.act({ type: 'publish', markerId: downId });
    await request({ operation: 'beginPhase', phaseId });
    const state = await until(`${label} duplex samples`, async () => {
      if (harness.status().receivedSamples < 48_000 * 3) return;
      const current = await sample();
      return hasDuplexSamples(readJourneyAudio(current.reply), harness) ? current : undefined;
    });
    const markers = await assertDuplexAudio(readJourneyAudio(state.reply), harness,
      { up: createMarker(phaseId), down: createMarker(downId) });
    keep(label, { phaseId, markers });
    for (const marker of Object.values(markers)) {
      assert.ok(marker.clean && marker.complete && marker.postRollObserved, `${label}: missing clean fresh audio`);
    }
    deadlineCheck();
    return sample();
  }
  async function startVideo(enable: Boundary, peer: VideoPeer, number: number): Promise<Epoch> {
    await peer.publish(number);
    deadlineCheck();
    return { enable, peer, number };
  }
  function measure(state: VideoSnapshot, epoch: Epoch, terminal?: Parameters<typeof assessJourneyVideo>[5]) {
    const up = epoch.peer.observation(), down = epoch.peer.sourceReceipt();
    const nativeEpoch = state.media.epochs.find(e => e.epoch === epoch.number);
    if (!up || up.startedAtMs > state.bracket.sentMs || !down.publication || !nativeEpoch?.publication ||
        !state.media.receivers.some(r => r.publication === down.publication)) return;
    return assessJourneyVideo(state, epoch.enable, epoch.number, down, up, terminal);
  }
  async function freshVideo(label: string, epoch: Epoch, terminal?: Parameters<typeof assessJourneyVideo>[5]) {
    const firstDeadline = hostVideoBoundary(epoch.enable.event.atMs, epoch.enable.sample.bracket).latest + videoGates.firstMs;
    return until(label, async () => {
      const state = await sample(), receipts = measure(state, epoch, terminal);
      if (!receipts?.up || receipts.up.firstMs === null || receipts.down.firstMs === null) {
        assert.ok(performance.now() <= firstDeadline, 'First independently decoded video is missing');
        return;
      }
      assert.ok(receipts.up.integrity && receipts.down.integrity && receipts.up.firstMs <= videoGates.firstMs &&
        receipts.down.firstMs <= videoGates.firstMs, 'Video integrity or first-frame gate failed');
      if (!receipts.up.windows.length || !receipts.down.windows.length) return;
      keep(label, { sdk: state.sdk, native: state.media, host: epoch.peer.observation(), farEndSource: epoch.peer.sourceReceipt(), receipts });
      assert.ok(state.sdk.connected && state.sdk.hasVideo === true && state.sdk.onHold === false &&
        receipts.up.onPassed && receipts.down.onPassed && receipts.up.lastFreshAtMs !== null && receipts.down.lastFreshAtMs !== null &&
        performance.now() - receipts.up.lastFreshAtMs <= videoGates.gapMs &&
        state.sdk.observedAtMs - receipts.down.lastFreshAtMs <= videoGates.gapMs, `${label}: duplex video gate failed`);
      return state;
    });
  }
  async function finishVideo(epoch: Epoch, terminal: NonNullable<Parameters<typeof assessJourneyVideo>[5]>,
    departedSource?: VideoSourceReceipt) {
    const { operation, ...end } = terminal;
    const remote = departedSource !== undefined;
    const coverage = hostVideoBoundary(end.event.atMs, end.sample.bracket).latest + videoGates.drainMs;
    while (performance.now() < coverage) {
      await delay(Math.ceil(coverage - performance.now()), undefined, { signal: budget.signal });
      deadlineCheck();
    }
    const state = await sample(), downlink = departedSource ?? epoch.peer.sourceReceipt();
    const host = remote ? undefined : epoch.peer.observation();
    assert.ok(remote || host, 'Missing terminal uplink observation');
    const receipts = assessJourneyVideo(state, epoch.enable, epoch.number, downlink, host, terminal);
    keep('terminal-video', { sdk: state.sdk, native: state.media, host, downlink, receipts,
      ...(remote ? { uplinkAfterLeave: remoteUplinkCoverage } : {}) });
    assert.ok(receipts.down.offPassed && (remote || receipts.up?.offPassed), 'Terminal video gate failed');
    assert.ok(!state.media.actions.some(a => a.kind === 'roomReconnecting' ||
      a.atMs >= end.event.atMs && (a.kind === 'published' || a.kind === 'remotePublished')), 'Video republished or room reconnected');
    assert.deepEqual(state.media.remotePublications, [], 'Far-end video is still published');
    if (operation === 'stop') assert.equal(state.media.publication, null, 'App video is still published');
    else {
      assert.equal(state.media.publicationMuted, true, 'Held app publication was not muted');
      assert.equal(state.sdk.onHold, true, 'SDK hold was not retained');
      assert.ok(downlink.generated.at(-1)!.sourceTimeUs > (coverage - 300) * 1000 && epoch.peer.status().held,
        'Far-end generation did not continue behind the hold gate');
    }
    return state;
  }

  const ready = await mailbox.connect(budget);
  await request({ operation: 'beginPhase', phaseId: randomUUID() });
  const initial = await sample();
  const [first] = initial.sdk.events;
  const startsWithVideo = scenario === 'initial-local' || scenario === 'hold-resume';
  assert.ok(initial.sdk.connected && initial.sdk.hasVideo === startsWithVideo && !initial.sdk.onHold &&
    first?.kind === 'readySnapshot' && first.connected && first.hasVideo === startsWithVideo &&
    first.source === null && first.atMs <= ready.observedAtMs && initial.sdk.events.length === 1, 'Missing connected initial SDK snapshot');
  const originalRoute = readAudioRoute(readJourneyAudio(initial.reply), startsWithVideo);
  let enabled: Boundary = { event: first, sample: initial };
  if (!startsWithVideo) {
    const audio = await freshAudio('before-upgrade');
    assert.ok(audio.media.publication === null && audio.media.remotePublications.length === 0 &&
      audio.media.epochs.length === 0 && audio.media.receivers.length === 0 && !initialPeer.observation(), 'Audio call began with video');
    const source = scenario === 'app-downgrade' ? 'app' : 'server';
    if (source === 'app') await request({ operation: 'video', enabled: true, source });
    else {
      assert.ok(audio.reply.phaseId);
      await harness.updateVideo({ conversationId, sessionId: audio.reply.sessionId, phaseId: audio.reply.phaseId, enabled: true }, budget);
    }
    enabled = await waitForEvent(audio, 'changed', true, source);
  }
  const videoRoute = readAudioRoute(readJourneyAudio(enabled.sample.reply), true);
  if (!startsWithVideo) {
    assert.deepEqual(videoRoute, originalRoute.length === 1 && originalRoute[0] === 'receiver'
      ? ['speaker'] : originalRoute, 'Upgrade did not preserve route ownership');
  }
  keep('initial-state', { sdk: initial.sdk, audioRoute: originalRoute, videoRoute });
  let epoch = await startVideo(enabled, initialPeer, 1);
  let live = await freshVideo('first-video', epoch);
  let downgradedBoundary: Parameters<typeof assessJourneyVideo>[5];
  if (scenario === 'app-downgrade') {
    await request({ operation: 'video', enabled: true, source: 'app' });
    // At least one complete fixed rate window now falls entirely after the duplicate request.
    await delay(2 * videoGates.windowMs, undefined, { signal: budget.signal });
    const same = await freshVideo('same-value', epoch);
    assert.deepEqual(same.sdk.events, live.sdk.events, 'Same-value update emitted another SDK event');
    assert.equal(same.media.publication, live.media.publication, 'Same-value update replaced the track');
    assert.equal(same.media.epochs.length, live.media.epochs.length, 'Same-value update started another epoch');
    await freshAudio('before-downgrade');
    live = await freshVideo('before-downgrade-video', epoch);
    const actionAtMs = performance.now();
    epoch.peer.freeze();
    await Promise.all([request({ operation: 'video', enabled: false, source: 'app' }), epoch.peer.stop()]);
    const off = await waitForEvent(live, 'changed', false, 'app');
    downgradedBoundary = { ...off, actionAtMs, operation: 'stop' };
    await finishVideo(epoch, downgradedBoundary);
    const downgraded = await freshAudio('after-downgrade');
    assert.deepEqual(readAudioRoute(readJourneyAudio(downgraded.reply), false), originalRoute, 'Downgrade did not restore the observed route');
    live = downgraded;
  } else if (scenario === 'hold-resume') {
    await freshAudio('before-hold');
    live = await freshVideo('before-hold-video', epoch);
    const audioSid = harness.status().activeTrackSid;
    assert.ok(audioSid, 'Missing live far-end audio subscription before hold');
    const actionAtMs = performance.now();
    await epoch.peer.hold();
    await request({ operation: 'hold', enabled: true });
    const hold = await waitForEvent(live, 'held', true);
    const audioGate = () => harness.observation().lifecycle.events.filter(e => e.identity === appParticipant &&
      e.trackSid === audioSid && e.atMs >= actionAtMs && (e.kind === 'trackMuted' || e.kind === 'trackUnmuted')).at(-1);
    const muted = await until('far-end held audio publication', () => {
      const event = audioGate();
      return event?.kind === 'trackMuted' ? event : undefined;
    });
    const holdCoverage = observeSilence(() => {
      const status = harness.status();
      return { ...status, samples: status.receivedSamples };
    }, { deadlineMs: budget.deadlineMs, durationMs: 1000, gapLimitMs: 250 });
    const nativeHold = until('held native audio', async () => {
      const held = await sample();
      return heldOutputReceipt(readJourneyAudio(held.reply), hold.event.atMs, held.sdk.observedAtMs);
    });
    const [output, silence] = await Promise.all([nativeHold, holdCoverage]);
    const held = await finishVideo(epoch, { ...hold, actionAtMs, operation: 'hold' });
    assert.deepEqual(audioGate(), muted, 'Held audio publication changed during observation');
    assert.equal(harness.status().activeTrackSid, audioSid, 'Held far-end audio subscription changed');
    keep('held-audio', { host: silence, output, muted });
    await epoch.peer.stop();
    const next = await harness.openVideo(clockID);
    await next.observe(appParticipant, 2);
    await request({ operation: 'hold', enabled: false });
    const resume = await waitForEvent(held, 'resumed', true);
    assert.equal(resume.sample.sdk.onHold, false);
    epoch = await startVideo(resume, next, 2);
    live = await freshVideo('resumed-video', epoch);
  }

  const videoAtEnd = scenario !== 'app-downgrade', remote = scenario === 'server-remote';
  await freshAudio('before-end');
  const armed = await request({ operation: 'armTeardown' });
  if (videoAtEnd) live = await freshVideo('before-end-video', epoch);
  else live = await sample();
  const actionAtMs = performance.now();
  let departedSource: VideoSourceReceipt | undefined;
  if (remote) {
    departedSource = await epoch.peer.stop();
    assert.ok(performance.now() - actionAtMs < videoGates.gapMs, 'Video was no longer fresh before far-end departure');
    await harness.act({ type: 'leave' });
    assert.equal(harness.status().connected, false, 'Far-end peer did not leave');
  } else if (videoAtEnd) {
    epoch.peer.freeze();
    await Promise.all([request({ operation: 'end' }), epoch.peer.stop()]);
  } else await request({ operation: 'end' });
  const ended = await waitForEvent(live, 'ended', videoAtEnd);
  if (!remote) {
    const departed = await until('far-end audio departure', () => harness.observation().lifecycle.afterDisconnect ?? undefined);
    await delay(Math.max(0, departed.startedAtMs + 1000 - performance.now()), undefined, { signal: budget.signal });
    keep('terminal-audio', assertLocalAudioDeparture(harness, actionAtMs, phaseIds));
  }
  const final = videoAtEnd ? await finishVideo(epoch, { ...ended, actionAtMs, operation: 'stop' }, departedSource) : await sample();
  assert.deepEqual(final.sdk.events, ended.sample.sdk.events, 'SDK video history changed after end');
  if (downgradedBoundary) {
    const earlierOff = measure(final, epoch, downgradedBoundary);
    assert.ok(earlierOff?.up?.offPassed && earlierOff.down.offPassed && final.media.publication === null &&
      !final.media.actions.some(a => a.atMs >= downgradedBoundary.event.atMs &&
        (a.kind === 'published' || a.kind === 'remotePublished')), 'Video returned after downgrade');
  }
  const row = final.reply.evidence as { ended?: { reason: string; atMs: number }; teardown?: unknown;
    released?: boolean; audioActive?: boolean };
  const arm = (armed.evidence as { teardown?: { startedAtMs: number } }).teardown;
  keep('ended', { state: final.sdk, ended: row.ended, teardown: row.teardown, actions: final.media.actions });
  assert.ok(arm && row.ended?.reason === (remote ? 'remoteEnded' : 'local') && row.ended.atMs === ended.event.atMs &&
    row.released === true && row.audioActive === false && !final.sdk.connected && !final.media.roomConnected,
    'Missing confirmed SDK end and released call');
  assertNativeTeardown(row.teardown, { clockID: final.sdk.clockId.toUpperCase(), startedAtMs: arm.startedAtMs,
    deadlineMs: final.bracket.nativeMs + budget.deadlineMs - final.bracket.receivedMs });
  assert.ok(final.media.actions.some(a => a.kind === 'roomDisconnected' && a.atMs >= ended.event.atMs) &&
    !final.media.actions.some(a => a.kind === 'roomReconnecting' || a.atMs >= ended.event.atMs &&
      (a.kind === 'published' || a.kind === 'remotePublished')), 'Room teardown or post-end publication evidence failed');
  if (remote) {
    assert.ok(final.media.actions.some(a => a.kind === 'farEndDisconnected' && a.atMs <= ended.event.atMs), 'No native far-end departure');
    const publication = live.media.publication;
    assert.ok(publication, 'Missing live app publication at remote end');
    keep('remote-producer', assertRemoteProducer(final, epoch.number, publication, ended.event));
  }
  await request({ operation: 'close' });
}

const [simulator, app, output, selection] = process.argv.slice(2);
assert.ok(simulator && app && output && cases.some(name => name === selection),
  'Usage: video-journey.ts <simulator> <app> <result> <initial-local|app-downgrade|server-remote|hold-resume>');
const scenario = selection as JourneyCase;
const report: Report = { scenario, verdict: 'failed', checkpoints: [] };
const fixtureId = randomUUID(), conversationId = randomUUID() as ConversationId, clockID = randomUUID();
const bundle = 'com.example.voipconversations';
const simctl = (...args: string[]) => command('xcrun', ['simctl', ...args]);
const harnessDirectory = output + '.harness';
let harness: MediaHarness | undefined, fixtureFile: string | undefined;
let watchdog: ReturnType<typeof setTimeout> | undefined;
let failure: unknown;
let journeyCompleted = false;
const hardStop = () => {
  harness?.abort();
  writeFileSync(output, JSON.stringify(report, null, 2));
  process.exit(124);
};
process.once('SIGALRM', hardStop);
try {
  try { await simctl('terminate', simulator, bundle); } catch { /* First launch has no running app. */ }
  await simctl('install', simulator, app);
  await simctl('privacy', simulator, 'grant', 'microphone', bundle);
  const directory = join(await simctl('get_app_container', simulator, bundle, 'data'), 'Documents');
  mkdirSync(directory, { recursive: true });
  fixtureFile = join(directory, 'media-fixture.json');
  const mailbox = prepareNativeJourney(directory, { fixtureId, conversationId });
  harness = await startHarness(harnessDirectory, fixtureId);
  watchdog = setTimeout(hardStop, 180_000).unref();
  const initialPeer = await harness.openVideo(clockID);
  await initialPeer.observe(appParticipant, 1);
  await harness.act({ type: 'publish', markerId: randomUUID() });
  writeFileSync(fixtureFile, JSON.stringify({ ...harness.credentials(appParticipant), control: 'http://127.0.0.1',
    profile: 'tones-v2', uplinkFrequencies: createMarker(randomUUID()).frequencies,
    journey: { fixtureId, conversationId, initialVideo: scenario === 'initial-local' || scenario === 'hold-resume', syntheticVideo: fixtureId },
  }), { mode: 0o600 });
  await simctl('launch', '--terminate-running-process', simulator, bundle);
  const budget = { deadlineMs: performance.now() + 30_000, signal: AbortSignal.timeout(30_000) };
  await runJourney(harness, mailbox, { scenario, conversationId, clockID, initialPeer, report, budget });
  journeyCompleted = true;
} catch (error) {
  failure = error;
  if (fixtureFile) {
    try {
      const checkpoint: unknown = JSON.parse(readFileSync(join(dirname(fixtureFile), 'media-journey-failure.json'), 'utf8'));
      const code = error instanceof NativeJourneyFailure
        ? { operation: error.operation, category: error.category, code: error.code }
        : undefined;
      report.checkpoints.push({ phase: 'native-failure', evidence: { ...diagnoseNativeStartup(checkpoint), failure: code } });
    } catch { /* A failure before the app launches has no native checkpoint. */ }
  }
} finally {
  try {
    if (fixtureFile) {
      rmSync(fixtureFile, { force: true });
      try { await simctl('terminate', simulator, bundle); } catch { /* Already exited. */ }
    }
    try { await harness?.stop(); } finally { await deadline(10_000, 'RTC disposal', dispose); }
    rmSync(harnessDirectory, { recursive: true, force: true });
    if (journeyCompleted) report.verdict = 'passed';
  } catch (error) {
    if (journeyCompleted) failure = error;
    else console.error('Video journey cleanup failed');
  } finally {
    clearTimeout(watchdog);
    process.removeListener('SIGALRM', hardStop);
    writeFileSync(output, JSON.stringify(report, null, 2));
  }
}
if (report.verdict === 'failed') throw failure;
