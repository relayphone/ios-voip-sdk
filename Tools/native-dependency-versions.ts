import { appendFileSync, readFileSync } from 'node:fs';

interface Lockfile {
  packages: Record<string, { version?: string } | undefined>;
}

const lock = JSON.parse(readFileSync('package-lock.json', 'utf8')) as Lockfile;
const output = process.env.GITHUB_OUTPUT;
if (!output) throw new Error('GITHUB_OUTPUT is required');
for (const [name, path] of [['rn', 'node_modules/react-native'], ['hermes', 'node_modules/hermes-compiler']] as const) {
  const version = lock.packages[path]?.version;
  if (!version || !/^[0-9A-Za-z.+-]+$/.test(version)) throw new Error(`Missing or invalid ${name} version`);
  appendFileSync(output, `${name}=${version}\n`);
}
