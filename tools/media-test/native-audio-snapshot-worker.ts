import { parentPort, workerData } from 'node:worker_threads';

if (!parentPort) throw Error('Native audio snapshot decoding requires an owned worker');

function object(value: unknown): value is Record<string, unknown> {
  return !!value && typeof value === 'object' && !Array.isArray(value);
}

const reply: unknown = JSON.parse(new TextDecoder().decode(workerData as ArrayBuffer));
const transfer: ArrayBuffer[] = [];
if (object(reply)) {
  for (const stage of ['decoded', 'output'] as const) {
    const audio = reply[stage];
    if (!object(audio) || !object(audio.pcm) || !Array.isArray(audio.pcm.channels) ||
        !audio.pcm.channels.every(Array.isArray)) continue;
    audio.pcm.channels = audio.pcm.channels.map(samples => {
      const pcm = Float32Array.from(samples as number[]);
      transfer.push(pcm.buffer);
      return pcm;
    });
  }
}
parentPort.postMessage(reply, transfer);
