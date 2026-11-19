export type ID<Kind extends string> = string & { readonly __kind: Kind };
export type Milliseconds = number & { readonly __kind: 'milliseconds' };
export type Decoder<Value> = (input: unknown, path?: string) => Value;
export type Decoded<Rule extends Decoder<unknown>> = ReturnType<Rule>;

type Fields = Readonly<Record<string, Decoder<unknown>>>;
type OptionalKey<Rules extends Fields> = {
  [Key in keyof Rules]: undefined extends Decoded<Rules[Key]> ? Key : never;
}[keyof Rules];
type ObjectValue<Rules extends Fields> = Readonly<
  { [Key in Exclude<keyof Rules, OptionalKey<Rules>>]: Decoded<Rules[Key]> }
  & { [Key in OptionalKey<Rules>]?: Exclude<Decoded<Rules[Key]>, undefined> }
>;

function invalid(path: string, expected: string): never {
  throw new TypeError(`Invalid call transport at ${path}: expected ${expected}`);
}

export function literal<const Values extends readonly (string | number | boolean)[]>(
  ...values: Values
): Decoder<Values[number]> {
  const matches = (input: unknown): input is Values[number] => values.some(value => value === input);
  return (input, path = '$') => {
    if (!matches(input)) return invalid(path, values.join(' or '));
    return input;
  };
}

function isPlainRecord(input: unknown): input is Record<string, unknown> {
  return input !== null && typeof input === 'object' &&
    [Object.prototype, null].includes(Object.getPrototypeOf(input));
}

export function object<const Rules extends Fields>(rules: Rules): Decoder<ObjectValue<Rules>> {
  return (input, path = '$') => {
    if (!isPlainRecord(input)) return invalid(path, 'a plain record');
    for (const key of Object.keys(input)) {
      if (!Object.hasOwn(rules, key) || input[key] === undefined) invalid(path, 'only declared JSON fields');
    }
    const entries: [string, unknown][] = [];
    for (const [key, decode] of Object.entries(rules)) {
      const value = decode(Object.hasOwn(input, key) ? input[key] : undefined, `${path}.${key}`);
      if (value !== undefined) entries.push([key, value]);
    }
    // SAFETY: Each declared key was decoded by its own rule, and only optional decoders can omit values.
    return Object.freeze(Object.fromEntries(entries)) as ObjectValue<Rules>;
  };
}

export const optional = <Value>(decode: Decoder<Value>): Decoder<Value | undefined> =>
  (input, path) => input === undefined ? undefined : decode(input, path);

export function array<Value>(decode: Decoder<Value>): Decoder<readonly Value[]> {
  return (input, path = '$') => {
    if (!Array.isArray(input)) invalid(path, 'an array');
    return Object.freeze(Array.from(input, (item, index) => decode(item, `${path}[${index}]`)));
  };
}

export function nonempty<Value>(decode: Decoder<Value>): Decoder<readonly [Value, ...Value[]]> {
  const values = array(decode);
  return (input, path = '$') => {
    const decoded = values(input, path);
    if (decoded.length === 0) invalid(path, 'at least one item');
    // SAFETY: The frozen decoded array has at least one item.
    return decoded as readonly [Value, ...Value[]];
  };
}

export function union<const Rules extends readonly Decoder<unknown>[]>(...rules: Rules): Decoder<Decoded<Rules[number]>> {
  return (input, path = '$') => {
    for (const rule of rules) {
      try {
        // SAFETY: A successful rule belongs to Rules, so its result is a member of the decoded union.
        return rule(input, path) as Decoded<Rules[number]>;
      } catch (error) { if (!(error instanceof TypeError)) throw error; }
    }
    return invalid(path, 'a supported variant');
  };
}

export function refine<Value>(decode: Decoder<Value>, valid: (value: Value) => boolean, expected: string): Decoder<Value> {
  return (input, path = '$') => {
    const value = decode(input, path);
    if (!valid(value)) invalid(path, expected);
    return value;
  };
}

function isString(input: unknown): input is string {
  return typeof input === 'string';
}

function isNumber(input: unknown): input is number {
  return typeof input === 'number';
}

export function text(min = 1, max = 256, pattern?: RegExp): Decoder<string> {
  return (input, path = '$') => {
    if (!isString(input)) invalid(path, 'a string');
    const length = [...input].length;
    if (length < min || length > max || (pattern && !pattern.test(input))) invalid(path, 'a valid string');
    return input;
  };
}

export function integer(min = 0, max = Number.MAX_SAFE_INTEGER): Decoder<number> {
  return (input, path = '$') => {
    if (!isNumber(input) || !Number.isSafeInteger(input) || input < min || input > max) {
      invalid(path, 'an integer in range');
    }
    return input;
  };
}

export function hasControlCharacters(value: string): boolean {
  for (let index = 0; index < value.length; index++) {
    const code = value.charCodeAt(index);
    if (code < 0x20 || (code >= 0x7f && code <= 0x9f)) return true;
  }
  return false;
}

const opaqueID = refine(text(), value => value.trim() === value && !hasControlCharacters(value),
  'an unpadded opaque identifier without control characters');
export const id = <Kind extends string>(): Decoder<ID<Kind>> =>
  (input, path) => {
    // SAFETY: The identifier decoder validated the original string before adding its domain brand.
    return opaqueID(input, path) as ID<Kind>;
  };
export const timestamp = refine(text(24, 24), value => Number.isFinite(Date.parse(value)) &&
  new Date(value).toISOString() === value, 'a UTC millisecond timestamp');
const positive = integer(1);
export const milliseconds: Decoder<Milliseconds> = (input, path) => {
  // SAFETY: The integer decoder checked that the duration is positive and within the safe integer range.
  return positive(input, path) as Milliseconds;
};
export const phone = text(3, 16, /^\+[1-9][0-9]{1,14}(?![\s\S])/u);
export const digit = literal('0', '1', '2', '3', '4', '5', '6', '7', '8', '9', '*', '#');
