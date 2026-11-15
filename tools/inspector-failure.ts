// Retains read-only runtime evidence after a journey failure, before simulator cleanup.
import { constants, closeSync, fstatSync, openSync, readSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { run } from './command.ts';

/** Reads only regular files, with a fixed allocation even when a live journal is growing. */
function boundedFile(path: string, limit: number, tail: boolean): Buffer {
  const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    const stat = fstatSync(fd);
    if (!stat.isFile() || (!tail && stat.size > limit)) throw new Error('Unsafe or oversized evidence file');
    const start = tail ? Math.max(0, stat.size - limit) : 0;
    const bytes = Buffer.alloc(Math.min(stat.size, limit));
    const count = readSync(fd, bytes, 0, bytes.length, start);
    const result = bytes.subarray(0, count);
    if (start === 0) return result;
    // The oldest retained line may start partway through a JSON row.
    const newline = result.indexOf(10);
    return newline < 0 ? Buffer.alloc(0) : result.subarray(newline + 1);
  } finally { closeSync(fd); }
}

/** Copies the current session and journal tail without a mailbox command or target mutation. */
export function captureInspectorJournal(container: string, bundle: string, prefix: string): void {
  const channel = join(container, 'Documents/.callkit-simulator');
  const bytes = boundedFile(join(channel, 'session.json'), 64 * 1024, false);
  const session = JSON.parse(bytes.toString('utf8')) as {
    schemaVersion?: unknown; bundleID?: unknown; runID?: unknown; pid?: unknown;
  };
  if (session.schemaVersion !== 1 || session.bundleID !== bundle
    || typeof session.runID !== 'string' || !/^[A-Za-z0-9_-]{1,64}$/.test(session.runID)
    || typeof session.pid !== 'number' || !Number.isSafeInteger(session.pid) || session.pid <= 0) {
    throw new Error('Invalid current runtime identity for failure evidence');
  }
  writeFileSync(`${prefix}-current-session.json`, bytes);
  writeFileSync(`${prefix}-runtime-tail.jsonl`, boundedFile(join(channel, session.runID, 'events.jsonl'), 256 * 1024, true));
}

/** Capture failures are diagnostic only and never replace or retry the original journey failure. */
export function captureInspectorFailure(device: string, bundle: string, prefix: string, execute: typeof run = run): void {
  try {
    const container = execute('xcrun', ['simctl', 'get_app_container', device, bundle, 'data'], { timeout: 10 });
    captureInspectorJournal(container, bundle, prefix);
  } catch (error) {
    try { writeFileSync(`${prefix}-journal-capture.log`, Buffer.from(String(error)).subarray(0, 4096)); }
    catch { console.warn('warning: could not retain Inspector failure evidence'); }
  }
}
