import {
  type ConfigPlugin,
  IOSConfig,
  withEntitlementsPlist,
  withInfoPlist,
  withPodfileProperties,
  withXcodeProject,
} from "expo/config-plugins";
import { copyFileSync, existsSync } from "fs";
import { basename, resolve } from "path";

import {
  DEFAULT_FULFILL_ANSWER_CALL_TIMEOUT,
  DEFAULT_INCLUDES_CALLS_IN_RECENTS,
  DEFAULT_INCOMING_CALL_TIMEOUT,
} from "./constants.ts";
import { withCallPreviewActivities } from "./withCallPreviewActivities.ts";
import type { VoIPConversationsPluginProps } from "./withVoIPConversations.ts";
import { withFocusFilter } from "./withFocusFilter.ts";

const ERROR_MSG_PREFIX = "An error occurred while configuring iOS calls. ";

// Default permission messages
const CAMERA_USAGE = "Allow $(PRODUCT_NAME) to access your camera";
const MICROPHONE_USAGE = "Allow $(PRODUCT_NAME) to access your microphone";

// Background modes for calls:
// - voip: receive PushKit VoIP pushes, which launch or wake the app for incoming calls
// - audio: keep call audio playing and recording while the app is in the background
const BACKGROUND_MODES = ["voip", "audio"];

// iOS 26+ sends the unified intent for audio and video calls, including redial from Recents.
// CallService.continueCall handles this intent.
const SIRI_INTENTS = ["INStartCallIntent"];

/**
 * Configures camera and microphone permissions for VoIP and video calls.
 */
const withPermissions: ConfigPlugin<{
  cameraPermission?: string | false;
  microphonePermission?: string | false;
}> = (config, { cameraPermission, microphonePermission }) => {
  return IOSConfig.Permissions.createPermissionsPlugin({
    NSCameraUsageDescription: CAMERA_USAGE,
    NSMicrophoneUsageDescription: MICROPHONE_USAGE,
  })(config, {
    NSCameraUsageDescription: cameraPermission,
    NSMicrophoneUsageDescription: microphonePermission,
  });
};

/**
 * Configures the push notification entitlement for PushKit VoIP pushes.
 */
const withPushNotificationEntitlement: ConfigPlugin = (config) => {
  return withEntitlementsPlist(config, (config) => {
    const key = "aps-environment";
    // Only set if not already configured; production builds use provisioning profile value
    if (!config.modResults[key]) {
      config.modResults[key] = "development";
    }
    return config;
  });
};

/**
 * Configures UIBackgroundModes for VoIP call handling.
 */
const withBackgroundModes: ConfigPlugin = (config) => {
  return withInfoPlist(config, (config) => {
    const existingModes = config.modResults.UIBackgroundModes;
    const modes = Array.isArray(existingModes)
      ? (existingModes as string[])
      : [];

    const newModes = new Set([...modes, ...BACKGROUND_MODES]);
    config.modResults.UIBackgroundModes = [...newModes];

    return config;
  });
};

/**
 * Configures SiriKit intents for voice-activated audio/video calls.
 */
const withSiriIntents: ConfigPlugin = (config) => {
  return withInfoPlist(config, (config) => {
    const existingIntents = config.modResults.NSUserActivityTypes;
    const intents = Array.isArray(existingIntents)
      ? (existingIntents as string[]).filter((intent) =>
          intent !== "INStartAudioCallIntent" && intent !== "INStartVideoCallIntent")
      : [];

    const newIntents = new Set([...intents, ...SIRI_INTENTS]);
    config.modResults.NSUserActivityTypes = [...newIntents];

    return config;
  });
};

/**
 * Configures call timeout values in Info.plist. The SDK's ring deadline covers both incoming
 * rings and outgoing dialing, so iOS has no separate outgoing timeout.
 */
const withTimeouts: ConfigPlugin<{
  incomingCallTimeout?: number;
  fulfillAnswerCallTimeout?: number;
}> = (config, { incomingCallTimeout, fulfillAnswerCallTimeout }) => {
  return withInfoPlist(config, (config) => {
    config.modResults.VoIPConversationsIncomingCallTimeout =
      incomingCallTimeout ?? DEFAULT_INCOMING_CALL_TIMEOUT;
    config.modResults.VoIPConversationsFulfillAnswerCallTimeout =
      fulfillAnswerCallTimeout ?? DEFAULT_FULFILL_ANSWER_CALL_TIMEOUT;
    return config;
  });
};

const MEDIA_ADAPTERS: readonly string[] = ["webrtc", "none"];

/** Selects optional sources and compile conditions in the package's podspec. */
const withCallCore: ConfigPlugin<{
  mediaAdapter?: string;
  simulator?: boolean;
  unhandledAction?: string;
  callNotifications?: boolean;
  callPreviewActivities?: boolean;
  focusFilter?: boolean;
}> = (
  config,
  {
    mediaAdapter,
    simulator,
    unhandledAction,
    callNotifications,
    callPreviewActivities,
    focusFilter,
  },
) => {
  const media = mediaAdapter ?? "webrtc";
  if (!MEDIA_ADAPTERS.includes(media)) {
    throw new Error(
      `${ERROR_MSG_PREFIX}"mediaAdapter" must be one of ${MEDIA_ADAPTERS.join(", ")}.`,
    );
  }
  config = withPodfileProperties(config, (config) => {
    // Earlier versions chose the calling framework here; the podspec no longer reads it.
    delete config.modResults["@relayphone/ios-voip-sdk.callingFramework"];
    config.modResults["@relayphone/ios-voip-sdk.mediaAdapter"] = media;
    config.modResults["@relayphone/ios-voip-sdk.simulator"] = String(
      simulator ?? false,
    );
    config.modResults["@relayphone/ios-voip-sdk.callNotifications"] = String(
      callNotifications ?? false,
    );
    config.modResults["@relayphone/ios-voip-sdk.callPreviewActivities"] = String(
      callPreviewActivities ?? false,
    );
    config.modResults["@relayphone/ios-voip-sdk.focusFilter"] = String(
      focusFilter ?? false,
    );
    return config;
  });
  return withInfoPlist(config, (config) => {
    config.modResults.VoIPConversationsMediaAdapter = media;
    config.modResults.VoIPConversationsUnhandledAction =
      unhandledAction ?? "fail";
    return config;
  });
};

/**
 * Gives the app the Communication Notifications capability for call notifications. The call
 * notifications' `INStartCallIntent` is in `NSUserActivityTypes` already; see `withSiriIntents`.
 */
const withCallNotifications: ConfigPlugin<{ callNotifications?: boolean }> = (
  config,
  { callNotifications },
) => {
  if (!callNotifications) return config;
  return withEntitlementsPlist(config, (config) => {
    config.modResults["com.apple.developer.usernotifications.communication"] =
      true;
    return config;
  });
};

/**
 * Configures whether the system's Recents list includes a call after it ends.
 */
const withRecents: ConfigPlugin<{ includesCallsInRecents?: boolean }> = (
  config,
  { includesCallsInRecents },
) => {
  return withInfoPlist(config, (config) => {
    config.modResults.VoIPConversationsIncludesCallsInRecents =
      includesCallsInRecents ?? DEFAULT_INCLUDES_CALLS_IN_RECENTS;
    return config;
  });
};

/**
 * Copies a resource file into the iOS project directory and registers it in the
 * Xcode project so it lands in the app bundle. Shared by the sound-file and
 * icon-template plugins. The caller validates that `sourcePath` exists first, so
 * it can emit a context-specific error message.
 */
function copyResourceFileToProject(
  config: Parameters<Parameters<typeof withXcodeProject>[1]>[0],
  sourcePath: string,
  projectName: string,
) {
  const filename = basename(sourcePath);
  const destinationPath = resolve(
    config.modRequest.projectRoot,
    "ios",
    projectName,
    filename,
  );

  // Copy the file to the iOS project directory
  copyFileSync(sourcePath, destinationPath);

  // Add the file to the Xcode project if not already present
  if (!config.modResults.hasFile(`${projectName}/${filename}`)) {
    config.modResults = IOSConfig.XcodeUtils.addResourceFileToGroup({
      filepath: `${projectName}/${filename}`,
      groupName: projectName,
      isBuildFile: true,
      project: config.modResults,
    });
  }

  return config;
}

/**
 * Copies sound files into the iOS project bundle.
 */
function setSoundFiles(
  config: Parameters<Parameters<typeof withXcodeProject>[1]>[0],
  sounds: string[],
) {
  const projectRoot = config.modRequest.projectRoot;
  const projectName = config.modRequest.projectName;

  if (!projectName) {
    throw new Error(`${ERROR_MSG_PREFIX}Unable to find iOS project name.`);
  }

  for (const soundPath of sounds) {
    const sourcePath = resolve(projectRoot, soundPath);

    if (!existsSync(sourcePath)) {
      throw new Error(`${ERROR_MSG_PREFIX}Sound file not found: ${sourcePath}`);
    }

    config = copyResourceFileToProject(config, sourcePath, projectName);
  }

  return config;
}

/**
 * Copies sound files into the iOS project bundle.
 */
const withSounds: ConfigPlugin<{ sounds?: string[] }> = (
  config,
  { sounds },
) => {
  if (sounds && sounds.length > 0) {
    config = withXcodeProject(config, (config) => {
      return setSoundFiles(config, sounds);
    });
  }
  return config;
};

/**
 * Configures the default ringtone for incoming calls in Info.plist.
 */
const withDefaultRingtone: ConfigPlugin<{
  sounds?: string[];
  defaultRingtone?: string;
}> = (config, { sounds, defaultRingtone }) => {
  const soundFilenames = sounds?.map((s) => basename(s)) ?? [];

  // Validate defaultRingtone if specified and not 'default'
  if (defaultRingtone && defaultRingtone !== "default") {
    if (soundFilenames.length === 0) {
      throw new Error(
        `${ERROR_MSG_PREFIX}"defaultRingtone" was specified but no ` +
          `sounds were provided.`,
      );
    }
    if (!soundFilenames.includes(defaultRingtone)) {
      throw new Error(
        `${ERROR_MSG_PREFIX}"defaultRingtone" must be one of the provided ` +
          `sounds (${soundFilenames.join(", ")}) or "default" for ` +
          `system ringtone.`,
      );
    }
  }

  return withInfoPlist(config, (config) => {
    config.modResults.VoIPConversationsDefaultRingtone = defaultRingtone || "default";
    return config;
  });
};

/**
 * Bundles the app's icon template into the iOS app and records its filename in Info.plist, so
 * the module can pass its PNG data to LiveCommunicationKit's
 * `ConversationManager.Configuration.iconTemplateImageData`.
 */
const withIconTemplate: ConfigPlugin<{
  sounds?: string[];
  iconTemplateIos?: string;
}> = (config, { sounds, iconTemplateIos }) => {
  if (!iconTemplateIos) {
    return config;
  }

  const iconFilename = basename(iconTemplateIos);

  // Sounds and the icon are copied flat into the same directory by filename,
  // so a shared name would silently overwrite one with the other.
  if (sounds?.some((s) => basename(s) === iconFilename)) {
    throw new Error(
      `${ERROR_MSG_PREFIX}"iconTemplateIos" filename "${iconFilename}" ` +
        `collides with a file in "sounds".`,
    );
  }

  // Copy the file into the iOS project and add it as a bundle resource.
  config = withXcodeProject(config, (config) => {
    const projectName = config.modRequest.projectName;

    if (!projectName) {
      throw new Error(`${ERROR_MSG_PREFIX}Unable to find iOS project name.`);
    }

    const sourcePath = resolve(config.modRequest.projectRoot, iconTemplateIos);

    if (!existsSync(sourcePath)) {
      throw new Error(
        `${ERROR_MSG_PREFIX}Icon template file not found: ${sourcePath}`,
      );
    }

    return copyResourceFileToProject(config, sourcePath, projectName);
  });

  // Record the filename so the native side can resolve it from the bundle.
  config = withInfoPlist(config, (config) => {
    config.modResults.VoIPConversationsIconTemplate = iconFilename;
    return config;
  });

  return config;
};

/**
 * Fails for the removed `callingFramework` option. Calls are always presented with
 * LiveCommunicationKit.
 */
function rejectRemovedOptions(props: VoIPConversationsPluginProps): void {
  if ((props as { callingFramework?: unknown }).callingFramework !== undefined) {
    throw new Error(
      `${ERROR_MSG_PREFIX}The "callingFramework" option was removed: iOS calls are always ` +
        `presented with LiveCommunicationKit. Remove the option from the plugin's configuration.`,
    );
  }
}

export const withVoIPConversationsIos: ConfigPlugin<VoIPConversationsPluginProps> = (
  config,
  props,
) => {
  rejectRemovedOptions(props);
  const {
    cameraPermission,
    microphonePermission,
    incomingCallTimeout,
    fulfillAnswerCallTimeout,
    includesCallsInRecents,
    sounds,
    defaultRingtoneIos,
    iconTemplateIos,
    mediaAdapter,
    simulator,
    unhandledAction,
    callNotifications,
    callPreviewActivities,
    focusFilter,
  } = props;
  config = withCallCore(config, {
    mediaAdapter,
    simulator,
    unhandledAction,
    callNotifications,
    callPreviewActivities: Boolean(callPreviewActivities),
    focusFilter: Boolean(focusFilter),
  });
  config = withCallNotifications(config, { callNotifications });
  config = withCallPreviewActivities(config, { callPreviewActivities });
  config = withFocusFilter(config, { focusFilter });
  config = withPermissions(config, { cameraPermission, microphonePermission });
  config = withPushNotificationEntitlement(config);
  config = withBackgroundModes(config);
  config = withSiriIntents(config);
  config = withTimeouts(config, {
    incomingCallTimeout,
    fulfillAnswerCallTimeout,
  });
  config = withRecents(config, { includesCallsInRecents });
  config = withSounds(config, { sounds });
  config = withDefaultRingtone(config, {
    sounds,
    defaultRingtone: defaultRingtoneIos,
  });
  config = withIconTemplate(config, { sounds, iconTemplateIos });

  return config;
};
