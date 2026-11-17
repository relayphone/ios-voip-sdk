import { readFileSync } from 'node:fs';
import type { Budgets, Journey, Model, Transitions } from './model.ts';

type Schema = Readonly<{ $schema?: string; $id?: string; $defs?: Readonly<Record<string, Schema>>;
  $ref?: string; type?: 'object' | 'array' | 'string' | 'integer' | 'boolean'; const?: unknown;
  enum?: readonly unknown[]; oneOf?: readonly Schema[]; properties?: Readonly<Record<string, Schema>>;
  required?: readonly string[]; additionalProperties?: false; items?: Schema; minItems?: number;
  minLength?: number; maxLength?: number; pattern?: string; minimum?: number; maximum?: number }>;
const schema = JSON.parse(readFileSync(new URL('../../spec/model.schema.json', import.meta.url), 'utf8')) as Schema;
const keywords = new Set(['$schema', '$id', '$defs', '$ref', 'type', 'const', 'enum', 'oneOf', 'properties',
  'required', 'additionalProperties', 'items', 'minItems', 'minLength', 'maxLength', 'pattern', 'minimum', 'maximum']);

function audit(rule: Schema): void {
  for (const key of Object.keys(rule)) if (!keywords.has(key)) throw new Error(`Unsupported schema keyword: ${key}`);
  if (rule.type && !['object', 'array', 'string', 'integer', 'boolean'].includes(rule.type)) throw new Error('Unsupported schema type');
  if ('additionalProperties' in rule && rule.additionalProperties !== false) throw new Error('Unsupported additionalProperties policy');
  if (rule.$ref) referenced(rule.$ref);
  for (const child of [...Object.values(rule.$defs ?? {}), ...Object.values(rule.properties ?? {}), ...(rule.oneOf ?? []), ...(rule.items ? [rule.items] : [])]) audit(child);
}
function referenced(reference: string): Schema {
  const name = reference.replace(/^#\/\$defs\//, '');
  if (reference !== `#/$defs/${name}` || !schema.$defs || !Object.hasOwn(schema.$defs, name)) throw new Error(`Unknown schema reference: ${reference}`);
  return schema.$defs[name]!;
}
/** Checks the declared JSON Schema subset without accepting unknown keywords in unused branches. */
export function validate(value: unknown, rule: Schema = schema, path = '$'): void {
  audit(rule);
  visit(value, rule, path);
}
/** The schema intentionally uses this small, fail-closed JSON Schema subset; no external validator. */
function visit(value: unknown, rule: Schema, path: string): void {
  const fail = (): never => { throw new Error(`Invalid conformance value at ${path}`); };
  if (rule.$ref) visit(value, referenced(rule.$ref), path);
  if ('const' in rule && value !== rule.const) fail();
  if (rule.enum && !rule.enum.includes(value)) fail();
  if (rule.oneOf) {
    const matches = rule.oneOf.filter(option => { try { visit(value, option, path); return true; } catch { return false; } });
    if (matches.length !== 1) fail();
  }
  switch (rule.type) {
    case 'object': {
      if (!value || typeof value !== 'object' || Array.isArray(value) || ![null, Object.prototype].includes(Object.getPrototypeOf(value))) fail();
      const record = value as Record<string, unknown>;
      for (const key of rule.required ?? []) if (!Object.hasOwn(record, key)) fail();
      for (const [key, entry] of Object.entries(record)) {
        const child = rule.properties && Object.hasOwn(rule.properties, key) ? rule.properties[key] : undefined;
        if (child) visit(entry, child, `${path}.${key}`);
        else if (rule.additionalProperties === false) fail();
      }
      break;
    }
    case 'array':
      if (!Array.isArray(value) || value.length < (rule.minItems ?? 0)) fail();
      if (rule.items) (value as unknown[]).forEach((item, i) => visit(item, rule.items!, `${path}[${i}]`));
      break;
    case 'string':
      if (typeof value !== 'string') fail();
      if ([...(value as string)].length < (rule.minLength ?? 0) || [...(value as string)].length > (rule.maxLength ?? Infinity)) fail();
      if (rule.pattern && !new RegExp(rule.pattern, 'u').test(value as string)) fail();
      break;
    case 'integer':
      if (!Number.isSafeInteger(value) || (value as number) < (rule.minimum ?? -Infinity) || (value as number) > (rule.maximum ?? Infinity)) fail();
      break;
    case 'boolean': if (typeof value !== 'boolean') fail(); break;
  }
}

/** Returns deterministic JSON without normalizing identifier strings or timestamps. */
export function canonical(value: unknown): string {
  const serialize = (item: unknown): string => {
    if (Array.isArray(item)) return `[${Array.from(item, serialize).join(',')}]`;
    if (item !== null && typeof item === 'object' && [null, Object.prototype].includes(Object.getPrototypeOf(item))) {
      return `{${Object.entries(item).sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0)
        .map(([key, entry]) => `${JSON.stringify(key)}:${serialize(entry)}`).join(',')}}`;
    }
    if (item === null || typeof item === 'string' || typeof item === 'boolean' || typeof item === 'number' && Number.isSafeInteger(item)) return JSON.stringify(item);
    throw new Error('Canonical values must be JSON records with safe integers');
  };
  return serialize(value);
}
export function validateBudgets(value: Budgets, effectiveActionDeadline?: number): void {
  validate(value, { $ref: '#/$defs/budgets' });
  const answer = value.answer;
  if (effectiveActionDeadline !== undefined && (!Number.isSafeInteger(effectiveActionDeadline) || effectiveActionDeadline < 1 || answer.total > effectiveActionDeadline) || answer.claim + answer.reconciliation + answer.settlementReserve >= answer.total) throw new Error('Invalid answer budget allocation');
}
export function decodeModel(value: unknown): Model {
  validate(value);
  const model = structuredClone(value) as Model;
  if (model.kind === 'budgets') validateBudgets(model.value);
  if (model.kind === 'call') {
    const { direction, lifecycle } = model.value;
    for (const key of ['connectedAt', 'endedAt'] as const) if (key in lifecycle) {
      const timestamp = (lifecycle as unknown as Record<string, string>)[key]!;
      if (!Number.isFinite(Date.parse(timestamp)) || new Date(timestamp).toISOString() !== timestamp) throw new Error('Invalid calendar timestamp');
    }
    if (direction === 'outgoing' && ['reporting', 'ringing', 'previewing'].includes(lifecycle.kind) || direction === 'incoming' && lifecycle.kind === 'dialing') throw new Error('Invalid call direction/lifecycle');
  }
  return model;
}
export function decodeJourney(value: unknown): Journey {
  validate(value, { $ref: '#/$defs/journey' });
  const journey = structuredClone(value) as Journey;
  validateBudgets(journey.configuration.budgets);
  if (!journey.steps.some(step => step.kind === 'expect')) throw new Error('Journey has no assertions');
  return journey;
}
export function decodeTransitions(value: unknown): Transitions {
  validate(value, { $ref: '#/$defs/transitions' });
  const transitions = structuredClone(value) as Transitions;
  if (new Set(transitions.rules.map(rule => rule.id)).size !== transitions.rules.length) throw new Error('Duplicate transition identity');
  return transitions;
}
