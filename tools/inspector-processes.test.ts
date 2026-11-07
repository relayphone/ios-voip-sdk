import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { CrashTracker, processSummary } from './inspector-processes.ts';

test('attributes CPU to simulator ancestors, counts command copies and handles missing parents', () => {
  const result = processSummary(`PID PPID STAT %CPU ELAPSED COMM
  1 0 Ss 0.0 1:00 /sbin/launchd
  10 1 S 1.0 1:00 /sim/launchd_sim
  11 10 R 90.0 0:10 /sim/ReportCrash
  12 10 R 80.0 0:10 /sim/ReportCrash
  20 1 R 60.0 1:00 /host/daemon
  30 99 R 50.0 1:00 /host/missing`);
  assert.match(result, /simulator 11:ReportCrash <- 10:launchd_sim/);
  assert.match(result, /host 20:daemon/);
  assert.match(result, /unresolved 30:missing/);
  assert.match(result, /2 \/sim\/ReportCrash/);
  assert.match(result, /ReportCrash processes: 2/);
  assert.ok(result.indexOf('11 10') < result.indexOf('20 1'));
});

test('counts only new host and simulator reports and retains their process header', () => {
  const root = mkdtempSync(join(tmpdir(), 'inspector-crashes-'));
  try {
    const host = join(root, 'host');
    const sim = join(root, 'sim');
    mkdirSync(host);
    writeFileSync(join(host, 'old.ips'), '{"app_name":"Old"}\n');
    const tracker = new CrashTracker([host, sim]);
    mkdirSync(join(sim, 'UUID'), { recursive: true });
    writeFileSync(join(sim, 'UUID', 'new.ips'), '{"app_name":"Daemon"}\nignored details');
    const result = tracker.sample();
    assert.match(result, /new.ips/);
    assert.match(result, /"app_name":"Daemon"/);
    assert.doesNotMatch(result, /Old|ignored details/);
    assert.doesNotMatch(tracker.sample(), /new.ips/);
  } finally { rmSync(root, { recursive: true, force: true }); }
});
