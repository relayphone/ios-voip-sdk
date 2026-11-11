import { type ConfigPlugin, createRunOncePlugin } from "expo/config-plugins";

import pkg from "../../package.json";
import type { CallPreviewActivitiesOption } from "./withCallPreviewActivities.ts";
import type { FocusFilterOption } from "./withFocusFilter.ts";
import { withVoIPConversationsIos } from "./withVoIPConversationsIos.ts";

import type { MediaAdapter } from "../../build/conversations/types";

/** iOS options for the config plugin exported by `@relayphone/ios-voip-sdk/plugin`. */
export type VoIPConversationsPluginProps = {
  /** WebRTC audio session integration, also used by LiveKit React Native. Defaults to webrtc. */
  mediaAdapter?: MediaAdapter;
  unhandledAction?: "fail" | "accept";
  /**
   * Presents calls in the iOS Simulator in Debug builds, with ios-voip-sdk's simulator runtime.
   * Release builds and devices are unaffected.
   * @default false
   * @platform ios
   */
  simulator?: boolean;
  /**
   * Posts a call notification, a communication notification from the caller, for each call that
   * Do Not Disturb or a Focus filtered on iOS, with ios-voip-sdk's `CallNotifier`. A Focus lets it
   * through for the people it allows, and it never rings. The plugin adds the Communication
   * Notifications capability. The app asks for the user's permission for notifications, and
   * expo-notifications must stay the notification center's delegate, which it is by default: the
   * module receives the responses to call notifications through it.
   * @default false
   * @platform ios
   */
  callNotifications?: boolean;
  /**
   * Shows each call preview as a Live Activity on the Lock Screen and in the Dynamic Island on
   * iOS, with ios-voip-sdk's `CallPreviewActivities`: a call that a Focus filtered, or that was
   * answered elsewhere, which the user can join. The app's servers start most call previews with
   * ActivityKit pushes; `useCallPreviewActivities()` gives them the tokens. The plugin sets
   * `NSSupportsLiveActivities` and generates the `CallPreviewWidget` widget extension, with
   * ios-voip-sdk's default views, and the Join intent that the app and the extension share.
   * Pass `{ widgetExtension: false }` to show call previews from your own widget extension.
   * Needs `ios.bundleIdentifier`, from which the extension's derives.
   * @default false
   * @platform ios
   */
  callPreviewActivities?: CallPreviewActivitiesOption;
  /**
   * Lets the app read its Focus filter state on iOS, with `useFocusFilterState()`: what the
   * app's Focus filter, a `CallFocusFilter` from ios-voip-sdk, last asked for, so that the app's
   * servers choose how each call appears. The app declares the filter in Swift, with its own
   * parameters: list its files in `sources` to compile them in the app, or declare it in an App
   * Intents extension of your own. The plugin adds `appGroup` to the app's App Groups.
   * @platform ios
   */
  focusFilter?: FocusFilterOption;
  /**
   * Custom message for microphone permission prompt. Set to false to skip.
   * @platform ios
   */
  microphonePermission?: string | false;
  /**
   * Custom message for camera permission prompt. Set to false to skip.
   * @platform ios
   */
  cameraPermission?: string | false;
  /**
   * Timeout in seconds for incoming calls before they are marked as unanswered. On iOS it also
   * bounds how long an outgoing call dials.
   * @default 45
   * @platform ios
   */
  incomingCallTimeout?: number;
  /**
   * Timeout in seconds for waiting for the call to connect after answering.
   * @default 30
   * @platform ios
   */
  fulfillAnswerCallTimeout?: number;
  /**
   * Whether the system's Recents list includes a call after it ends. Sets LiveCommunicationKit's
   * `ConversationManager.Configuration.includesConversationInRecents`.
   * @default true
   * @platform ios
   */
  includesCallsInRecents?: boolean;
  /**
   * Array of sound file paths (relative to project root) to include in the app.
   * These files will be copied into the iOS bundle.
   * .wav recommended
   * @platform ios
   */
  sounds?: string[];
  /**
   * The ringtone for incoming calls on iOS: the filename (with extension) of one of the provided
   * sounds, which the plugin bundles with the app, or 'default' for the system ringtone. Sets
   * LiveCommunicationKit's `ConversationManager.Configuration.ringtoneName`, the name of the
   * sound resource in the app bundle for the app's ringtone.
   * @default 'default'
   * @platform ios
   */
  defaultRingtoneIos?: string;
  /**
   * Path (relative to the project root) to a PNG of the app's icon for the system's call UI on
   * iOS. The plugin bundles it with the app, and the module passes its data to
   * LiveCommunicationKit's `ConversationManager.Configuration.iconTemplateImageData`, which
   * Apple documents only as the PNG data for the app's icon image. The property is named for a
   * template image, so provide a square PNG, about 40x40 points, whose alpha channel describes
   * the glyph. When omitted, the module passes no icon.
   * @platform ios
   */
  iconTemplateIos?: string;
};

const withVoIPConversations: ConfigPlugin<
  VoIPConversationsPluginProps | void
> = (config, props) => {
  const opts: VoIPConversationsPluginProps = props ?? {};
  config = withVoIPConversationsIos(config, opts);

  return config;
};

export default createRunOncePlugin(
  withVoIPConversations,
  pkg.name,
  pkg.version
);
