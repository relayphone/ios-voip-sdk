import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import type { ConversationId } from '../../expo/src/conversations/types.ts';
import { createMarker } from '../../expo/src/testing/marker.ts';
import { command, deadline } from './fixture-runtime.ts';
import type { IsolatedHarness } from './harness.ts';
import { prepareNativeJourney, type NativeJourneyBudget } from './native-journey.ts';
import { sampleNativeVideoClock } from './native-synthetic-video.ts';
import { NativeJourneyFailure, type NativeVideoEvent } from './native-video-evidence.ts';
import { assertNativeTeardown } from './result-receipt.ts';
import { SilenceObservationError } from './silence-window.ts';
import { withSimulatorMediaAudio } from './simulator-media.ts';
import { diagnoseNativeStartup } from './startup-diagnostics.ts';
import { assertDuplexAudio, assertLocalAudioDeparture, hasDuplexSamples, hasUplinkSamples, heldAudioDrainMs, heldOutputReceipt, journeyAudioQueueMs, journeyCaptureSeconds, readAudioRoute, readJourneyAudio } from './video-journey-audio.ts';
import { appParticipant, assertRemoteProducer, assessJourneyVideo, readVideoSnapshot, remoteUplinkCoverage, type VideoSnapshot } from './video-journey-evidence.ts';
import { hostVideoBoundary, videoGates, type VideoSourceReceipt } from './video-observation.ts';

const cases = ['initial-local', 'app-downgrade', 'server-remote', 'hold-resume'] as const;
type JourneyCase = typeof cases[number];
type Boundary = { event: NativeVideoEvent; sample: VideoSnapshot };
type VideoPeer = Awaited<ReturnType<IsolatedHarness['openVideo']>>;
type Epoch = { enable: Boundary; number: number; peer: VideoPeer };
type Report = { scenario: JourneyCase; verdict: 'failed' | 'passed'; checkpoints: { phase: string; evidence: unknown }[] };

async function runJourney(harness: IsolatedHarness, mailbox: ReturnType<typeof prepareNativeJourney>, input: {
  scenario: JourneyCase; conversationId: string; clockID: string; initialPeer: VideoPeer; report: Report; budget: NativeJourneyBudget;
}) {
  const { scenario, conversationId, clockID, initialPeer, report, budget } = input;
  const keep = (phase: string, evidence: unknown) => { report.checkpoints.push({ phase, evidence }); };
  const phaseIds: string[] = [];
  const deadlineCheck = () => {
    budget.signal.throwIfAborted();
    assert.ok(performance.now() < budget.deadlineMs, '30-second video journey acquisition expired');
  };
  const waitThrough = async (boundaryMs: number) => {
    let remainingMs = boundaryMs - performance.now();
    while (remainingMs > 0) {
      await delay(Math.ceil(remainingMs), undefined, { signal: budget.signal });
      deadlineCheck();
      remainingMs = boundaryMs - performance.now();
    }
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
  async function freshAudio(label: string, expectedDownlink?: string) {
    const phaseId = randomUUID(), downId = `${phaseId}:downlink`;
    phaseIds.push(phaseId, downId);
    const startedAtMs = performance.now();
    await harness.act({ type: 'capture' });
    const phaseSentAtMs = performance.now();
    const phase = await request({ operation: 'beginPhase', phaseId });
    const phaseReceivedAtMs = performance.now();
    // Arm both captures before sending the new marker on the continuously paced track.
    await harness.act({ type: 'publish', markerId: downId, observePacing: true, keepQueuedAudio: true });
    const capture = { host: await harness.status(), native: readJourneyAudio(phase) };
    try {
      if (expectedDownlink) {
        assert.equal(capture.native.remoteAudioPublication, expectedDownlink, 'Resumed capture began on a different downlink');
      }
      await until(`${label} duplex samples with RTP coverage`, async () => {
        capture.host = await harness.status();
        if (!hasUplinkSamples(capture.host)) return;
        capture.native = readJourneyAudio(await request({ operation: 'audioProgress' }));
        return hasDuplexSamples(capture.native, capture.host) ? true : undefined;
      });
      const snapshotRequestedAtMs = performance.now();
      const snapshot = await request({ operation: 'audioSnapshot' });
      const pcm = readJourneyAudio(snapshot);
      assert.ok(hasDuplexSamples(pcm, await harness.status()), 'Duplex capture lost coverage between snapshots');
      if (expectedDownlink) {
        assert.equal(pcm.remoteAudioPublication, expectedDownlink, 'Resumed PCM came from a different downlink');
      }
      const capturedAtMs = performance.now();
      const downlink = { clockID, nativeClockID: snapshot.clockId, sender: await harness.downlinkPacing(),
        phase: { sentAtMs: phaseSentAtMs, receivedAtMs: phaseReceivedAtMs, nativeAtMs: phase.phaseAtMs },
        capture: { sentAtMs: snapshotRequestedAtMs, receivedAtMs: capturedAtMs, nativeAtMs: snapshot.observedAtMs },
        decoded: { callbacks: pcm.decoded.observation, rtp: pcm.decoded.pcm?.transport },
        output: { callbacks: pcm.output.observation, rtp: pcm.output.pcm?.transport } };
      const { markers, uplinkCapture } = await assertDuplexAudio(pcm, harness, { up: createMarker(phaseId), down: createMarker(downId) });
      keep(label, { phaseId, remoteAudioPublication: pcm.remoteAudioPublication,
        startedAtMs, snapshotRequestedAtMs, capturedAtMs, analyzedAtMs: performance.now(), uplinkCapture, downlink, markers });
      for (const marker of Object.values(markers)) {
        assert.ok(marker.clean && marker.complete && marker.postRollObserved, `${label}: missing clean fresh audio`);
      }
      deadlineCheck();
    } catch (error) {
      keep(`${label}-capture`, { phaseId, startedAtMs, observedAtMs: performance.now(), sender: await harness.downlinkPacing(), ...capture });
      throw error;
    }
  }
  async function startVideo(enable: Boundary, peer: VideoPeer, number: number): Promise<Epoch> {
    await peer.publish(number);
    deadlineCheck();
    return { enable, peer, number };
  }
  function measure(state: VideoSnapshot, epoch: Epoch, { up, down }: Awaited<ReturnType<VideoPeer['snapshot']>>,
    terminal?: Parameters<typeof assessJourneyVideo>[5]) {
    const nativeEpoch = state.media.epochs.find(e => e.epoch === epoch.number);
    if (!up || up.startedAtMs > state.bracket.sentMs || !down.publication || !nativeEpoch?.publication ||
        !state.media.receivers.some(r => r.publication === down.publication)) return;
    return assessJourneyVideo(state, epoch.enable, epoch.number, down, up, terminal);
  }
  async function freshVideo(label: string, epoch: Epoch, terminal?: Parameters<typeof assessJourneyVideo>[5]) {
    const firstDeadline = hostVideoBoundary(epoch.enable.event.atMs, epoch.enable.sample.bracket).latest + videoGates.firstMs;
    let priorPoll: { startedAtMs: number; sampledAtMs: number; assessedAtMs: number } | undefined;
    let priorSnapshot: VideoSnapshot | undefined;
    return until(label, async () => {
      const startedAtMs = performance.now();
      let state: VideoSnapshot;
      try { state = await sample(); }
      catch (error) {
        keep(`${label}-last-observation`, { priorPoll, waitingSinceMs: startedAtMs,
          sdk: priorSnapshot?.sdk, native: priorSnapshot?.media, bracket: priorSnapshot?.bracket });
        throw error;
      }
      priorSnapshot = state;
      const sampledAtMs = performance.now();
      const hostVideo = await epoch.peer.snapshot();
      const receipts = measure(state, epoch, hostVideo, terminal);
      const previousPoll = priorPoll;
      const currentPoll = { startedAtMs, sampledAtMs, assessedAtMs: performance.now() };
      priorPoll = currentPoll;
      const preserve = () => keep(label, { sdk: state.sdk, native: state.media, bracket: state.bracket,
        host: hostVideo.up, farEndSource: hostVideo.down, receipts,
        polling: { previous: previousPoll, current: currentPoll } });
      if (!receipts?.up || receipts.up.firstMs === null || receipts.down.firstMs === null) {
        if (performance.now() > firstDeadline) {
          preserve();
          assert.fail('First independently decoded video is missing');
        }
        return;
      }
      if (!receipts.up.integrity || !receipts.down.integrity ||
          receipts.up.firstMs > videoGates.firstMs || receipts.down.firstMs > videoGates.firstMs) {
        preserve();
        assert.fail('Video integrity or first-frame gate failed');
      }
      if (!receipts.up.windows.length || !receipts.down.windows.length) return;
      preserve();
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
    await waitThrough(coverage);
    const state = await sample();
    const { up: host, down: downlink } = departedSource
      ? { down: departedSource, up: undefined } : await epoch.peer.snapshot();
    assert.ok(remote || host, 'Missing terminal uplink observation');
    const receipts = assessJourneyVideo(state, epoch.enable, epoch.number, downlink, host, terminal);
    keep('terminal-video', { sdk: state.sdk, native: state.media, host, downlink, receipts,
      timing: { actionAtMs: end.actionAtMs, boundary: end.sample.bracket, observed: state.bracket },
      ...(remote ? { uplinkAfterLeave: remoteUplinkCoverage } : {}) });
    assert.ok(receipts.down.offPassed && (remote || receipts.up?.offPassed), 'Terminal video gate failed');
    assert.ok(!state.media.actions.some(a => a.kind === 'roomReconnecting' ||
      a.atMs >= end.event.atMs && (a.kind === 'published' || a.kind === 'remotePublished')), 'Video republished or room reconnected');
    assert.deepEqual(state.media.remotePublications, [], 'Far-end video is still published');
    if (operation === 'stop') assert.equal(state.media.publication, null, 'App video is still published');
    else {
      assert.equal(state.media.publicationMuted, true, 'Held app publication was not muted');
      assert.equal(state.sdk.onHold, true, 'SDK hold was not retained');
      assert.ok(downlink.generated.at(-1)!.sourceTimeUs > (coverage - 300) * 1000 && (await epoch.peer.status()).held,
        'Far-end generation did not continue behind the hold gate');
    }
    return state;
  }

  const ready = await mailbox.connect(budget);
  keep('startup', diagnoseNativeStartup(ready.evidence));
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
    await freshAudio('before-upgrade');
    const audio = await sample();
    assert.ok(audio.media.publication === null && audio.media.remotePublications.length === 0 &&
      audio.media.epochs.length === 0 && audio.media.receivers.length === 0 && !(await initialPeer.observation()), 'Audio call began with video');
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
  keep('initial-state', { sdk: initial.sdk, audioRoute: originalRoute, videoRoute,
    startup: diagnoseNativeStartup(initial.reply.evidence) });
  let epoch = await startVideo(enabled, initialPeer, 1);
  let live = await freshVideo('first-video', epoch);
  let downgradedBoundary: Parameters<typeof assessJourneyVideo>[5];
  let resumedAudioPublication: string | undefined;
  if (scenario === 'app-downgrade') {
    await request({ operation: 'video', enabled: true, source: 'app' });
    const duplicateObservedAtMs = performance.now();
    // Capture fresh audio while video stays on. At least one complete fixed-rate video
    // window must still fall entirely after the duplicate request.
    await freshAudio('before-downgrade');
    await waitThrough(duplicateObservedAtMs + 2 * videoGates.windowMs);
    const same = await freshVideo('same-value', epoch);
    assert.deepEqual(same.sdk.events, live.sdk.events, 'Same-value update emitted another SDK event');
    assert.equal(same.media.publication, live.media.publication, 'Same-value update replaced the track');
    assert.equal(same.media.epochs.length, live.media.epochs.length, 'Same-value update started another epoch');
    const actionAtMs = performance.now();
    await epoch.peer.freeze();
    await Promise.all([request({ operation: 'video', enabled: false, source: 'app' }), epoch.peer.stop()]);
    const off = await waitForEvent(same, 'changed', false, 'app');
    downgradedBoundary = { ...off, actionAtMs, operation: 'stop' };
    await finishVideo(epoch, downgradedBoundary);
  } else if (scenario === 'hold-resume') {
    await freshAudio('before-hold');
    live = await freshVideo('before-hold-video', epoch);
    const audioSid = (await harness.status()).activeTrackSid;
    assert.ok(audioSid, 'Missing live far-end audio subscription before hold');
    const actionAtMs = performance.now();
    await epoch.peer.hold();
    const audioGate = async () => (await harness.audioLifecycle()).events.filter(e => e.identity === appParticipant &&
      e.trackSid === audioSid && e.atMs >= actionAtMs && (e.kind === 'trackMuted' || e.kind === 'trackUnmuted')).at(-1);
    const holdCoverage = harness.heldSilence(appParticipant, audioSid, actionAtMs, heldAudioDrainMs,
      { deadlineMs: budget.deadlineMs, durationMs: 1000, gapLimitMs: 250 }).then(evidence => {
      if (evidence.reason) {
        keep('held-far-end-audio', evidence);
        throw new SilenceObservationError(evidence.reason, evidence.windows);
      }
      return evidence;
    });
    const nativeHold = async () => {
      await request({ operation: 'hold', enabled: true });
      const hold = await waitForEvent(live, 'held', true);
      const output = await until('held native audio', async () => {
        const held = await sample();
        const audio = readJourneyAudio(held.reply);
        try { return heldOutputReceipt(audio, live.sdk.observedAtMs, hold.event.atMs, held.sdk.observedAtMs); }
        catch (error) {
          keep('held-native-audio', { audio, sdk: held.sdk });
          throw error;
        }
      });
      return { hold, output };
    };
    const [{ hold, output }, { muted, windows: silence }] = await Promise.all([nativeHold(), holdCoverage]);
    const held = await finishVideo(epoch, { ...hold, actionAtMs, operation: 'hold' });
    const finalAudio = readJourneyAudio(held.reply);
    const finalOutput = heldOutputReceipt(finalAudio, live.sdk.observedAtMs, hold.event.atMs, held.sdk.observedAtMs);
    assert.deepEqual(finalOutput, output, 'Native held output changed during observation');
    assert.deepEqual(await audioGate(), muted, 'Held audio publication changed during observation');
    assert.equal((await harness.status()).activeTrackSid, audioSid, 'Held far-end audio subscription changed');
    keep('held-audio', { host: silence, native: finalAudio, output, muted });
    await epoch.peer.stop();
    const next = await harness.openVideo(clockID);
    await next.observe(appParticipant, 2);
    await request({ operation: 'hold', enabled: false });
    const resume = await waitForEvent(held, 'resumed', true);
    assert.equal(resume.sample.sdk.onHold, false);
    keep('resume-boundary', { sdk: resume.sample.sdk, native: resume.sample.media, bracket: resume.sample.bracket });
    epoch = await startVideo(resume, next, 2);
    live = await freshVideo('resumed-video', epoch);
    if (output.kind === 'engineStopped') {
      // The stopped engine could not pull playout. Use a fresh receiver stream
      // so NetEQ does not accelerate queued audio through the resume marker.
      deadlineCheck();
      const publication = await deadline(budget.deadlineMs - performance.now(), 'Renew resumed audio publication',
        () => harness.renewAudioPublication(async retired => {
          assert.equal(retired, finalAudio.remoteAudioPublication, 'Held downlink audio publication changed');
          await until('retired downlink audio subscription', async () => {
            const reply = await request({ operation: 'snapshot' });
            if (readJourneyAudio(reply).remoteAudioPublication !== undefined) return;
            keep('retired-audio-subscription', { retired, observedAtMs: reply.observedAtMs });
            return true;
          });
        }));
      await until('resumed downlink audio subscription', async () => {
        const reply = await request({ operation: 'snapshot' });
        const audio = readJourneyAudio(reply);
        if (audio.remoteAudioPublication !== publication.publication || !audio.decoded.observation.installed) return;
        keep('resumed-audio-subscription', { ...publication, observedAtMs: reply.observedAtMs });
        return true;
      });
      resumedAudioPublication = publication.publication;
    }
  }

  const videoAtEnd = scenario !== 'app-downgrade', remote = scenario === 'server-remote';
  // For app downgrade, this is the first audio capture after the confirmed
  // change and the final audio capture before end.
  await freshAudio('before-end', resumedAudioPublication);
  const armed = await request({ operation: 'armTeardown' });
  if (videoAtEnd) live = await freshVideo('before-end-video', epoch);
  else {
    live = await sample();
    assert.deepEqual(readAudioRoute(readJourneyAudio(live.reply), false), originalRoute, 'Downgrade did not restore the observed route');
  }
  const actionAtMs = performance.now();
  let departedSource: VideoSourceReceipt | undefined;
  if (remote) {
    departedSource = await epoch.peer.stop();
    assert.ok(performance.now() - actionAtMs < videoGates.gapMs, 'Video was no longer fresh before far-end departure');
    await harness.act({ type: 'leave' });
    assert.equal((await harness.status()).connected, false, 'Far-end peer did not leave');
  } else if (videoAtEnd) {
    await epoch.peer.freeze();
    await Promise.all([request({ operation: 'end' }), epoch.peer.stop()]);
  } else await request({ operation: 'end' });
  const ended = await waitForEvent(live, 'ended', videoAtEnd);
  if (!remote) {
    const departed = await until('far-end audio departure', async () => (await harness.audioLifecycle()).afterDisconnect ?? undefined);
    await waitThrough(departed.startedAtMs + 1000);
    keep('terminal-audio', await assertLocalAudioDeparture(harness, actionAtMs, phaseIds));
  }
  const final = videoAtEnd ? await finishVideo(epoch, { ...ended, actionAtMs, operation: 'stop' }, departedSource) : await sample();
  assert.deepEqual(final.sdk.events, ended.sample.sdk.events, 'SDK video history changed after end');
  if (downgradedBoundary) {
    const hostVideo = await epoch.peer.snapshot();
    const earlierOff = measure(final, epoch, hostVideo, downgradedBoundary);
    keep('downgrade-through-end', { receipts: earlierOff, sdk: final.sdk, native: final.media, bracket: final.bracket,
      host: hostVideo.up });
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

const [requestedSimulator, app, output, selection] = process.argv.slice(2);

await withSimulatorMediaAudio(async (guardSignal, leasedSimulator, trackSimulatorApp) => {
  const watchdogAbort = new AbortController();
  const signal = AbortSignal.any([guardSignal, watchdogAbort.signal]);
  const { startIsolatedHarness } = await import('./harness.ts');
  assert.ok(requestedSimulator && app && output && cases.some(name => name === selection),
    'Usage: video-journey.ts <simulator|lease> <app> <result> <initial-local|app-downgrade|server-remote|hold-resume>');
  const simulator = leasedSimulator ?? requestedSimulator;
  const scenario = selection as JourneyCase;
  const report: Report = { scenario, verdict: 'failed', checkpoints: [] };
  const fixtureId = randomUUID(), conversationId = randomUUID() as ConversationId, clockID = randomUUID();
  const bundle = 'com.example.voipconversations';
  const simctl = (...args: string[]) => command('xcrun', ['simctl', ...args], 120_000, signal);
  const harnessDirectory = output + '.harness';
  let harness: IsolatedHarness | undefined, fixtureFile: string | undefined;
  let watchdog: ReturnType<typeof setTimeout> | undefined;
  let failure: unknown;
  let journeyCompleted = false;
  let launchAttempted = false;
  const terminate = () => launchAttempted
    ? command('xcrun', ['simctl', 'terminate', simulator, bundle])
        .catch(() => { /* The app may have already exited. */ })
    : undefined;
  let terminationOnAbort: ReturnType<typeof terminate>;
  const stop = () => {
    terminationOnAbort = terminate();
    harness?.abort();
  };
  const hardStop = () => {
    process.exitCode = 124;
    watchdogAbort.abort(new Error('Video journey exceeded its run deadline'));
  };
  signal.addEventListener('abort', stop, { once: true });
  process.once('SIGALRM', hardStop);
  try {
    signal.throwIfAborted();
    try { await simctl('terminate', simulator, bundle); } catch { /* First launch has no running app. */ }
    await simctl('install', simulator, app);
    await simctl('privacy', simulator, 'grant', 'microphone', bundle);
    const directory = join(await simctl('get_app_container', simulator, bundle, 'data'), 'Documents');
    mkdirSync(directory, { recursive: true });
    fixtureFile = join(directory, 'media-fixture.json');
    const mailbox = prepareNativeJourney(directory, { fixtureId, conversationId });
    signal.throwIfAborted();
    // Retain uplink already received while the native decoder and output fill their windows.
    harness = await startIsolatedHarness(harnessDirectory, fixtureId,
      { captureSeconds: journeyCaptureSeconds, audioQueueMs: journeyAudioQueueMs });
    signal.throwIfAborted();
    watchdog = setTimeout(hardStop, 180_000).unref();
    const initialPeer = await harness.openVideo(clockID);
    await initialPeer.observe(appParticipant, 1);
    await harness.act({ type: 'publish', markerId: randomUUID() });
    signal.throwIfAborted();
    writeFileSync(fixtureFile, JSON.stringify({ ...harness.credentials(appParticipant), control: 'http://127.0.0.1',
      profile: 'tones-v2', uplinkFrequencies: createMarker(randomUUID()).frequencies,
      journey: { fixtureId, conversationId, initialVideo: scenario === 'initial-local' || scenario === 'hold-resume', syntheticVideo: fixtureId },
    }), { mode: 0o600 });
    launchAttempted = true;
    const launched = await simctl('launch', '--terminate-running-process', simulator, bundle);
    if (trackSimulatorApp) trackSimulatorApp(Number(/:\s*(\d+)\s*$/.exec(launched)?.[1]));
    const budget = { deadlineMs: performance.now() + 30_000, signal: AbortSignal.any([signal, AbortSignal.timeout(30_000)]) };
    await runJourney(harness, mailbox, { scenario, conversationId, clockID, initialPeer, report, budget });
    journeyCompleted = true;
  } catch (error) {
    failure = error;
    if (fixtureFile) {
      try {
        const checkpoint: unknown = JSON.parse(readFileSync(join(dirname(fixtureFile), 'media-journey-failure.json'), 'utf8'));
        const code = error instanceof NativeJourneyFailure
          ? { operation: error.operation, category: error.category, code: error.code, underlying: error.underlying }
          : undefined;
        report.checkpoints.push({ phase: 'native-failure', evidence: { ...diagnoseNativeStartup(checkpoint), failure: code } });
      } catch { /* A failure before the app launches has no native checkpoint. */ }
    }
  } finally {
    try {
      try {
        if (fixtureFile) rmSync(fixtureFile, { force: true });
        await terminationOnAbort;
        // The first termination can race an interrupted launch.
        await terminate();
      } finally {
        await harness?.stop();
      }
      if (journeyCompleted) {
        signal.throwIfAborted();
        report.verdict = 'passed';
      }
    } catch (error) {
      harness?.abort();
      if (journeyCompleted) failure = error;
      else console.error('Video journey cleanup failed');
    } finally {
      clearTimeout(watchdog);
      process.removeListener('SIGALRM', hardStop);
      signal.removeEventListener('abort', stop);
      try { rmSync(harnessDirectory, { recursive: true, force: true }); }
      finally { writeFileSync(output, JSON.stringify(report, null, 2)); }
    }
  }
  if (report.verdict === 'failed') throw failure;
}, { localDestination: requestedSimulator ? { simulator: requestedSimulator } : undefined }).catch(error => {
  if (process.exitCode !== 124) throw error;
  console.error('Video journey exceeded its run deadline');
  process.exit(124);
});
