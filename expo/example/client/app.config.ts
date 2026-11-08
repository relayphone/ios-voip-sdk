import type { ExpoConfig } from "expo/config";

const BUNDLE_ID = "com.example.voipconversations";

const config: ExpoConfig = {
  name: "VoIP Example",
  slug: "voip-conversations-example",
  scheme: "conversations-example",
  version: "1.0.0",
  orientation: "portrait",
  icon: "./assets/icon.png",
  ios: {
    supportsTablet: true,
    bundleIdentifier: BUNDLE_ID,
  },
  plugins: [
    [
      "expo-splash-screen",
      {
        image: "./assets/splash-icon.png",
        resizeMode: "contain",
        backgroundColor: "#ffffff",
      },
    ],
    [
      "expo-build-properties",
      {
        ios: { deploymentTarget: "26.0", enableSceneSupport: true },
      },
    ],
    [
      "@relayphone/ios-voip-sdk",
      {
        sounds: ["./assets/sounds/ringtone.wav"],
        defaultRingtoneIos: "ringtone.wav",
        iconTemplateIos: "./assets/call-icon.png",
        // Debug builds present calls in the iOS Simulator.
        simulator: true,
        // A call that a Focus filters becomes a call preview with a call notification, shown as a
        // Live Activity from the generated widget extension.
        callNotifications: true,
        callPreviewActivities: true,
        // The app's Focus filter, whose state the app shows.
        focusFilter: {
          appGroup: "group.com.example.voipconversations",
          sources: ["./focus/CallsFocusFilter.swift"],
        },
      },
    ],
  ],
};

export default config;
