// Example-only build choice; the SDK uses the public plugin option.
module.exports = ({ config }) => {
  const mediaAdapter = process.env.SDK_EXAMPLE_MEDIA_ADAPTER ?? 'none';
  if (!['none', 'webrtc'].includes(mediaAdapter)) {
    throw new Error('SDK_EXAMPLE_MEDIA_ADAPTER must be none or webrtc.');
  }
  return {
    ...config,
    plugins: config.plugins.map((plugin) =>
      Array.isArray(plugin) && plugin[0] === 'ios-voip-sdk'
        ? [plugin[0], { ...plugin[1], mediaAdapter }]
        : plugin,
    ),
  };
};
