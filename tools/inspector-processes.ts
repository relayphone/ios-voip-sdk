import { basename, join } from 'node:path';
import { closeSync, openSync, readSync, readdirSync } from 'node:fs';

interface ProcessRow { pid: number; parent: number; cpu: number; command: string; row: string }
function processes(output: string): ProcessRow[] {
  return output.split('\n').flatMap(row => {
    const m = /^\s*(\d+)\s+(\d+)\s+\S+\s+([\d.]+)\s+\S+\s+(.+)$/.exec(row);
    return m ? [{ pid: Number(m[1]), parent: Number(m[2]), cpu: Number(m[3]), command: m[4]!, row }] : [];
  });
}

/** CPU leaders with parent chains, command multiplicity and live crash reporter count. */
export function processSummary(output: string): string {
  const rows = processes(output);
  const byPID = new Map(rows.map(row => [row.pid, row]));
  const counts = new Map<string, number>();
  for (const row of rows) counts.set(row.command, (counts.get(row.command) ?? 0) + 1);
  const ancestry = (row: ProcessRow): string => {
    const visited = new Set<number>();
    const chain: string[] = [];
    let current: ProcessRow | undefined = row;
    while (current && !visited.has(current.pid)) {
      visited.add(current.pid);
      chain.push(`${current.pid}:${basename(current.command)}`);
      if (basename(current.command) === 'launchd_sim') return `simulator ${chain.join(' <- ')}`;
      if (current.parent <= 1) return `host ${chain.join(' <- ')}`;
      current = byPID.get(current.parent);
    }
    return `unresolved ${chain.join(' <- ')}`;
  };
  const leaders = rows.toSorted((a, b) => b.cpu - a.cpu).slice(0, 25);
  return ['ps CPU leaders (PID PPID STAT %CPU ELAPSED COMM)',
    ...leaders.map(row => `${row.row}\n  ancestry: ${ancestry(row)}`),
    'Process counts by command (top 15)',
    ...[...counts].toSorted((a, b) => b[1] - a[1]).slice(0, 15).map(([name, count]) => `${count} ${name}`),
    `ReportCrash processes: ${rows.filter(r => basename(r.command) === 'ReportCrash').length}`,
  ].join('\n');
}

function ipsFiles(root: string): string[] {
  let entries;
  try { entries = readdirSync(root, { withFileTypes: true }); }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return [];
    throw error;
  }
  return entries.flatMap(entry => {
    const path = join(root, entry.name);
    return entry.isDirectory() ? ipsFiles(path) : entry.isFile() && entry.name.endsWith('.ips') ? [path] : [];
  });
}

/** Tracks new reports separately for the host and simulator directories from sampler startup. */
export class CrashTracker {
  private readonly seen = new Set<string>();
  private readonly roots: readonly string[];
  constructor(roots: readonly string[]) {
    this.roots = roots;
    for (const root of roots) for (const path of ipsFiles(root)) this.seen.add(path);
  }
  sample(): string {
    return this.roots.map(root => {
      const added = ipsFiles(root).filter(path => !this.seen.has(path));
      const headers = added.map(path => {
        // Read only a bounded header, never a whole crash report.
        const fd = openSync(path, 'r');
        const buffer = Buffer.alloc(4096);
        let length: number;
        try { length = readSync(fd, buffer, 0, buffer.length, 0); } finally { closeSync(fd); }
        const header = buffer.subarray(0, length).toString().split('\n')[0] ?? '';
        this.seen.add(path);
        return `${path}\n.ips header: ${header}`;
      });
      return `New .ips reports since previous sample [${root}]: ${added.length}\n${headers.join('\n')}`;
    }).join('\n');
  }
}
