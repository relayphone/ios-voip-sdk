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
#import <objc/runtime.h>
#import "VSCompletionOnce.h"
#import "VSProviderMonitorInternal.h"

static NSUInteger warnings, roots, concretes, destroyed;
static void require(BOOL condition, const char *reason) {
  if (!condition) { fprintf(stderr, "%s\n", reason); exit(1); }
}
@interface VSFixtureProvider : NSObject
@property(nonatomic, strong) id configuration;
- (instancetype)initWithConfiguration:(id)configuration;
@end
@implementation VSFixtureProvider
- (instancetype)initWithConfiguration:(id)configuration {
  if ((self = [super init])) { roots++; self.configuration = configuration; }
  return self;
}
- (void)dealloc { destroyed++; }
@end
@interface VSFixtureCluster : VSFixtureProvider @end
@interface VSFixtureConcrete : VSFixtureCluster @end
@implementation VSFixtureConcrete
- (instancetype)initWithConfiguration:(id)configuration {
  concretes++;
  return [super initWithConfiguration:configuration];
}
@end
@implementation VSFixtureCluster
+ (id)allocWithZone:(NSZone *)zone {
  if (self == VSFixtureCluster.class) return [VSFixtureConcrete allocWithZone:zone];
  return [super allocWithZone:zone];
}
@end
@interface VSFixtureNil : VSFixtureProvider @end
@implementation VSFixtureNil
- (instancetype)initWithConfiguration:(id)configuration { return nil; }
@end

static void diagnostic(NSString *message) {
  require([NSThread isMainThread], "diagnostic must run on main");
  require(message.length > 0, "diagnostic must explain the condition");
  warnings++;
}
static void created(Class cls) {
  @autoreleasepool {
    NSObject *configuration = [NSObject new];
    VSFixtureProvider *provider = [[cls alloc] initWithConfiguration:configuration];
    require(provider.configuration == configuration, "original initializer must run");
  }
}
int main(int argc, const char **argv) {
  @autoreleasepool {
    require(argc == 2, "one control name is required");
    NSString *mode = @(argv[1]);
    if ([mode isEqual:@"completion-race"]) {
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
    IMP globalAllocator = class_getMethodImplementation(object_getClass(NSObject.class), @selector(allocWithZone:));
    if ([mode isEqual:@"unsupported"]) {
      require(!VSProviderMonitorInstall(NSObject.class, ^(NSString *m){ diagnostic(m); }), "missing initializer must refuse");
      require(warnings == 1, "unsupported ABI must diagnose");
      require(globalAllocator == class_getMethodImplementation(object_getClass(NSObject.class), @selector(allocWithZone:)), "NSObject must remain untouched");
      puts("passed"); return 0;
    }
    Class cls = [mode isEqual:@"cluster"] ? VSFixtureCluster.class :
        ([mode isEqual:@"nil"] ? VSFixtureNil.class : VSFixtureProvider.class);
    require(VSProviderMonitorInstall(cls, ^(NSString *m){ diagnostic(m); }), "public hooks must install");
    require(VSProviderMonitorInstall(cls, ^(NSString *m){ diagnostic(m); }), "installation must be idempotent");
    require(globalAllocator == class_getMethodImplementation(object_getClass(NSObject.class), @selector(allocWithZone:)), "NSObject allocator must never be swapped");
    if ([mode isEqual:@"background"]) {
      VSProviderMonitorBeginOwnedCreation();
      dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        created(cls);
        dispatch_async(dispatch_get_main_queue(), ^{
          require(warnings == 1, "background creation cannot consume the owned bracket");
          VSProviderMonitorEndOwnedCreation();
          require(warnings == 2, "missing owned creation must diagnose");
          puts("passed"); exit(0);
        });
      });
      [[NSRunLoop mainRunLoop] run];
    }
    VSProviderMonitorBeginOwnedCreation();
    if ([mode isEqual:@"nil"]) {
      require([[cls alloc] initWithConfiguration:[NSObject new]] == nil, "nil initializer result must remain nil");
      VSProviderMonitorEndOwnedCreation();
      require(warnings == 1, "missing owned creation must diagnose");
      puts("passed"); return 0;
    }
    created(cls);
    if ([mode isEqual:@"extra-owned"]) {
      created(cls);
      require(warnings == 1, "second provider inside the bracket must warn");
      VSProviderMonitorEndOwnedCreation();
    } else {
      VSProviderMonitorEndOwnedCreation();
      require(warnings == 0, "one owned provider must not warn");
      created(cls);
      require(warnings == 1, "later provider must warn exactly once");
    }
    require(roots == 2 && destroyed == 2, "initializer and ARC ownership must remain balanced");
    if ([mode isEqual:@"cluster"]) require(concretes == 2, "concrete/super initializer chain must run once");
    puts("passed");
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
  func receiveVoIPPush(_ payload: [AnyHashable: Any], mustReport: Bool,
                       completion: @escaping () -> Void) { completion() }
}
@MainActor func checkImports() throws {
  let receiver = Receiver()
  let owner = try PushRegistryOwner.shared(receiver: receiver)
  try owner.start()
  _ = owner.isStarted
  ProviderCreationMonitor.install(diagnosticHandler: { _ in })
  ProviderCreationMonitor.beginOwnedManagerCreation()
  ProviderCreationMonitor.endOwnedManagerCreation()
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
             str(PLATFORM / "VSCompletionOnce.m"), str(PLATFORM / "VSProviderMonitorInternal.m"),
             "-framework", "Foundation", "-o", str(binary)])
        for case in ["completion-race", "plain", "cluster", "extra-owned", "background", "nil", "unsupported"]:
            result = run([str(binary), case])
            if result.stdout.strip() != "passed":
                raise RuntimeError(f"Host control did not acknowledge success: {case}")
            checks.append(f"host:{case}")

        module = out / "module.modulemap"
        module.write_text(f'module VoIPPlatform {{ umbrella header "{PLATFORM / "include/VoIPPlatform.h"}" export * }}\n')
        swift = out / "import.swift"
        swift.write_text(SWIFT)
        implementations = sorted(str(path) for path in PLATFORM.glob("*.m"))
        configurations = [
            ("iphonesimulator", "arm64-apple-ios17.4-simulator"),
            ("iphoneos", "arm64-apple-ios17.4"),
            ("watchos", "arm64_32-apple-watchos10.4"),
        ]
        for sdk_name, target in configurations:
            sdk = run(["xcrun", "--sdk", sdk_name, "--show-sdk-path"]).stdout.strip()
            for debug in [0, 1]:
                run(["xcrun", "clang", "-fobjc-arc", "-fblocks", "-fsyntax-only", "-Werror", "-Wall", "-Wextra",
                     "-Wno-unused-parameter", "-isysroot", sdk, "-target", target, f"-DDEBUG={debug}", *implementations])
                checks.append(f"compile:{sdk_name}:DEBUG={debug}")
            run(["xcrun", "swiftc", "-typecheck", "-swift-version", "6", "-strict-concurrency=complete",
                 "-sdk", sdk, "-target", target, "-I", str(out),
                 "-module-cache-path", str(out / "modules"), str(swift)])
            checks.append(f"swift-import:{sdk_name}")
        # Release device objects must not carry debug monitor implementation or CallKit references.
        device_sdk = run(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"]).stdout.strip()
        for filename in ["VSProviderMonitorInternal.m", "VSProviderCreationMonitor.m"]:
            obj = out / f"{filename}.o"
            run(["xcrun", "clang", "-c", "-fobjc-arc", "-fblocks", "-DDEBUG=0", "-isysroot", device_sdk,
                 "-target", "arm64-apple-ios17.4", str(PLATFORM / filename), "-o", str(obj)])
            symbols = run(["xcrun", "nm", str(obj)]).stdout
            if any(marker in symbols for marker in ["CXProvider", "observedInitialize", "observedAllocate", "VSProviderMonitorInstall", "method_setImplementation"]):
                raise RuntimeError(f"Release object contains debug implementation: {filename}")
            checks.append(f"release-symbols:{filename}")
    print(json.dumps({"success": True, "checks": checks, "count": len(checks)}, indent=2))


if __name__ == "__main__":
    main()
