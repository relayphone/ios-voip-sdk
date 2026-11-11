// Installs the packed React Native package beside each supported Expo release and runs its config
// plugin, so an import that a newer Expo no longer exports fails here instead of in an app.
// Usage: node tools/expo-plugin-load.ts <package archive> [expo version ...]
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { isMain, main, run } from './command.ts';

/** The Expo releases the config plugin supports: the lowest major and the newest. */
export const supportedExpo = ['57', '58'] as const;

/** Loads `app.plugin.js` from the installed archive and applies it to a minimal app config. */
export const loadScript = [
  "const entry = require('@relayphone/ios-voip-sdk/app.plugin');",
  "const plugin = typeof entry === 'function' ? entry : entry.default;",
  "if (typeof plugin !== 'function') throw new Error('app.plugin.js exports no config plugin');",
  "const config = plugin({ name: 'PluginLoad', slug: 'plugin-load' }, {});",
  "if (!config || config.name !== 'PluginLoad') throw new Error('The config plugin returned an invalid app config');",
  "console.log(`expo ${require('expo/package.json').version}: config plugin loaded`);",
].join('\n');

export function loadPlugin(archive: string, expo: string): string {
  const project = mkdtempSync(join(tmpdir(), `voip-plugin-expo-${expo}-`));
  try {
    writeFileSync(join(project, 'package.json'), `${JSON.stringify({ name: 'plugin-load', private: true })}\n`);
    run('npm', ['install', '--ignore-scripts', '--no-audit', '--no-fund', '--legacy-peer-deps', `expo@${expo}`, resolve(archive)], {
      directory: project,
      timeout: 900,
    });
    return run('node', ['-e', loadScript], { directory: project });
  } finally {
    rmSync(project, { recursive: true, force: true });
  }
}

if (isMain(import.meta.url)) {
  await main(() => {
    const [archive, ...versions] = process.argv.slice(2);
    if (!archive) throw new Error('Usage: node tools/expo-plugin-load.ts <package archive> [expo version ...]');
    for (const expo of versions.length > 0 ? versions : supportedExpo) console.log(loadPlugin(archive, expo));
  });
}
