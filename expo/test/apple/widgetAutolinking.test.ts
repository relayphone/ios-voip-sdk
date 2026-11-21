import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

import { addWidgetPods } from "../../plugin/build/withCallPreviewActivities.js";

test("uses the same relative package source as Expo autolinking", t => {
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
  assert.ifError(result.error);
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), {
    name: "VoIPConversations/LiveActivity",
    path: "../node_modules/@relayphone/ios-voip-sdk/ios",
  });
});
