// Silent sandbox update only. Authentication implementation is shared with the existing VoIP sender.
import { readFileSync, writeFileSync } from 'node:fs';
import { connect } from 'node:http2';
import { loadSigningKey, providerToken } from '../../discovery/send-apns.mjs';
const args = process.argv.slice(2);
const options = Object.fromEntries(Array.from({ length: args.length / 2 }, (_, i) => [args[i * 2], args[i * 2 + 1]]));
try {
  const registration = JSON.parse(readFileSync(options['--token-file'], 'utf8'));
  if (!/^(?:[a-fA-F0-9]{2}){32,256}$/.test(registration.token)) throw Error();
  const timestamp = Math.floor(Date.now() / 1000);
  const payload = Buffer.from(JSON.stringify({ aps: { timestamp, event: 'update',
    'content-state': { revision: timestamp, excerpt: 'Synthetic caller: APNs update', updatedAt: timestamp },
    'stale-date': timestamp + 30 } }));
  if (payload.length > 4096) throw Error();
  const authorization = `bearer ${providerToken(loadSigningKey())}`;
  const receipt = options['--receipt-file'];
  // Reserve before sending. Uncertain delivery is never automatically retried.
  writeFileSync(receipt, JSON.stringify({ status: 'unknown', deliveryConfirmed: false }), { flag: 'wx', mode: 0o600 });
  const result = await new Promise((resolve, reject) => {
    const client = connect('https://api.sandbox.push.apple.com');
    const timer = setTimeout(() => { client.destroy(); reject(Error()); }, 20000);
    client.on('error', () => { clearTimeout(timer); client.destroy(); reject(Error()); });
    const request = client.request({ ':method': 'POST', ':path': `/3/device/${registration.token}`, authorization,
      'apns-topic': 'dev.callkitsim.focus.push-type.liveactivity', 'apns-push-type': 'liveactivity', 'apns-priority': '5' });
    let status;
    request.on('response', headers => { status = headers[':status']; });
    request.on('data', () => {});
    request.on('error', () => { clearTimeout(timer); client.destroy(); reject(Error()); });
    request.on('end', () => { clearTimeout(timer); client.destroy(); resolve({ status, deliveryConfirmed: false, timestamp }); });
    request.end(payload);
  });
  writeFileSync(receipt, JSON.stringify(result), { mode: 0o600 });
  if (result.status !== 200) process.exitCode = 1;
} catch { console.error('ActivityKit update failed or outcome unknown; inspect private receipt; do not resend automatically.'); process.exitCode = 1; }
