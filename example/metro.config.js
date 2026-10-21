const { getDefaultConfig } = require('expo/metro-config');
const path = require('node:path');

const config = getDefaultConfig(__dirname);
const repositoryRoot = path.resolve(__dirname, '..');

config.watchFolders = [...new Set([...config.watchFolders, repositoryRoot])];
config.resolver.extraNodeModules = {
  ...config.resolver.extraNodeModules,
  'ios-voip-sdk': repositoryRoot,
};
config.resolver.nodeModulesPaths = [
  path.join(__dirname, 'node_modules'),
  path.join(repositoryRoot, 'node_modules'),
];

// npm workspaces hoists the pinned React and React Native versions to the root.
// Keep that shared installation visible rather than blocking the parent modules.
module.exports = config;
