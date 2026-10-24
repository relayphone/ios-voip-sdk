const mediaAdapter = process.env.SDK_EXAMPLE_MEDIA_ADAPTER ?? 'none';
if (!['none', 'webrtc'].includes(mediaAdapter)) {
  throw new Error('SDK_EXAMPLE_MEDIA_ADAPTER must be none or webrtc.');
}
module.exports = {
  dependencies:
    mediaAdapter === 'webrtc'
      ? {}
      : { 'react-native-webrtc': { platforms: { ios: null } } },
};
