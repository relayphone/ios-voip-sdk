import { fork } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { deadline, stopChild } from './fixture-runtime.ts';
import { SilenceObservationError } from './silence-window.ts';
import type { JoinCredentials, PeerOptions } from './harness.ts';
import type { PeerCommand, PeerOperations, PeerResponse, PeerResult } from './peer-process-child.ts';

/** Keep media callbacks and observation timers on their own event loop. */
export async function startPeerProcess(credentials: JoinCredentials, options: PeerOptions, serverPid: number) {
  // Both processes use the same host monotonic clock. Express receipts in the caller's time domain.
  const parentOriginMs = Number(process.hrtime.bigint()) / 1e6 - performance.now();
  const child = fork(fileURLToPath(new URL('./peer-process-child.ts', import.meta.url)), [], {
    execArgv: [], stdio: ['ignore', 'ignore', 'inherit', 'ipc'], serialization: 'advanced',
  });
  const exited = Promise.withResolvers<number | null>();
  const pending = new Map<number, { resolve(value: PeerResult): void; reject(error: Error): void }>();
  let nextId = 0;
  const fail = (error: Error) => {
    for (const reply of pending.values()) reply.reject(error);
    pending.clear();
  };
  child.on('error', fail);
  child.once('disconnect', () => fail(Error('Far-end peer disconnected')));
  child.once('exit', (code, signal) => {
    fail(Error(`Far-end peer exited (${code ?? signal})`));
    exited.resolve(code);
  });
  child.once('close', code => exited.resolve(code));
  child.on('message', (response: PeerResponse) => {
    const reply = pending.get(response.id);
    if ('error' in response) reply?.reject(response.error);
    else reply?.resolve(response.value);
  });
  async function call<K extends PeerCommand>(command: K, ...args: Parameters<PeerOperations[K]>): Promise<Awaited<ReturnType<PeerOperations[K]>>> {
    if (!child.connected) throw Error('Far-end peer disconnected');
    const id = ++nextId;
    const reply = Promise.withResolvers<PeerResult>();
    pending.set(id, reply);
    try {
      child.send({ id, command, args }, error => { if (error) reply.reject(error); });
      const value = await deadline(50_000, `Far-end peer ${command}`, () => reply.promise);
      // SAFETY: The peer replies to this request ID with the result of the matching command.
      return value as Awaited<ReturnType<PeerOperations[K]>>;
    } finally { pending.delete(id); }
  }
  const abort = () => { if (child.connected) child.disconnect(); };
  async function join() {
    abort();
    try {
      const code = await deadline(12_000, 'Far-end peer exit', () => exited.promise);
      if (code !== 0) throw Error(`Far-end peer stopped with exit code ${code}`);
    } catch (error) { await stopChild(child); throw error; }
  }
  let stopped: Promise<void> | undefined;
  const close = () => stopped ??= (async () => {
    try {
      if (child.connected) await deadline(12_000, 'Far-end peer cleanup', () => call('close'));
    } finally { await join(); }
  })();
  try { await call('connect', credentials, options, serverPid, parentOriginMs); }
  catch (error) {
    await close().catch(() => {});
    throw error;
  }
  return {
    status: () => call('status'),
    lifecycle: () => call('lifecycle'),
    observation: () => call('observation'),
    downlinkPacing: () => call('downlinkPacing'),
    act: (action: Parameters<PeerOperations['act']>[0]) => call('act', action),
    async renewAudioPublication(observeRetired: (retired: string) => Promise<void>) {
      const retired = await call('retireAudio');
      await observeRetired(retired);
      return call('replaceAudio', retired);
    },
    receiverWindows: (deadlineMs: number) => call('receiverWindows', deadlineMs),
    async silence(options: Parameters<PeerOperations['silence']>[0]) {
      const { windows, reason } = await call('silence', options);
      if (reason) throw new SilenceObservationError(reason, windows);
      return windows;
    },
    heldSilence: (...args: Parameters<PeerOperations['heldSilence']>) => call('heldSilence', ...args),
    async openVideo(fixtureId: string, clockID: string) {
      const id = await call('openVideo', fixtureId, clockID);
      return {
        observe: (participant: string, epoch: number) => call('observeVideo', id, participant, epoch),
        publish: (epoch: number) => call('publishVideo', id, epoch),
        hold: () => call('holdVideo', id),
        freeze: () => call('freezeVideo', id),
        stop: () => call('stopVideo', id),
        observation: () => call('videoObservation', id),
        snapshot: () => call('videoSnapshot', id),
        status: () => call('videoStatus', id),
      };
    },
    abort,
    close,
  };
}
