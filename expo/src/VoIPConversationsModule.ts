import { requireNativeModule } from "expo";

import { withCommandErrors } from "./conversations/errors";
import type { NativeTransport } from "./conversations/transport";

export default withCommandErrors(
  requireNativeModule<NativeTransport>("VoIPConversations")
);
