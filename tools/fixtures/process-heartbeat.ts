import { renameSync, writeFileSync } from 'node:fs';

const path = process.argv[2];
if (!path) throw new Error('Require heartbeat output path');
let counter = 0;
setInterval(() => {
  writeFileSync(`${path}.tmp`, String(++counter));
  renameSync(`${path}.tmp`, path);
}, 20);
