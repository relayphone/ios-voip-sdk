// ActivityKit payload construction and bounded staging sender for the disposable
// Focus probe. Push-to-start is alerting and requires an explicit opt-in.
import { randomUUID } from 'node:crypto';
import { readFileSync, realpathSync, writeFileSync } from 'node:fs';
import { connect } from 'node:http2';
import { pathToFileURL } from 'node:url';
import { loadSigningKey, providerToken } from '../../discovery/send-apns.mjs';

const MAX_BYTES = 4096;
const DEFAULT_SURFACE = '00000000-0000-4000-8000-000000000001';
const TOPIC = 'dev.callkitsim.focus.push-type.liveactivity';
const byteCount = value => Buffer.byteLength(JSON.stringify(value), 'utf8');

/** A per-activity token is usable only with the matching current registration. */
export function validateRegistration(token, registration) {
  const keys = ['activityID', 'surfaceID', 'tokenGeneration'];
  return Boolean(token && registration && typeof token.token === 'string' &&
    /^(?:[a-fA-F0-9]{2}){32,256}$/.test(token.token) &&
    keys.every(key => typeof token[key] === 'string' && token[key] && token[key] === registration[key]) &&
    ['active', 'stale'].includes(registration.state) && token.state === registration.state);
}

export function validateStartToken(token) {
  return Boolean(token && typeof token.token === 'string' && /^(?:[a-fA-F0-9]{2}){32,256}$/.test(token.token) &&
    typeof token.tokenGeneration === 'string' && token.tokenGeneration.length > 0);
}

/** Synthetic L10 negative control. It cannot be an exported activity token. */
export function validateInvalidTokenFixture(token, registration) {
  return validateRegistration(token, registration) && token.token === '00'.repeat(32) &&
    token.activityID === 'synthetic-invalid-token' &&
    /^synthetic-invalid-[A-Za-z0-9-]{1,80}$/.test(token.tokenGeneration);
}

export function expectedInvalidTokenRejection(status, reason) {
  return (status === 400 && ['BadDeviceToken', 'DeviceTokenNotForTopic'].includes(reason)) ||
    (status === 410 && reason === 'Unregistered');
}

function requireInteger(name, value, min, max = Number.MAX_SAFE_INTEGER) {
  if (!Number.isSafeInteger(value) || value < min || value > max) throw new Error(`Invalid ${name}`);
}

/** Make a single synthetic ActivityKit payload; the caller chooses a unique revision. */
export function buildPayload({ event = 'update', timestamp, revision = 1,
  excerpt = 'Synthetic caller: APNs update', surfaceID = DEFAULT_SURFACE,
  staleAfter = 30, alertAllowed = false, fit = false, sessionID } = {}) {
  if (!['start', 'update', 'end'].includes(event)) throw new Error('Invalid event');
  requireInteger('timestamp', timestamp, 1, Number.MAX_SAFE_INTEGER - 86400);
  requireInteger('revision', revision, 0);
  requireInteger('staleAfter', staleAfter, 1, 86400);
  if (typeof excerpt !== 'string' || typeof surfaceID !== 'string' ||
      !/^[A-Fa-f0-9-]{1,128}$/.test(surfaceID)) throw new Error('Invalid synthetic content');
  if (sessionID !== undefined && (typeof sessionID !== 'string' ||
      !/^focus-synthetic-[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$/.test(sessionID)))
    throw new Error('Invalid synthetic session');
  if (event === 'start' && !alertAllowed) throw new Error('Push-to-start requires explicit alert authorization');

  const attributes = { surfaceID };
  function payloadFor(text) {
    const state = { revision, excerpt: text, updatedAt: timestamp };
    if (sessionID !== undefined) state.sessionID = sessionID;
    const aps = { timestamp, event, 'content-state': state };
    if (event === 'start') {
      aps['attributes-type'] = 'FocusAttributes';
      aps.attributes = attributes;
      aps['input-push-token'] = 1;
      aps.alert = { title: 'Focus Probe', body: 'Synthetic Live Activity started' };
    }
    if (event === 'end') aps['dismissal-date'] = timestamp;
    else aps['stale-date'] = timestamp + staleAfter;
    return { aps };
  }
  function valid(text) {
    const payload = payloadFor(text);
    return byteCount(payload) <= MAX_BYTES && byteCount({ attributes, state: payload.aps['content-state'] }) <= MAX_BYTES;
  }
  let output = excerpt;
  let truncated = false;
  if (!valid(output)) {
    if (!fit) throw new Error('Live Activity payload exceeds 4 KB');
    const characters = Array.from(excerpt);
    let lower = 0, upper = characters.length;
    while (lower < upper) {
      const middle = Math.ceil((lower + upper) / 2);
      if (valid(characters.slice(0, middle).join(''))) lower = middle;
      else upper = middle - 1;
    }
    output = characters.slice(0, lower).join('');
    truncated = true;
    if (!valid(output)) throw new Error('Fixed payload exceeds 4 KB');
  }
  const payload = payloadFor(output);
  return { payload, bytes: byteCount(payload), stateBytes: byteCount({ attributes, state: payload.aps['content-state'] }), truncated };
}

/** Plan a bounded staging cadence, not an Apple delivery or budget guarantee. */
export function buildCadence({ count, intervalMs, priority = 5, firstTimestamp }) {
  requireInteger('count', count, 1, 60);
  requireInteger('intervalMs', intervalMs, 1000, 60000);
  requireInteger('firstTimestamp', firstTimestamp, 1, Number.MAX_SAFE_INTEGER - 3600);
  if (![5, 10].includes(priority)) throw new Error('Priority must be 5 or 10');
  return Array.from({ length: count }, (_, index) => ({
    offsetMs: index * intervalMs,
    timestamp: firstTimestamp + Math.floor(index * intervalMs / 1000),
    revision: index + 1,
    priority,
  }));
}

/** Offline reconciliation fixture only: acceptance never means a rendered card. */
export function simulateProjection(events) {
  let tokenVersion = 0, currentToken = null, latestRevision = -1, renderedRevision = null, ended = false;
  const decisions = [];
  for (const event of events) {
    if (event.type === 'register') {
      requireInteger('tokenVersion', event.version, 1);
      if (typeof event.tokenID !== 'string' || !event.tokenID) throw new Error('Synthetic token ID required');
      const accepted = !ended && event.version > tokenVersion;
      if (accepted) { tokenVersion = event.version; currentToken = event.tokenID; }
      decisions.push({ type: 'register', accepted, version: event.version });
    } else if (event.type === 'snapshot') {
      requireInteger('revision', event.revision, 0);
      const accepted = !ended && event.revision > latestRevision;
      if (accepted) latestRevision = event.revision;
      decisions.push({ type: 'snapshot', accepted, revision: event.revision });
    } else if (event.type === 'apnsAccepted') {
      decisions.push({ type: 'apnsAccepted', rendered: false });
    } else if (event.type === 'rendered') {
      requireInteger('revision', event.revision, 0);
      const accepted = !ended && event.revision === latestRevision;
      if (accepted) renderedRevision = event.revision;
      decisions.push({ type: 'rendered', accepted, revision: event.revision });
    } else if (event.type === 'end') {
      ended = true; currentToken = null;
      decisions.push({ type: 'end', accepted: true });
    } else throw new Error('Unknown simulated event');
  }
  return { mode: 'offline simulation, not device evidence', tokenVersion, currentToken,
    latestRevision, renderedRevision, ended, decisions };
}

/** Offline retry/backoff fixture. This does not send APNs or claim delivery. */
export function simulateBackoff({ revisions, attempts, initialDelayMs = 1000, maxDelayMs = 16000 }) {
  if (!Array.isArray(revisions) || revisions.length < 1 || revisions.length > 60) throw new Error('Invalid revisions');
  for (const revision of revisions) requireInteger('revision', revision, 0);
  requireInteger('attempts', attempts, 1, 6);
  requireInteger('initialDelayMs', initialDelayMs, 1, 60000);
  requireInteger('maxDelayMs', maxDelayMs, initialDelayMs, 60000);
  const latestRevision = Math.max(...revisions);
  let offsetMs = 0;
  const planned = [];
  for (let index = 0; index < attempts; index++) {
    if (index > 0) offsetMs += Math.min(initialDelayMs * 2 ** (index - 1), maxDelayMs);
    planned.push({ attempt: index + 1, offsetMs, revision: latestRevision });
  }
  return { mode: 'offline simulation, not device evidence', coalescedRevision: latestRevision, planned };
}

function parseArgs(args) {
  const values = {};
  const flags = new Set(['--dry-run', '--allow-alert', '--fit', '--test-invalid-token']);
  const allowed = new Set(['--event', '--timestamp', '--revision', '--excerpt', '--surface-id', '--session-id', '--stale-after', '--priority', '--token-file', '--registration-file', '--receipt-file']);
  for (let i = 0; i < args.length; i++) {
    const key = args[i];
    if (Object.hasOwn(values, key)) throw new Error('Duplicate option');
    if (flags.has(key)) values[key] = true;
    else if (allowed.has(key) && i + 1 < args.length) values[key] = args[++i];
    else throw new Error('Invalid option');
  }
  return values;
}

async function send(payload, token, priority, requestID, auth) {
  return await new Promise((resolve, reject) => {
    const client = connect('https://api.sandbox.push.apple.com');
    let done = false;
    function finish(error, value) {
      if (done) return;
      done = true; clearTimeout(timer); client.destroy();
      error ? reject(error) : resolve(value);
    }
    const timer = setTimeout(() => finish(new Error('APNs timeout')), 20000);
    client.on('error', () => finish(new Error('APNs transport failure')));
    let response = { status: 'unknown', apnsID: null }, responseSize = 0;
    const responseChunks = [];
    const request = client.request({ ':method': 'POST', ':path': `/3/device/${token}`,
      authorization: auth, 'apns-id': requestID, 'apns-topic': TOPIC,
      'apns-push-type': 'liveactivity', 'apns-priority': String(priority) });
    request.on('response', headers => { response = { status: headers[':status'], apnsID: headers['apns-id'] }; });
    request.on('data', chunk => {
      responseSize += chunk.length;
      if (responseSize <= 4096) responseChunks.push(chunk);
    });
    request.on('error', () => finish(new Error('APNs transport failure')));
    request.on('end', () => {
      // Retain only documented non-sensitive classifications, never arbitrary APNs bodies.
      try {
        const value = JSON.parse(Buffer.concat(responseChunks).toString('utf8'));
        if (['BadDeviceToken', 'DeviceTokenNotForTopic', 'Unregistered'].includes(value.reason)) response.reason = value.reason;
      } catch { /* Success response or unrecognized/malformed failure body. */ }
      finish(null, response);
    });
    request.end(Buffer.from(JSON.stringify(payload)));
  });
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const event = options['--event'] || 'update';
  const priority = Number(options['--priority'] || 5);
  if (![5, 10].includes(priority)) throw new Error('Priority must be 5 or 10');
  const invalidControl = Boolean(options['--test-invalid-token']);
  if (invalidControl && (event !== 'update' || priority !== 5 || options['--allow-alert']))
    throw new Error('Synthetic invalid-token control is a silent priority-5 update only');
  const timestamp = Number(options['--timestamp'] || Math.floor(Date.now() / 1000));
  const revision = Number(options['--revision'] || 1);
  function readCurrentToken() {
    const token = JSON.parse(readFileSync(options['--token-file'], 'utf8'));
    if (event === 'start') {
      if (options['--registration-file'] || !validateStartToken(token)) throw new Error('Invalid push-to-start token');
    } else {
      if (!options['--registration-file']) throw new Error('Current activity registration required');
      const registration = JSON.parse(readFileSync(options['--registration-file'], 'utf8'));
      if (!validateRegistration(token, registration)) throw new Error('Activity token registration mismatch');
      if (invalidControl ? !validateInvalidTokenFixture(token, registration) : token.token === '00'.repeat(32))
        throw new Error('Invalid-token fixture is not explicitly qualified');
    }
    return token;
  }
  let tokenData;
  if (!options['--dry-run']) {
    if (!options['--token-file'] || !options['--receipt-file']) throw new Error('Private token and receipt files required');
    tokenData = readCurrentToken();
    if (event !== 'start' && options['--surface-id'] && options['--surface-id'] !== tokenData.surfaceID)
      throw new Error('Activity surface mismatch');
  }
  const surfaceID = options['--surface-id'] || (event !== 'start' && tokenData?.surfaceID) || (options['--dry-run'] ? DEFAULT_SURFACE : randomUUID());
  const result = buildPayload({ event, timestamp, revision, surfaceID,
    excerpt: options['--excerpt'] || 'Synthetic caller: APNs update',
    staleAfter: Number(options['--stale-after'] || 30), alertAllowed: Boolean(options['--allow-alert']),
    fit: Boolean(options['--fit']), sessionID: options['--session-id'] });
  if (options['--dry-run']) {
    console.log(JSON.stringify({ ...result, priority, topic: TOPIC, simulated: true, invalidTokenControl: invalidControl })); return;
  }
  const auth = `bearer ${providerToken(loadSigningKey())}`;
  // Re-read both files after signing; never send an observed stale or cross-activity token.
  const latest = readCurrentToken();
  if (latest.token !== tokenData.token || latest.tokenGeneration !== tokenData.tokenGeneration ||
      latest.surfaceID !== tokenData.surfaceID || latest.activityID !== tokenData.activityID)
    throw new Error('Activity token changed before send');
  const requestID = randomUUID();
  const receipt = options['--receipt-file'];
  const base = { status: 'unknown', requestID, event, priority, bytes: result.bytes, surfaceID,
    timestamp, revision, truncated: result.truncated, deliveryConfirmed: false, invalidTokenControl: invalidControl };
  // Reserve before transport; a crash or ambiguous response must not be retried blindly.
  writeFileSync(receipt, JSON.stringify(base), { flag: 'wx', mode: 0o600 });
  const response = await send(result.payload, tokenData.token, priority, requestID, auth);
  const outcome = { ...base, status: response?.status ?? 'unknown', apnsID: response?.apnsID ?? null,
    reason: response?.reason ?? null,
    expectedRejection: invalidControl && expectedInvalidTokenRejection(response?.status, response?.reason) };
  writeFileSync(receipt, JSON.stringify(outcome), { mode: 0o600 });
  const acknowledged = String(outcome.apnsID).toLowerCase() === requestID.toLowerCase();
  if (!acknowledged || (invalidControl ? !outcome.expectedRejection : outcome.status !== 200))
    throw new Error('APNs did not return the expected response');
}

if (process.argv[1] && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href) {
  main().catch(() => { console.error('ActivityKit send failed or outcome unknown; inspect private receipt; do not resend automatically.'); process.exitCode = 1; });
}
