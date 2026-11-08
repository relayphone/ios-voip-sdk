import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { copyFileSync, mkdirSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { test } from "node:test";

import { widgetFiles } from "../../build/withCallPreviewActivities.js";

test("generated intents and the example Focus filter compile alongside Expo's internal imports", t => {
  const root = mkdtempSync(join(tmpdir(), "voip-swift-sources-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const packageRoot = resolve(import.meta.dirname, "../../..");
  const moduleCache = join(root, "ModuleCache");
  mkdirSync(moduleCache);
  const sdk = spawnSync("xcrun", ["--sdk", "iphonesimulator", "--show-sdk-path"], {
    encoding: "utf8", timeout: 10_000,
  });
  assert.equal(sdk.status, 0, sdk.stderr);
  const platform = ["-sdk", sdk.stdout.trim(), "-target", "arm64-apple-ios26.0-simulator",
    "-module-cache-path", moduleCache];
  const compile = (args: string[]) => {
    const result = spawnSync("xcrun", ["swiftc", ...platform, ...args], {
      encoding: "utf8", timeout: 60_000,
    });
    assert.equal(result.status, 0, result.stderr);
  };

  // Emit the real SDK API used by the extension sources as the CocoaPods module.
  const sources = ["VoIPCore", "VoIPFocus", "VoIPLiveActivity"].flatMap(target =>
    readdirSync(join(packageRoot, "../Sources", target), { recursive: true, encoding: "utf8" })
      .filter(path => path.endsWith(".swift"))
      .map(path => join(packageRoot, "../Sources", target, path)),
  );
  compile(["-emit-module", "-parse-as-library", "-swift-version", "6",
    "-enable-upcoming-feature", "ExistentialAny",
    "-enable-upcoming-feature", "InternalImportsByDefault",
    "-enable-upcoming-feature", "MemberImportVisibility",
    "-module-name", "VoIPConversations", "-emit-module-path", join(root, "VoIPConversations.swiftmodule"),
    ...sources]);
  for (const [name, contents] of Object.entries(widgetFiles({ name: "Calls", slug: "calls" }))) {
    writeFileSync(join(root, name), contents);
  }
  const focus = join(root, "CallsFocusFilter.swift");
  copyFileSync(join(packageRoot, "example/client/focus/CallsFocusFilter.swift"), focus);
  const provider = join(root, "ExpoModulesProvider.swift");
  writeFileSync(provider, "internal import VoIPConversations\n");
  const intent = join(root, "JoinCallPreview.swift");
  compile(["-typecheck", "-parse-as-library", "-swift-version", "5", "-I", root,
    "-module-name", "ExampleApp", intent, focus, provider]);
  compile(["-typecheck", "-parse-as-library", "-swift-version", "6", "-I", root,
    "-module-name", "CallPreviewWidget", intent, join(root, "CallPreviewWidget.swift")]);
});
