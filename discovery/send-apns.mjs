#!/usr/bin/env node
// Sandbox-only research sender. Credentials and device tokens never enter argv or output.
import { closeSync, openSync, readFileSync, realpathSync, writeFileSync } from 'node:fs';
import { createPrivateKey, createPublicKey, randomUUID, sign, verify } from 'node:crypto';
import { connect } from 'node:http2';
import { pathToFileURL } from 'node:url';

export function loadSigningKey(env = process.env) {
  if (env.PHONE_APNS_ENVIRONMENT !== 'sandbox') {
    throw new Error('PHONE_APNS_ENVIRONMENT must explicitly be sandbox.');
  }
  for (const name of ['PHONE_APNS_KEY_ID', 'PHONE_APNS_TEAM_ID']) {
    if (!/^[A-Z0-9]{10}$/.test(env[name] ?? '')) throw new Error(`Invalid ${name}.`);
  }
  if (Boolean(env.PHONE_APNS_KEY_PATH) === Boolean(env.PHONE_APNS_KEY_P8)) {
    throw new Error('Set exactly one of PHONE_APNS_KEY_PATH and PHONE_APNS_KEY_P8.');
  }
  let key;
  try {
    key = createPrivateKey(env.PHONE_APNS_KEY_PATH
      ? readFileSync(env.PHONE_APNS_KEY_PATH)
      : env.PHONE_APNS_KEY_P8);
  } catch {
    throw new Error('Could not read an APNs private key.');
  }
  if (key.asymmetricKeyType !== 'ec' || key.asymmetricKeyDetails.namedCurve !== 'prime256v1') {
    throw new Error('APNs requires an EC P-256 key.');
  }
  return key;
}

export function providerToken(key, env = process.env) {
  const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');
  const content = `${encode({ alg: 'ES256', kid: env.PHONE_APNS_KEY_ID })}.${encode({
    iss: env.PHONE_APNS_TEAM_ID, iat: Math.floor(Date.now() / 1000),
  })}`;
  const signature = sign('sha256', Buffer.from(content), { key, dsaEncoding: 'ieee-p1363' });
  if (!verify('sha256', Buffer.from(content), {
    key: createPublicKey(key), dsaEncoding: 'ieee-p1363',
  }, signature)) throw new Error('Local ES256 signature verification failed.');
  return `${content}.${signature.toString('base64url')}`;
}

export async function sendPush({ key, tokenFile, payloadFile, topic }, env = process.env) {
  if (env.PHONE_APNS_ENVIRONMENT !== 'sandbox') throw new Error('Sandbox environment required.');
  if (!/^[A-Za-z0-9.-]+\.voip$/.test(topic)) throw new Error('A full .voip topic is required.');
  let deviceToken, body;
  try {
    deviceToken = readFileSync(tokenFile, 'utf8').trim();
    if (!/^(?:[A-Fa-f0-9]{2}){32,256}$/.test(deviceToken)) throw new Error();
    body = readFileSync(payloadFile);
    const payload = JSON.parse(body.toString('utf8'));
    if (!payload || typeof payload !== 'object' || Array.isArray(payload)) throw new Error();
    if (!payload.aps || typeof payload.aps !== 'object' || Array.isArray(payload.aps)) throw new Error();
    if (body.length > 5120) throw new Error();
  } catch {
    throw new Error('Invalid token file or VoIP JSON payload (requires aps; maximum 5120 bytes).');
  }
  const authorization = `bearer ${providerToken(key, env)}`;
  const apnsID = randomUUID();
  return await new Promise((resolve, reject) => {
    const client = connect('https://api.sandbox.push.apple.com');
    let settled = false;
    let request;
    const finish = (error, result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      request?.close();
      client.destroy();
      if (error) {
        error.receipt = { time: new Date().toISOString(), environment: 'sandbox', topic,
          status: 'unknown', requestedAPNsID: apnsID, deliveryConfirmed: false };
        reject(error);
      } else resolve(result);
    };
    const timer = setTimeout(() => finish(new Error(
      'APNs request timed out; delivery outcome is unknown. Do not retry automatically.',
    )), 20000);
    client.on('error', () => finish(new Error('APNs transport failed; delivery outcome may be unknown.')));
    client.once('connect', () => {
      request = client.request({
        ':method': 'POST', ':path': `/3/device/${deviceToken}`,
        authorization, 'apns-topic': topic, 'apns-push-type': 'voip',
        'apns-priority': '10', 'apns-expiration': '0', 'apns-id': apnsID,
        'content-type': 'application/json',
      });
      let headers, response = '';
      request.on('response', value => { headers = value; });
      request.setEncoding('utf8');
      request.on('data', data => { if (response.length < 16384) response += data; });
      request.on('error', () => finish(new Error('APNs stream failed; delivery outcome may be unknown.')));
      request.on('end', () => {
        if (!headers) return finish(new Error('APNs closed without a response; delivery outcome is unknown.'));
        let reason;
        try { reason = JSON.parse(response).reason; } catch { /* Successful responses have no body. */ }
        finish(null, {
          time: new Date().toISOString(), environment: 'sandbox', topic,
          status: headers[':status'], apnsID: headers['apns-id'], requestedAPNsID: apnsID,
          // Never echo an arbitrary response or request, even on failure.
          ...(typeof reason === 'string' && /^[A-Za-z]{1,80}$/.test(reason) ? { reason } : {}),
          deliveryConfirmed: false,
        });
      });
      request.end(body);
    });
  });
}

async function main() {
  const args = process.argv.slice(2);
  const key = loadSigningKey();
  if (args.length === 1 && args[0] === '--check-key') {
    providerToken(key);
    console.log(JSON.stringify({ keyReadable: true, curve: 'P-256', localES256Verified: true,
      environment: 'sandbox', apnsAuthenticated: false }));
    return;
  }
  const options = {};
  for (let i = 0; i < args.length; i += 2) {
    if (!['--token-file', '--payload-file', '--topic', '--receipt-file'].includes(args[i]) || !args[i + 1]) {
      throw new Error('Usage: send-apns.mjs --check-key | --token-file PATH --payload-file PATH --topic BUNDLE.voip [--receipt-file PATH]');
    }
    if (options[args[i]]) throw new Error('Duplicate option.');
    options[args[i]] = args[i + 1];
  }
  let receipt;
  if (options['--receipt-file']) {
    try { receipt = openSync(options['--receipt-file'], 'wx', 0o600); }
    catch { throw new Error('Could not reserve receipt file; no push was sent.'); }
  }
  try {
    let result;
    try {
      result = await sendPush({ key, tokenFile: options['--token-file'],
        payloadFile: options['--payload-file'], topic: options['--topic'] });
    } catch (error) {
      if (error.receipt) {
        console.log(JSON.stringify(error.receipt));
        if (receipt !== undefined) {
          try { writeFileSync(receipt, `${JSON.stringify(error.receipt, null, 2)}\n`); }
          catch { console.error('Unknown APNs outcome printed above; receipt write failed.'); }
        }
      }
      throw error;
    }
    // Preserve the externally visible outcome even if receipt persistence later fails.
    console.log(JSON.stringify(result));
    if (receipt !== undefined) {
      try { writeFileSync(receipt, `${JSON.stringify(result, null, 2)}\n`); }
      catch { throw new Error('APNs outcome printed above; receipt write failed. Do not resend automatically.'); }
    }
    if (result.status !== 200 || result.apnsID?.toLowerCase() !== result.requestedAPNsID.toLowerCase()) {
      process.exitCode = 1;
    }
  } finally {
    if (receipt !== undefined) closeSync(receipt);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href) {
  main().catch(error => { console.error(error.message); process.exitCode = 1; });
}
