// Checked against the installed tarball by the packed example's typecheck.
import type plugin from "@relayphone/ios-voip-sdk/plugin";
import type { VoIPConversationsPluginProps } from "@relayphone/ios-voip-sdk/plugin";
import type { ConfigPlugin } from "expo/config-plugins";

const props: VoIPConversationsPluginProps = {
  mediaAdapter: "webrtc",
  simulator: true,
  callPreviewActivities: { widgetExtension: false },
  focusFilter: { appGroup: "group.example.calls", sources: ["./Filter.swift"] },
};

// A wrapper can add platform options while preserving the iOS plugin signature.
type CrossPlatformProps = VoIPConversationsPluginProps & { androidEnabled?: boolean };
declare const iosPlugin: typeof plugin;
const wrapper: ConfigPlugin<CrossPlatformProps | void> = (config, options) =>
  iosPlugin(config, options);
void wrapper;
void props;

// @ts-expect-error Only supported media adapters are accepted.
const invalidMedia: VoIPConversationsPluginProps = { mediaAdapter: "unknown" };
// @ts-expect-error Android options belong to the wrapper.
const android: VoIPConversationsPluginProps = { androidEnabled: true };
void invalidMedia;
void android;
