// Example-only build variants; the SDK itself uses the public plugin option.
module.exports = ({ config }) => {
  const mediaAdapter = process.env.SDK_EXAMPLE_MEDIA_ADAPTER ?? 'none';
  if (!['none', 'livekit'].includes(mediaAdapter)) {
    throw new Error('SDK_EXAMPLE_MEDIA_ADAPTER must be none or livekit.');
  }
  return {
    ...config,
    plugins: config.plugins.map((plugin) => {
      if (!Array.isArray(plugin) || plugin[0] !== 'ios-voip-sdk') return plugin;
      return [
        plugin[0],
        {
          ...plugin[1],
          mediaAdapter,
          ...(mediaAdapter === 'livekit'
            ? {
                microphonePermission:
                  'Record a local audio track to verify calling audio.',
              }
            : {}),
        },
      ];
    }),
  };
};
