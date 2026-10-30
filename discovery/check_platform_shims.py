#!/usr/bin/env python3
"""Host controls and compile-only checks; never boots a simulator or registers push."""
from __future__ import annotations

import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PLATFORM = ROOT / "Sources/VoIPPlatform"

HOST = r'''
#import <Foundation/Foundation.h>
#import "VSCompletionOnce.h"

static void require(BOOL condition, const char *reason) {
  if (!condition) { fprintf(stderr, "%s\n", reason); exit(1); }
}
int main(int argc, const char **argv) {
  @autoreleasepool {
    require(argc == 2 && strcmp(argv[1], "completion-race") == 0, "the completion-race control is required");
    __block NSUInteger calls = 0;
    NSObject *receiver = [NSObject new];
    __weak NSObject *weakReceiver = receiver;
    VSCompletionOnce *once = [[VSCompletionOnce alloc] initWithCompletion:^{
      require([NSThread isMainThread], "completion must run on main");
      require(weakReceiver != nil, "receiver must survive through completion");
      calls++;
    } retaining:receiver];
    receiver = nil;
    require(weakReceiver != nil, "receiver must survive pending work");
    dispatch_group_t group = dispatch_group_create();
    for (NSUInteger i = 0; i < 250; i++) dispatch_group_async(group,
        dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ [once finish]; });
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
      [once finish];
      require(calls == 1, "completion must settle exactly once under races");
      dispatch_async(dispatch_get_main_queue(), ^{
        require(weakReceiver == nil, "receiver must be released after completion");
        puts("passed"); exit(0);
      });
    });
    [[NSRunLoop mainRunLoop] run];
  }
  return 0;
}
'''

SWIFT = '''
import Foundation
import VoIPPlatform
@MainActor final class Receiver: NSObject, PushReceiver {
  func pushTokenDidUpdate(_ token: Data) {}
  func pushTokenDidInvalidate() {}
  nonisolated func receiveVoIPPush(_ payload: [AnyHashable: Any], mustReport: Bool,
                                   delivery: PushDelivery) { delivery.finish() }
}
@MainActor func checkImports() throws {
  let receiver = Receiver()
  let owner = try PushRegistryOwner.shared(receiver: receiver)
  try owner.start()
  _ = owner.isStarted
}
'''


def run(command: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(command, text=True, capture_output=True, timeout=60, **kwargs)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result


def main() -> None:
    checks: list[str] = []
    with tempfile.TemporaryDirectory(prefix="ios-voip-platform-") as directory:
        out = Path(directory)
        host = out / "host.m"
        host.write_text(HOST)
        binary = out / "platform-controls"
        run(["xcrun", "clang", "-fobjc-arc", "-fblocks", "-DDEBUG=1", "-Wall", "-Wextra",
             "-Werror", "-Wno-unused-parameter", "-I", str(PLATFORM), str(host),
             str(PLATFORM / "VSCompletionOnce.m"), "-framework", "Foundation", "-o", str(binary)])
        if run([str(binary), "completion-race"]).stdout.strip() != "passed":
            raise RuntimeError("Host control did not acknowledge success: completion-race")
        checks.append("host:completion-race")

        module = out / "module.modulemap"
        module.write_text(f'module VoIPPlatform {{ umbrella header "{PLATFORM / "include/VoIPPlatform.h"}" export * }}\n')
        swift = out / "import.swift"
        swift.write_text(SWIFT)
        implementations = sorted(str(path) for path in PLATFORM.glob("*.m"))
        configurations = [
            ("iphonesimulator", "arm64-apple-ios26.0-simulator"),
            ("iphoneos", "arm64-apple-ios26.0"),
            ("watchos", "arm64_32-apple-watchos10.4"),
        ]
        for sdk_name, target in configurations:
            sdk = run(["xcrun", "--sdk", sdk_name, "--show-sdk-path"]).stdout.strip()
            for debug in (0, 1):
                run(["xcrun", "clang", "-fobjc-arc", "-fblocks", "-fsyntax-only", "-Werror", "-Wall", "-Wextra",
                     "-Wno-unused-parameter", "-isysroot", sdk, "-target", target, f"-DDEBUG={debug}", *implementations])
                checks.append(f"compile:{sdk_name}:DEBUG={debug}")
            run(["xcrun", "swiftc", "-typecheck", "-D", "DEBUG", "-Xcc", "-DDEBUG=1", "-swift-version", "6", "-strict-concurrency=complete",
                 "-sdk", sdk, "-target", target, "-I", str(out),
                 "-module-cache-path", str(out / "modules"), str(swift)])
            checks.append(f"swift-import:{sdk_name}")
    print(json.dumps({"success": True, "checks": checks, "count": len(checks)}, indent=2))

if __name__ == "__main__":
    main()
