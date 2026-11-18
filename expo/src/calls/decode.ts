export type ID<Kind extends string> = string & { readonly __kind: Kind };
export type Milliseconds = number & { readonly __kind: 'milliseconds' };
export type Decoder<Value> = (input: unknown, path?: string) => Value;
export type Decoded<Rule extends Decoder<unknown>> = ReturnType<Rule>;

type Fields = Readonly<Record<string, Decoder<unknown>>>;
type OptionalKey<Shape extends Fields> = {
  [Key in keyof Shape]: undefined extends Decoded<Shape[Key]> ? Key : never;
}[keyof Shape];
type ObjectValue<Shape extends Fields> = Readonly<
  { [Key in Exclude<keyof Shape, OptionalKey<Shape>>]: Decoded<Shape[Key]> }
  & { [Key in OptionalKey<Shape>]?: Exclude<Decoded<Shape[Key]>, undefined> }
>;

function invalid(path: string, expected: string): never {
  throw new TypeError(`Invalid call transport at ${path}: expected ${expected}`);
}

export function literal<const Values extends readonly (string | number | boolean)[]>(
  ...values: Values
): Decoder<Values[number]> {
  return (input, path = '$') => {
    if (!values.some(value => value === input)) invalid(path, values.join(' or '));
    return input as Values[number];
  };
}

export function object<const Shape extends Fields>(shape: Shape): Decoder<ObjectValue<Shape>> {
  return (input, path = '$') => {
    if (input === null || typeof input !== 'object' ||
        ![Object.prototype, null].includes(Object.getPrototypeOf(input))) {
      invalid(path, 'a plain record');
    }
    const record = input as Record<string, unknown>;
    for (const key of Object.keys(record)) {
      if (!Object.hasOwn(shape, key) || record[key] === undefined) invalid(path, 'only declared JSON fields');
    }
    const entries = Object.entries(shape).flatMap(([key, decode]) => {
      const value = decode(Object.hasOwn(record, key) ? record[key] : undefined, `${path}.${key}`);
      return value === undefined ? [] : [[key, value]];
    });
    return Object.freeze(Object.fromEntries(entries)) as ObjectValue<Shape>;
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
    return decoded as readonly [Value, ...Value[]];
  };
}

export function union<const Rules extends readonly Decoder<unknown>[]>(...rules: Rules): Decoder<Decoded<Rules[number]>> {
  return (input, path = '$') => {
    for (const rule of rules) {
      try { return rule(input, path) as Decoded<Rules[number]>; }
      catch (error) { if (!(error instanceof TypeError)) throw error; }
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

export function text(min = 1, max = 256, pattern?: RegExp): Decoder<string> {
  return (input, path = '$') => {
    if (typeof input !== 'string') invalid(path, 'a string');
    const length = [...input].length;
    if (length < min || length > max || (pattern && !pattern.test(input))) invalid(path, 'a valid string');
    return input;
  };
}

export function integer(min = 0, max = Number.MAX_SAFE_INTEGER): Decoder<number> {
  return (input, path = '$') => {
    if (typeof input !== 'number' || !Number.isSafeInteger(input) || input < min || input > max) {
      invalid(path, 'an integer in range');
    }
    return input;
  };
}

const opaqueID = refine(text(), value => value.trim() === value && !/[\u0000-\u001f\u007f-\u009f]/u.test(value),
  'an unpadded opaque identifier without control characters');
export const id = <Kind extends string>(): Decoder<ID<Kind>> =>
  (input, path) => opaqueID(input, path) as ID<Kind>;
export const timestamp = refine(text(24, 24), value => Number.isFinite(Date.parse(value)) &&
  new Date(value).toISOString() === value, 'a UTC millisecond timestamp');
const positive = integer(1);
export const milliseconds: Decoder<Milliseconds> = (input, path) => positive(input, path) as Milliseconds;
export const phone = text(3, 16, /^\+[1-9][0-9]{1,14}(?![\s\S])/u);
export const digit = literal('0', '1', '2', '3', '4', '5', '6', '7', '8', '9', '*', '#');
