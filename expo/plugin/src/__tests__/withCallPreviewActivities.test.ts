import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import type { ExpoConfig } from "expo/config";
import { createRequire } from "node:module";
import type { ModConfig, XcodeProject } from "expo/config-plugins";
import { join } from "path";
import { isList, isRecord, isString } from "../../../../tools/json-fields.ts";

import {
  addCallPreviewWidget,
  addWidgetPods,
  WIDGET_TARGET,
  widgetFiles,
  withWidgetCredentials,
} from "../../build/withCallPreviewActivities.js";
import type { VoIPConversationsPluginProps } from "../../build/withVoIPConversations.js";
import { withVoIPConversationsIos } from "../../build/withVoIPConversationsIos.js";

// Load config-plugins values the way the shipped CommonJS plugin does, so these tests resolve
// `expo/config-plugins` on Expo releases with and without a package exports map.
// SAFETY: The loader resolves the same Expo module whose declarations describe IOSConfig.
const { IOSConfig } = createRequire(import.meta.url)("expo/config-plugins") as typeof import("expo/config-plugins");

const app: ExpoConfig = {
  name: "test-app",
  slug: "test-app",
  version: "2.3.4",
  ios: { bundleIdentifier: "com.example.calls", buildNumber: "17" },
};

/** Applies the iOS plugin and runs one of its mods against the given results. */
async function evaluateMod(
  props: VoIPConversationsPluginProps,
  modName: "infoPlist" | "podfileProperties",
) {
  const config: ExpoConfig & { mods?: ModConfig } = withVoIPConversationsIos(
    { ...app },
    props,
  );
  const mod = config.mods?.ios?.[modName];
  if (!mod) throw new Error(`The plugin registered no ${modName} mod.`);
  const result = await mod({
    ...config,
    modResults: {},
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

/** The Expo template's Xcode project, whose app target is `HelloWorld`. */
function templateProject() {
  return IOSConfig.XcodeUtils.getPbxproj(join(import.meta.dirname, "fixtures"));
}

function fields(value: unknown) {
  assert.ok(isRecord(value));
  return new Map<string, unknown>(Object.entries(value));
}

function section(project: XcodeProject, name: string) {
  const objects = fields(project.hash.project.objects);
  const value = objects.get(name);
  return value === undefined ? new Map<string, unknown>() : fields(value);
}

function links(value: unknown, key: "value" | "comment") {
  assert.ok(isList(value));
  return value.map(entry => {
    const link = fields(entry).get(key);
    assert.ok(isString(link));
    return link;
  });
}

function configurationIDs(project: XcodeProject, target: ReadonlyMap<string, unknown>) {
  const id = target.get("buildConfigurationList");
  assert.ok(isString(id));
  const list = fields(section(project, "XCConfigurationList").get(id));
  return links(list.get("buildConfigurations"), "value");
}

/** The names of the files in a target's build phase of the given type. */
function phaseFiles(project: XcodeProject, targetName: string, type: string) {
  const target = section(project, "PBXNativeTarget").values().find(
    entry => isRecord(entry) && "name" in entry && String(entry.name).replace(/"/g, "") === targetName,
  );
  assert.ok(target);
  const phases = section(project, type);
  return links(fields(target).get("buildPhases"), "value").flatMap(id => {
    const phase = phases.get(id);
    return isRecord(phase) ? links(fields(phase).get("files"), "comment") : [];
  });
}

describe("withVoIPConversationsIos call preview Live Activities", () => {
  it("adds the LiveActivity subspec and supports Live Activities", async () => {
    assert.partialDeepStrictEqual(await evaluateMod({ callPreviewActivities: true }, "podfileProperties"), { "@relayphone/ios-voip-sdk.callPreviewActivities": "true" });
    assert.partialDeepStrictEqual(await evaluateMod({ callPreviewActivities: true }, "infoPlist"), {
      NSSupportsLiveActivities: true,
    });
    assert.equal("NSSupportsLiveActivities" in (await evaluateMod({}, "infoPlist")), false);
  });

  it("generates the widget extension unless the app brings its own", () => {
    const generated: ExpoConfig & { mods?: ModConfig } =
      withVoIPConversationsIos({ ...app }, { callPreviewActivities: true });
    assert.notEqual(generated.mods?.ios?.xcodeproj, undefined);
    assert.ok(generated.mods?.ios && "podfile" in generated.mods.ios);
    const own: ExpoConfig & { mods?: ModConfig } = withVoIPConversationsIos(
      { ...app },
      { callPreviewActivities: { widgetExtension: false } },
    );
    assert.equal(own.mods?.ios?.xcodeproj, undefined);
    assert.equal(own.extra, undefined);
  });

  it("needs the app's bundle identifier for the widget extension's", () => {
    assert.throws(() =>
      withVoIPConversationsIos(
        { name: "test-app", slug: "test-app" },
        { callPreviewActivities: true },
      ), new RegExp("\"ios\\.bundleIdentifier\""));
  });

  it("declares the widget extension for EAS Build once", () => {
    const config = withWidgetCredentials(
      withWidgetCredentials(
        {
          ...app,
          extra: { eas: { projectId: "project", build: { other: true } } },
        },
        "com.example.calls",
      ),
      "com.example.calls",
    );
    assert.deepStrictEqual(config.extra, {
      eas: {
        projectId: "project",
        build: {
          other: true,
          experimental: {
            ios: {
              appExtensions: [
                {
                  targetName: WIDGET_TARGET,
                  bundleIdentifier: "com.example.calls.CallPreviewWidget",
                  entitlements: {},
                },
              ],
            },
          },
        },
      },
    });
  });
});

describe("addCallPreviewWidget", () => {
  it("uses default widget build versions when app versions are omitted", () => {
    const project = addCallPreviewWidget(templateProject(), {
      projectName: "HelloWorld",
      bundleIdentifier: "com.example.calls",
      config: { name: "test-app", slug: "test-app" },
    });
    const widget = fields(project.pbxTargetByName(`"${WIDGET_TARGET}"`));
    const ids = configurationIDs(project, widget);
    const configurations = section(project, "XCBuildConfiguration");
    assert.equal(ids.length, 2);
    for (const id of ids) {
      assert.partialDeepStrictEqual(configurations.get(id), {
        buildSettings: {
          MARKETING_VERSION: "1.0.0",
          CURRENT_PROJECT_VERSION: "1",
        },
      });
    }
  });

  it("adds the widget extension, embedded in the app, and the shared Join intent", () => {
    const project = addCallPreviewWidget(templateProject(), {
      projectName: "HelloWorld",
      bundleIdentifier: "com.example.calls",
      config: app,
    });
    const widget = fields(project.pbxTargetByName(`"${WIDGET_TARGET}"`));
    assert.strictEqual(widget.get("productType"), '"com.apple.product-type.app-extension"');
    assert.deepStrictEqual(phaseFiles(project, WIDGET_TARGET, "PBXSourcesBuildPhase"), [
      "CallPreviewWidget.swift in Sources",
      "JoinCallPreview.swift in Sources",
    ]);
    assert.ok((phaseFiles(project, "HelloWorld", "PBXSourcesBuildPhase")).includes("JoinCallPreview.swift in Sources"));
    assert.deepStrictEqual(phaseFiles(project, "HelloWorld", "PBXCopyFilesBuildPhase"), ["CallPreviewWidget.appex in Embed Foundation Extensions"]);
    const embed = section(project, "PBXCopyFilesBuildPhase").values().find(isRecord);
    assert.partialDeepStrictEqual(embed, { dstSubfolderSpec: 13, dstPath: '""' });

    const configurations = section(project, "XCBuildConfiguration");
    const settings = configurationIDs(project, widget).map(
      id => fields(configurations.get(id)).get("buildSettings"),
    );
    assert.equal((settings).length, 2);
    for (const setting of settings) {
      assert.partialDeepStrictEqual(setting, {
        PRODUCT_BUNDLE_IDENTIFIER: '"com.example.calls.CallPreviewWidget"',
        INFOPLIST_FILE: "CallPreviewWidget/Info.plist",
        IPHONEOS_DEPLOYMENT_TARGET: "26.0",
        SWIFT_VERSION: "6.0",
        MARKETING_VERSION: "2.3.4",
        CURRENT_PROJECT_VERSION: "17",
      });
    }
    assert.equal((project.writeSync()).includes("undefined"), false);
  });

  it("leaves a project that has the widget extension unchanged", () => {
    const options = {
      projectName: "HelloWorld",
      bundleIdentifier: "com.example.calls",
      config: app,
    };
    const project = addCallPreviewWidget(templateProject(), options);
    const once = project.writeSync();
    assert.strictEqual(addCallPreviewWidget(project, options).writeSync(), once);
  });
});

describe("the widget extension's files and pods", () => {
  it("gives the extension the app's version and the shared Join intent", () => {
    const files = widgetFiles(app);
    assert.ok((files["Info.plist"]).includes("<string>2.3.4</string>"));
    assert.ok((files["Info.plist"]).includes("<string>17</string>"));
    assert.ok((files["Info.plist"]).includes("com.apple.widgetkit-extension"));
    assert.ok((files["CallPreviewWidget.swift"]).includes("join: JoinCallPreview.self"));
    assert.ok((files["JoinCallPreview.swift"]).includes("struct JoinCallPreview: JoinCallPreviewIntent"));
    assert.ok((files["JoinCallPreview.swift"]).includes(".foreground(.immediate)"));
  });

  it("adds the extension's pod target once, from the app's SDK source", () => {
    const podfile = "target 'App' do\n  use_expo_modules!\nend\n";
    const once = addWidgetPods(podfile);
    assert.strictEqual(addWidgetPods(once), once);
    assert.ok((once).includes("pod 'VoIPConversations/LiveActivity', :path =>"));
    assert.ok((once).includes("require.resolve('@relayphone/ios-voip-sdk/package.json'"));
    assert.equal((once).includes(":git"), false);
    assert.strictEqual(once.startsWith(podfile), true);
  });

  it("uses the same relative package source as Expo autolinking", t => {
    const directory = mkdtempSync(join(tmpdir(), "voip-widget-pods-"));
    t.after(() => rmSync(directory, { recursive: true, force: true }));
    const root = realpathSync(directory);
    mkdirSync(join(root, "ios"));
    const podfile = join(root, "ios/Podfile");
    writeFileSync(podfile, addWidgetPods(""));
    const result = spawnSync("ruby", ["-rpathname", "-rjson", "-e", `
      module Pod
        module Executable
          def self.execute_command(*args); ENV.fetch('PACKAGE_JSON'); end
        end
      end
      def target(name); yield; end
      def pod(name, path:); puts JSON.generate({name: name, path: path}); end
      load ARGV.fetch(0)
    `, podfile], {
      encoding: "utf8",
      timeout: 10_000,
      env: { ...process.env, PACKAGE_JSON: join(root, "node_modules/@relayphone/ios-voip-sdk/package.json") },
    });
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(JSON.parse(result.stdout), {
      name: "VoIPConversations/LiveActivity",
      path: "../node_modules/@relayphone/ios-voip-sdk/ios",
    });
  });
});
