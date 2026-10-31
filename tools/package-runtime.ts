// Archives a complete runtime package for release, with a SHA256SUMS file.
//
// Usage: node tools/package-runtime.ts <runtime package> <new output directory>
import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { isMain, main } from './command.ts';
import { archive, sha256, validate } from './runtime-package.ts';

/** Writes the archive and its checksum, and returns the archive's name. */
export function packageRuntime(distribution: string, output: string): string {
  const info = validate(distribution);
  if (!Number.isSafeInteger(info.sourceDateEpoch) || info.sourceDateEpoch < 0) {
    throw new Error('Invalid source date epoch');
  }
  if (existsSync(output)) throw new Error(`Output already exists: ${output}`);
  mkdirSync(output, { recursive: true });
  const name = `callkit-simulator-v${info.version}-macos.tar.gz`;
  // Normalizing the archive's metadata makes packaging the same files reproducible; rebuilding the
  // Mach-O files is a separate question.
  const data = archive(distribution, info.sourceDateEpoch);
  writeFileSync(join(output, name), data);
  writeFileSync(join(output, 'SHA256SUMS'), `${sha256(data)}  ${name}\n`);
  return name;
}

if (isMain(import.meta.url)) {
  await main(() => {
    const [distribution, output] = process.argv.slice(2);
    if (!distribution || !output) {
      throw new Error('Usage: node tools/package-runtime.ts <runtime package> <new output directory>');
    }
    console.log(packageRuntime(resolve(distribution), resolve(output)));
  });
}
