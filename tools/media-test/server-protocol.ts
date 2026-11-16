/** Private IPC between the fixture and its server supervisor. */
export type ServerEvent =
  | { type: 'started'; pid: number }
  | { type: 'failed'; code: number | null; signal: NodeJS.Signals | null; diagnostic: string };
