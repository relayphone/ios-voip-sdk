import assert from "node:assert/strict";
import { describe, it } from "node:test";
import type { ExpoConfig } from "expo/config";
import { IOSConfig, type ModConfig } from "expo/config-plugins.js";
import { mkdtempSync, readFileSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";

import type { VoIPConversationsPluginProps } from "../../build/withVoIPConversations.js";
import { withVoIPConversationsIos } from "../../build/withVoIPConversationsIos.js";
import { addFocusFilterSources } from "../../build/withFocusFilter.js";

const app: ExpoConfig = { name: "test-app", slug: "test-app" };
const focusFilter = { appGroup: "group.com.example.calls" };

/** Applies the iOS plugin and runs one of its mods against the given results. */
async function evaluateMod(
  props: VoIPConversationsPluginProps,
  modName: "infoPlist" | "podfileProperties" | "entitlements",
  modResults: Record<string, unknown> = {},
): Promise<Record<string, unknown>> {
  const config: ExpoConfig & { mods?: ModConfig } = withVoIPConversationsIos(
    { ...app },
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
    modRawConfig: { ...app },
  });
  return result.modResults;
}

describe("withVoIPConversationsIos Focus filter", () => {
  it("adds the Focus subspec, the App Group and its identifier for the module", async () => {
    assert.partialDeepStrictEqual(await evaluateMod({ focusFilter }, "podfileProperties"), { "@relayphone/ios-voip-sdk.focusFilter": "true" });
    assert.partialDeepStrictEqual(await evaluateMod({ focusFilter }, "infoPlist"), {
      VoIPConversationsFocusAppGroup: "group.com.example.calls",
    });
    assert.partialDeepStrictEqual(await evaluateMod({ focusFilter }, "entitlements", {
        "com.apple.security.application-groups": [
          "group.com.example.other",
          "group.com.example.calls",
        ],
      }), {
      "com.apple.security.application-groups": [
        "group.com.example.other",
        "group.com.example.calls",
      ],
    });
    assert.equal("VoIPConversationsFocusAppGroup" in (await evaluateMod({}, "infoPlist")), false);
  });

  it("needs an App Group identifier", () => {
    assert.throws(() =>
      withVoIPConversationsIos(
        { ...app },
        { focusFilter: { appGroup: "com.example.calls" } },
      ), new RegExp("\"focusFilter\\.appGroup\" must be an App Group identifier"));
  });

  it("compiles the filter's sources in the app only when there are some", () => {
    const withoutSources: ExpoConfig & { mods?: ModConfig } =
      withVoIPConversationsIos({ ...app }, { focusFilter });
    assert.equal(withoutSources.mods?.ios?.xcodeproj, undefined);
    const withSources: ExpoConfig & { mods?: ModConfig } =
      withVoIPConversationsIos(
        { ...app },
        { focusFilter: { ...focusFilter, sources: ["./focus/Filter.swift"] } },
      );
    assert.notEqual(withSources.mods?.ios?.xcodeproj, undefined);
  });
});

describe("addFocusFilterSources", () => {
  function setUp() {
    const projectRoot = mkdtempSync(join(tmpdir(), "focus-filter-"));
    writeFileSync(join(projectRoot, "Filter.swift"), "struct Filter {}\n");
    const project = IOSConfig.XcodeUtils.getPbxproj(
      join(import.meta.dirname, "fixtures"),
    );
    return { projectRoot, project };
  }

  it("copies the sources and compiles them in the app target, once", () => {
    const { projectRoot, project } = setUp();
    const options = {
      projectRoot,
      projectName: "HelloWorld",
      sources: ["./Filter.swift"],
    };
    addFocusFilterSources(project, options);
    assert.strictEqual(readFileSync(
        join(projectRoot, "ios/HelloWorld/FocusFilter/Filter.swift"),
        "utf8",
      ), "struct Filter {}\n");
    const once = project.writeSync();
    assert.ok((once).includes("/* Filter.swift in Sources */ = {isa = PBXBuildFile; fileRef = "));
    assert.ok((once).includes('path = "HelloWorld/FocusFilter/Filter.swift"'));
    assert.strictEqual(addFocusFilterSources(project, options).writeSync(), once);
  });

  it("rejects a missing file and files that aren't Swift", () => {
    const { projectRoot, project } = setUp();
    assert.throws(() =>
      addFocusFilterSources(project, {
        projectRoot,
        projectName: "HelloWorld",
        sources: ["./Missing.swift"],
      }), new RegExp("Focus filter source not found"));
    assert.throws(() =>
      addFocusFilterSources(project, {
        projectRoot,
        projectName: "HelloWorld",
        sources: ["./Filter.m"],
      }), new RegExp("isn't a Swift file"));
  });
});
