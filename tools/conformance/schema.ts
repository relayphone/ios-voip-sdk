import { readFileSync } from 'node:fs';
import { isList, isRecord, isString } from '../json-fields.ts';
import type { Budgets, Journey, Model, Transitions, WireID } from './model.ts';

type Schema = Readonly<{ $schema?: string; $id?: string; $defs?: Readonly<Record<string, Schema>>;
  $ref?: string; type?: 'object' | 'array' | 'string' | 'integer' | 'boolean'; const?: unknown;
  enum?: readonly unknown[]; oneOf?: readonly Schema[]; properties?: Readonly<Record<string, Schema>>;
  required?: readonly string[]; additionalProperties?: false; items?: Schema; minItems?: number;
  minLength?: number; maxLength?: number; pattern?: string; minimum?: number; maximum?: number }>;
function loadSchema(path: string) {
  // SAFETY: These repository-owned documents declare the Schema subset checked by audit.
  return JSON.parse(readFileSync(new URL(path, import.meta.url), 'utf8')) as Schema;
}
const schema = loadSchema('../../spec/model.schema.json');
let schemaV1: Schema | undefined;
let bridgeSchema: Schema | undefined;
let httpAuthoritySchema: Schema | undefined;
const versionOne = () => schemaV1 ??= loadSchema('../../spec/v1/model.schema.json');
const httpAuthority = () => httpAuthoritySchema ??= loadSchema('../../spec/v1/http-authority.schema.json');
const keywords = new Set(['$schema', '$id', '$defs', '$ref', 'type', 'const', 'enum', 'oneOf', 'properties',
  'required', 'additionalProperties', 'items', 'minItems', 'minLength', 'maxLength', 'pattern', 'minimum', 'maximum']);

function audit(rule: Schema, root: Schema, seen = new Set<Schema>()) {
  if (seen.has(rule)) return;
  seen.add(rule);
  for (const key of Object.keys(rule)) if (!keywords.has(key)) throw new Error(`Unsupported schema keyword: ${key}`);
  if (rule.type && !['object', 'array', 'string', 'integer', 'boolean'].includes(rule.type)) throw new Error('Unsupported schema type');
  if ('additionalProperties' in rule && rule.additionalProperties !== false) throw new Error('Unsupported additionalProperties policy');
  if (rule.$ref) {
    const [target, targetRoot] = referenced(rule.$ref, root);
    audit(target, targetRoot, seen);
  }
  for (const child of [...Object.values(rule.$defs ?? {}), ...Object.values(rule.properties ?? {}), ...(rule.oneOf ?? []), ...(rule.items ? [rule.items] : [])]) audit(child, root, seen);
}
function referenced(reference: string, root: Schema) {
  const [document, name, extra] = reference.split('#/$defs/');
  const target = document === '' ? root : document === schema.$id ? schema
    : document === versionOne().$id ? versionOne()
    : document === httpAuthority().$id ? httpAuthority() : undefined;
  const definitions = target?.$defs;
  const rule = name && definitions && Object.hasOwn(definitions, name) ? definitions[name] : undefined;
  if (!rule || !target || extra !== undefined) {
    throw new Error(`Unknown schema reference: ${reference}`);
  }
  return [rule, target] as const;
}
/** Checks the declared JSON Schema subset without accepting unknown keywords in unused branches. */
export function validate(value: unknown, rule: Schema = schema, path = '$') {
  audit(rule, schema);
  visit(value, rule, path, schema);
}
export function validateV1(value: unknown, definition?: string) {
  validateDocument(value, versionOne(), definition);
}
export function validateBridge(value: unknown, definition?: 'snapshot' | 'frame' | 'command' | 'reply') {
  bridgeSchema ??= loadSchema('../../spec/bridge.schema.json');
  validateDocument(value, bridgeSchema, definition);
}
export function validateHTTPAuthority(value: unknown) {
  validateDocument(value, httpAuthority());
}
function validateDocument(value: unknown, root: Schema, definition?: string) {
  const rule = definition === undefined ? root : { $ref: `#/$defs/${definition}` };
  audit(rule, root);
  visit(value, rule, '$', root);
}
function isPlainRecord(value: unknown): value is object {
  return isRecord(value) && [null, Object.prototype].includes(Object.getPrototypeOf(value));
}
function isBoolean(value: unknown): value is boolean {
  return typeof value === 'boolean';
}
function isNumber(value: unknown): value is number {
  return typeof value === 'number';
}

/** The schema intentionally uses this small, fail-closed JSON Schema subset; no external validator. */
function visit(value: unknown, rule: Schema, path: string, root: Schema) {
  const fail = (): never => { throw new Error(`Invalid conformance value at ${path}`); };
  if (rule.$ref) {
    const [target, targetRoot] = referenced(rule.$ref, root);
    visit(value, target, path, targetRoot);
  }
  if ('const' in rule && value !== rule.const) fail();
  if (rule.enum && !rule.enum.includes(value)) fail();
  if (rule.oneOf) {
    const matches = rule.oneOf.filter(option => { try { visit(value, option, path, root); return true; } catch { return false; } });
    if (matches.length !== 1) fail();
  }
  switch (rule.type) {
    case 'object': {
      if (!isPlainRecord(value)) return fail();
      for (const key of rule.required ?? []) if (!Object.hasOwn(value, key)) fail();
      const entries: [string, unknown][] = Object.entries(value);
      for (const [key, entry] of entries) {
        const child = rule.properties && Object.hasOwn(rule.properties, key) ? rule.properties[key] : undefined;
        if (child) visit(entry, child, `${path}.${key}`, root);
        else if (rule.additionalProperties === false) fail();
      }
      break;
    }
    case 'array': {
      if (!isList(value) || value.length < (rule.minItems ?? 0)) return fail();
      const { items } = rule;
      if (items) value.forEach((item, i) => visit(item, items, `${path}[${i}]`, root));
      break;
    }
    case 'string': {
      if (!isString(value)) return fail();
      const length = [...value].length;
      if (length < (rule.minLength ?? 0) || length > (rule.maxLength ?? Infinity)) fail();
      if (rule.pattern && !new RegExp(rule.pattern, 'u').test(value)) fail();
      break;
    }
    case 'integer':
      if (!isNumber(value) || !Number.isSafeInteger(value) || value < (rule.minimum ?? -Infinity) || value > (rule.maximum ?? Infinity)) fail();
      break;
    case 'boolean': if (!isBoolean(value)) fail(); break;
  }
}

/** Validates an exact wire identifier before it enters a typed record; never trims it. */
export function wireID(value: string) {
  validate(value, { $ref: '#/$defs/id' });
  // SAFETY: The ID schema has checked the full string before adding the brand.
  return value as WireID;
}
/** Returns deterministic JSON without normalizing identifier strings or timestamps. */
export function canonical(value: unknown) {
  const serialize: (item: unknown) => string = item => {
    if (isList(item)) return `[${Array.from(item, serialize).join(',')}]`;
    if (isPlainRecord(item)) {
      const entries: [string, unknown][] = Object.entries(item);
      return `{${entries.sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0)
        .map(([key, entry]) => `${JSON.stringify(key)}:${serialize(entry)}`).join(',')}}`;
    }
    if (item === null || isString(item) || isBoolean(item) || (isNumber(item) && Number.isSafeInteger(item))) return JSON.stringify(item);
    throw new Error('Canonical values must be JSON records with safe integers');
  };
  return serialize(value);
}
export function validateBudgets(value: Budgets, effectiveActionDeadline?: number) {
  validate(value, { $ref: '#/$defs/budgets' });
  const answer = value.answer;
  if (effectiveActionDeadline !== undefined && (!Number.isSafeInteger(effectiveActionDeadline) || effectiveActionDeadline < 1 || answer.total > effectiveActionDeadline) || answer.claim + answer.reconciliation + answer.settlementReserve >= answer.total) throw new Error('Invalid answer budget allocation');
}
export function decodeModel(value: unknown) {
  validate(value);
  // SAFETY: The version-0 model schema checks the discriminant and every variant before cloning.
  const model = structuredClone(value) as Model;
  if (model.kind === 'budgets') validateBudgets(model.value);
  if (model.kind === 'call') {
    const { direction, lifecycle } = model.value;
    const timestamp = 'connectedAt' in lifecycle ? lifecycle.connectedAt
      : 'endedAt' in lifecycle ? lifecycle.endedAt : undefined;
    if (timestamp !== undefined) {
      if (!Number.isFinite(Date.parse(timestamp)) || new Date(timestamp).toISOString() !== timestamp) throw new Error('Invalid calendar timestamp');
    }
    if (direction === 'outgoing' && ['reporting', 'ringing', 'previewing'].includes(lifecycle.kind) || direction === 'incoming' && lifecycle.kind === 'dialing') throw new Error('Invalid call direction/lifecycle');
  }
  return model;
}
export function decodeJourney(value: unknown) {
  validate(value, { $ref: '#/$defs/journey' });
  // SAFETY: The version-0 journey definition checks the configuration and each step.
  const journey = structuredClone(value) as Journey;
  validateBudgets(journey.configuration.budgets);
  if (!journey.steps.some(step => step.kind === 'expect')) throw new Error('Journey has no assertions');
  return journey;
}
export function decodeTransitions(value: unknown) {
  validate(value, { $ref: '#/$defs/transitions' });
  // SAFETY: The transitions definition checks every rule before cloning.
  const transitions = structuredClone(value) as Transitions;
  if (new Set(transitions.rules.map(rule => rule.id)).size !== transitions.rules.length) throw new Error('Duplicate transition identity');
  return transitions;
}
