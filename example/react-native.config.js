// Keep the default native example independent of optional media frameworks.
const mediaAdapter = process.env.SDK_EXAMPLE_MEDIA_ADAPTER ?? 'none';
if (!['none', 'livekit'].includes(mediaAdapter)) {
  throw new Error('SDK_EXAMPLE_MEDIA_ADAPTER must be none or livekit.');
}
module.exports = {
  dependencies:
    mediaAdapter === 'livekit'
      ? {}
      : {
          '@livekit/react-native': { platforms: { ios: null } },
          '@livekit/react-native-webrtc': { platforms: { ios: null } },
        },
};
