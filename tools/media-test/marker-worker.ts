import { parentPort, workerData } from 'node:worker_threads';
import { measureMarker, type PCMCapture } from './marker-evidence.ts';
import type { MediaMarker } from '../../expo/src/testing/types.ts';

const data = workerData as { capture: PCMCapture; marker: MediaMarker };
if (!parentPort) throw new Error('Marker analysis requires an owned worker');
parentPort.postMessage(measureMarker(data.capture, data.marker));
