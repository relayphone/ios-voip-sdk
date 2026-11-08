import assert from "node:assert/strict";
import { describe, it } from "node:test";
import type { ExpoConfig } from "expo/config";
import type { ModConfig } from "expo/config-plugins.js";

import type { VoIPConversationsPluginProps } from "../../build/withVoIPConversations.js";
import {
  withVoIPConversationsIos,
} from "../../build/withVoIPConversationsIos.js";

/**
 * Applies the iOS plugin to a bare config and executes one registered mod
 * chain against the given results (empty by default), returning the resulting
 * entries. This exercises every mod of that kind the plugin composes, without
 * running a full prebuild.
 */
async function evaluateMod(
  props: VoIPConversationsPluginProps,
  modName: "infoPlist" | "podfileProperties" | "entitlements",
  modResults: Record<string, unknown> = {},
): Promise<Record<string, unknown>> {
  const config: ExpoConfig & { mods?: ModConfig } = withVoIPConversationsIos(
    { name: "test-app", slug: "test-app" },
    props,
  );

  const mod = config.mods?.ios?.[modName] as unknown as
    | ((config: unknown) => Promise<{ modResults: Record<string, unknown> }>)
    | undefined;
  if (!mod) throw new Error(`The plugin registered no ${modName} mod.`);

  const result = await mod({
    ...config,
    modResults,
    modRequest: {
      projectRoot: "/tmp/test-app",
      platformProjectRoot: "/tmp/test-app/ios",
      modName,
      platform: "ios",
      introspect: true,
    },
    modRawConfig: { name: "test-app", slug: "test-app" },
  });
  return result.modResults;
}

const evaluateInfoPlist = (props: VoIPConversationsPluginProps) =>
  evaluateMod(props, "infoPlist");

describe("withVoIPConversationsIos Info.plist configuration", () => {
  it("defaults VoIPConversationsIncludesCallsInRecents to true when the prop is omitted", async () => {
    const plist = await evaluateInfoPlist({});
    assert.strictEqual(plist.VoIPConversationsIncludesCallsInRecents, true);
  });

  it("writes VoIPConversationsIncludesCallsInRecents=false when the prop is false", async () => {
    const plist = await evaluateInfoPlist({ includesCallsInRecents: false });
    assert.strictEqual(plist.VoIPConversationsIncludesCallsInRecents, false);
  });

  it("writes VoIPConversationsIncludesCallsInRecents=true when the prop is explicitly true", async () => {
    const plist = await evaluateInfoPlist({ includesCallsInRecents: true });
    assert.strictEqual(plist.VoIPConversationsIncludesCallsInRecents, true);
  });

  it("keeps writing the timeout defaults alongside the new key (chain intact)", async () => {
    const plist = await evaluateInfoPlist({});
    assert.strictEqual(plist.VoIPConversationsIncomingCallTimeout, 45);
    assert.strictEqual(plist.VoIPConversationsFulfillAnswerCallTimeout, 30);
  });

  it("writes the media adapter and unhandled action for the native module", async () => {
    assert.partialDeepStrictEqual(await evaluateInfoPlist({}), {
      VoIPConversationsMediaAdapter: "webrtc",
      VoIPConversationsUnhandledAction: "fail",
    });
    assert.partialDeepStrictEqual(await evaluateInfoPlist({ mediaAdapter: "none", unhandledAction: "accept" }), {
      VoIPConversationsMediaAdapter: "none",
      VoIPConversationsUnhandledAction: "accept",
    });
  });
});

describe("withVoIPConversationsIos call core selection", () => {
  it("defaults to WebRTC media without the simulator runtime", async () => {
    assert.deepStrictEqual(await evaluateMod({}, "podfileProperties"), {
      "@relayphone/ios-voip-sdk.mediaAdapter": "webrtc",
      "@relayphone/ios-voip-sdk.simulator": "false",
      "@relayphone/ios-voip-sdk.callNotifications": "false",
      "@relayphone/ios-voip-sdk.callPreviewActivities": "false",
      "@relayphone/ios-voip-sdk.focusFilter": "false",
    });
  });

  it("selects the media adapter and the simulator runtime", async () => {
    assert.deepStrictEqual(await evaluateMod(
        { simulator: true, mediaAdapter: "webrtc" },
        "podfileProperties",
      ), {
      "@relayphone/ios-voip-sdk.mediaAdapter": "webrtc",
      "@relayphone/ios-voip-sdk.simulator": "true",
      "@relayphone/ios-voip-sdk.callNotifications": "false",
      "@relayphone/ios-voip-sdk.callPreviewActivities": "false",
      "@relayphone/ios-voip-sdk.focusFilter": "false",
    });
  });

  it("drops the calling framework property that earlier versions wrote", async () => {
    assert.equal("@relayphone/ios-voip-sdk.callingFramework" in (await evaluateMod({}, "podfileProperties", {
        "@relayphone/ios-voip-sdk.callingFramework": "callKit",
      })), false);
  });

  it("rejects the removed calling framework option", () => {
    for (const callingFramework of ["callKit", "liveCommunicationKit"]) {
      assert.throws(() =>
        withVoIPConversationsIos(
          { name: "test-app", slug: "test-app" },
          { callingFramework } as VoIPConversationsPluginProps,
        ), new RegExp("The \"callingFramework\" option was removed"));
    }
  });


});

describe("withVoIPConversationsIos call notifications", () => {
  it("adds the Notifications subspec and the Communication Notifications capability", async () => {
    assert.partialDeepStrictEqual(await evaluateMod({ callNotifications: true }, "podfileProperties"), { "@relayphone/ios-voip-sdk.callNotifications": "true" });
    assert.partialDeepStrictEqual(await evaluateMod({ callNotifications: true }, "entitlements"), {
      "com.apple.developer.usernotifications.communication": true,
    });
    const types = (await evaluateInfoPlist({ callNotifications: true })).NSUserActivityTypes;
    assert.ok(Array.isArray(types));
    assert.ok(types.includes("INStartCallIntent"));
  });

  it("adds neither without the option", async () => {
    assert.equal("com.apple.developer.usernotifications.communication" in (await evaluateMod({}, "entitlements")), false);
  });
});
