import { Worker } from 'node:worker_threads';
import type { MediaMarker } from '../../expo/src/testing/types.ts';
import { measureMarker, type PCMCapture } from './marker-evidence.ts';
import { deadline } from './fixture-runtime.ts';

/** Analysis must not starve the publisher/receiver packet clock. Always terminate its worker. */
export async function measureMarkerAsync(capture: PCMCapture, marker: MediaMarker): Promise<ReturnType<typeof measureMarker>> {
  const worker = new Worker(new URL('./marker-worker.ts', import.meta.url), { workerData: { capture, marker }, execArgv: [] });
  try {
    return await deadline(20_000, 'Marker analysis', () => new Promise((resolve, reject) => {
      worker.once('message', resolve);
      worker.once('error', reject);
      worker.once('exit', code => reject(new Error(`Marker worker exited before a result (${code})`)));
    }));
  } finally { await deadline(5000, 'Marker worker cleanup', () => worker.terminate()); }
}
