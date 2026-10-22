/** Copy bridge JSON so application mutation cannot corrupt the native snapshot. */
export function immutableCopy<Value>(value: Value): Value {
  if (Array.isArray(value)) {
    return Object.freeze(value.map(immutableCopy)) as Value;
  }
  if (value !== null && typeof value === 'object') {
    const copy = Object.fromEntries(
      Object.entries(value).map(([key, entry]) => [key, immutableCopy(entry)]),
    );
    return Object.freeze(copy) as Value;
  }
  return value;
}

/** Native revisions order events and asynchronous reads on the same timeline. */
export class RevisionStore<Value> {
  private revision = -1;
  private value: Value;
  private failure: unknown;
  private failed = false;
  private started = false;
  private readonly listeners = new Set<() => void>();

  constructor(initial: Value) {
    this.value = initial;
  }

  readonly getSnapshot = (): Value => {
    if (this.revision < 0 && this.failed) throw this.failure;
    return this.value;
  };

  readonly subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  accept(revision: number, value: Value): boolean {
    if (!Number.isSafeInteger(revision) || revision < 0) {
      throw new Error('ios-voip-sdk: invalid native snapshot revision.');
    }
    if (revision <= this.revision) return false;
    this.revision = revision;
    this.value = immutableCopy(value);
    this.failure = undefined;
    this.failed = false;
    this.publish();
    return true;
  }

  start(read: () => Promise<void>): void {
    if (this.started) return;
    this.started = true;
    void read().catch((error: unknown) => {
      this.failure = error;
      this.failed = true;
      this.publish();
    });
  }

  private publish(): void {
    for (const listener of [...this.listeners]) listener();
  }
}
