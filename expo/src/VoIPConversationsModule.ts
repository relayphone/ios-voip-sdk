import { requireNativeModule } from "expo";
import { Platform } from "react-native";

import { bindAndroid, type AndroidBridge } from "./conversations/android";
import { withCommandErrors } from "./conversations/errors";
import type { NativeTransport } from "./conversations/transport";

export default Platform.OS === "android"
  ? bindAndroid(requireNativeModule<AndroidBridge>("VoIPConversations"))
  : withCommandErrors(requireNativeModule<NativeTransport>("VoIPConversations"));
