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
static void (^fixtureCreationObserver)(id);
static BOOL inheritedShape;
static BOOL foreignShape;
static void require(BOOL condition, const char *reason) {
  if (!condition) { fprintf(stderr, "%s\n", reason); exit(1); }
}
@interface VSFixtureProvider : NSObject
@property(nonatomic, strong) id configuration;
- (instancetype)initWithConfiguration:(id)configuration;
@end
@implementation VSFixtureProvider
- (instancetype)initWithConfiguration:(id)configuration {
  if ((self = [super init])) {
    roots++; self.configuration = configuration;
    if (fixtureCreationObserver) fixtureCreationObserver(self);
  }
  return self;
}
- (void)dealloc { destroyed++; }
@end
@interface VSFixtureCluster : VSFixtureProvider @end
@interface VSFixtureConcrete : VSFixtureCluster @end
@interface VSFixtureIndependent : VSFixtureCluster @end
@interface VSFixtureLeaf : VSFixtureIndependent @end
@implementation VSFixtureLeaf @end
@interface VSFixtureForeign : NSObject
@property(nonatomic, strong) id configuration;
- (instancetype)initWithConfiguration:(id)configuration;
@end
@implementation VSFixtureForeign
- (instancetype)initWithConfiguration:(id)configuration {
  if ((self = [super init])) self.configuration = configuration;
  return self;
}
@end
@implementation VSFixtureConcrete
- (instancetype)initWithConfiguration:(id)configuration {
  concretes++;
  return [super initWithConfiguration:configuration];
}
@end
@implementation VSFixtureIndependent
- (instancetype)initWithConfiguration:(id)configuration {
  // A genuine class-cluster initializer need not call the public root's
  // initWithConfiguration:. Its inherited leaf must still be observed.
  if ((self = [super init])) { concretes++; self.configuration = configuration; }
  return self;
}
@end
@implementation VSFixtureCluster
+ (id)allocWithZone:(NSZone *)zone {
  if (self == VSFixtureCluster.class) {
    Class concrete = foreignShape ? VSFixtureForeign.class :
        (inheritedShape ? VSFixtureLeaf.class : VSFixtureConcrete.class);
    return [concrete allocWithZone:zone];
  }
  return [super allocWithZone:zone];
}
@end
@interface VSFixtureNil : VSFixtureProvider @end
@implementation VSFixtureNil
- (instancetype)initWithConfiguration:(id)configuration { return nil; }
@end
@interface VSFixtureReplacement : VSFixtureProvider @end
@implementation VSFixtureReplacement
- (instancetype)initWithConfiguration:(id)configuration {
  self = (id)[[VSFixtureConcrete alloc] initWithConfiguration:configuration];
  return self;
}
@end

// RUNTIME_PROVIDER_SOURCE

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
    if ([mode hasPrefix:@"cooperative"]) {
      IMP initializer = class_getMethodImplementation(VSFixtureProvider.class, @selector(initWithConfiguration:));
      IMP allocator = class_getMethodImplementation(object_getClass(VSFixtureProvider.class), @selector(allocWithZone:));
      BOOL reject = [mode isEqual:@"cooperative-rejected"];
      fixtureCreationObserver = ^(id provider) { observeSDKDebugProviderCreation(provider); };
      BOOL result = VSProviderMonitorInstallWithSource(VSFixtureProvider.class, ^(NSString *m){ diagnostic(m); },
          ^BOOL(void (^observer)(id)) {
            if (reject) return NO;
            require(!CKSimInstallProviderCreationObserver(observer), "inactive runtime must reject observer registration");
            installed = YES;
            return CKSimInstallProviderCreationObserver(observer);
          });
      require(result != reject, "cooperative source registration must report its result");
      require(initializer == class_getMethodImplementation(VSFixtureProvider.class, @selector(initWithConfiguration:)) &&
              allocator == class_getMethodImplementation(object_getClass(VSFixtureProvider.class), @selector(allocWithZone:)) &&
              globalAllocator == class_getMethodImplementation(object_getClass(NSObject.class), @selector(allocWithZone:)),
              "cooperative monitoring must never replace initializer or allocator IMPs");
      if (reject) {
        require(warnings == 1 && !sdkDebugProviderCreationObserver, "rejected source must diagnose without installing hooks");
        puts("passed"); return 0;
      }
      require(VSProviderMonitorInstall(VSFixtureProvider.class, ^(NSString *m){ diagnostic(m); }),
              "ordinary repeated install must preserve the cooperative source");
      VSProviderMonitorBeginOwnedCreation();
      VSFixtureProvider *owned = [[VSFixtureProvider alloc] initWithConfiguration:[NSObject new]];
      observeSDKDebugProviderCreation(owned);
      VSProviderMonitorEndOwnedCreation();
      require(warnings == 0, "owned creation and repeated object observation must not warn");
      if ([mode isEqual:@"cooperative-background"]) {
        VSProviderMonitorBeginOwnedCreation();
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
          created(VSFixtureProvider.class);
          dispatch_async(dispatch_get_main_queue(), ^{
            require(warnings == 1, "background cooperative creation must not consume owned bracket");
            VSProviderMonitorEndOwnedCreation();
            require(warnings == 2, "empty owned bracket must still diagnose");
            puts("passed"); exit(0);
          });
        });
        [[NSRunLoop mainRunLoop] run];
      }
      VSProviderMonitorBeginOwnedCreation();
      created(VSFixtureProvider.class);
      created(VSFixtureProvider.class);
      VSProviderMonitorEndOwnedCreation();
      require(warnings == 1, "second cooperative provider in owned bracket must warn once");
      created(VSFixtureProvider.class);
      require(warnings == 2, "later cooperative provider must warn once");
      puts("passed"); return 0;
    }
    if ([mode isEqual:@"unsupported"]) {
      require(!VSProviderMonitorInstall(NSObject.class, ^(NSString *m){ diagnostic(m); }), "missing initializer must refuse");
      require(warnings == 1, "unsupported ABI must diagnose");
      require(globalAllocator == class_getMethodImplementation(object_getClass(NSObject.class), @selector(allocWithZone:)), "NSObject must remain untouched");
      puts("passed"); return 0;
    }
    inheritedShape = [mode isEqual:@"inherited-cluster"];
    foreignShape = [mode isEqual:@"unrelated-allocation"];
    Class cls = ([mode isEqual:@"cluster"] || inheritedShape || foreignShape) ? VSFixtureCluster.class :
        ([mode isEqual:@"nil"] ? VSFixtureNil.class : VSFixtureProvider.class);
    BOOL replacement = [mode isEqual:@"init-substitution"];
    Class constructClass = replacement ? VSFixtureReplacement.class : cls;
    require(VSProviderMonitorInstall(cls, ^(NSString *m){ diagnostic(m); }), "public hooks must install");
    require(VSProviderMonitorInstall(cls, ^(NSString *m){ diagnostic(m); }), "installation must be idempotent");
    require(globalAllocator == class_getMethodImplementation(object_getClass(NSObject.class), @selector(allocWithZone:)), "NSObject allocator must never be swapped");
    if (foreignShape) {
      IMP foreignInit = class_getMethodImplementation(VSFixtureForeign.class, @selector(initWithConfiguration:));
      VSProviderMonitorBeginOwnedCreation();
      created(cls);
      VSProviderMonitorEndOwnedCreation();
      require(warnings == 2, "unrelated allocation must diagnose unsupported coverage");
      require(foreignInit == class_getMethodImplementation(VSFixtureForeign.class, @selector(initWithConfiguration:)), "unrelated class methods must not be changed");
      require(globalAllocator == class_getMethodImplementation(object_getClass(NSObject.class), @selector(allocWithZone:)), "NSObject must remain untouched");
      puts("passed"); return 0;
    }
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
    created(constructClass);
    if ([mode isEqual:@"extra-owned"]) {
      created(constructClass);
      require(warnings == 1, "second provider inside the bracket must warn");
      VSProviderMonitorEndOwnedCreation();
    } else {
      VSProviderMonitorEndOwnedCreation();
      require(warnings == 0, "one owned provider must not warn");
      created(constructClass);
      require(warnings == 1, "later provider must warn exactly once");
    }
    require(roots == (inheritedShape ? 0 : 2) && destroyed == (replacement ? 4 : 2), "initializer and ARC ownership must remain balanced");
    if ([mode isEqual:@"cluster"] || inheritedShape) require(concretes == 2, "concrete/super initializer chain must run once");
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
        runtime = (ROOT / 'Sources/Interposition/CKInterposition.m').read_text()
        start = runtime.index('#if CKSIM_SDK_SOURCE && DEBUG\n')
        end = runtime.index('#endif', start)
        # Execute the actual runtime registration/notification helpers against
        # the host fixture; no Apple call service or simulator is involved.
        helper = runtime[start + len('#if CKSIM_SDK_SOURCE && DEBUG\n'):end]
        host.write_text(HOST.replace('// RUNTIME_PROVIDER_SOURCE',
            '#define CXProvider VSFixtureProvider\nstatic BOOL installed;\n' + helper + '\n#undef CXProvider'))
        binary = out / "platform-controls"
        run(["xcrun", "clang", "-fobjc-arc", "-fblocks", "-DDEBUG=1", "-Wall", "-Wextra",
             "-Werror", "-Wno-unused-parameter", "-I", str(PLATFORM), str(host),
             str(PLATFORM / "VSCompletionOnce.m"), str(PLATFORM / "VSProviderMonitorInternal.m"),
             "-framework", "Foundation", "-o", str(binary)])
        for case in ["completion-race", "plain", "cluster", "inherited-cluster", "init-substitution", "extra-owned", "background", "nil", "unsupported", "unrelated-allocation",
                     "cooperative", "cooperative-background", "cooperative-rejected"]:
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
        # The cooperative seam has no observer storage, notifier or registration
        # implementation in Release simulator or Debug device runtime objects.
        simulator_sdk = run(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"]).stdout.strip()
        version = (ROOT / 'VERSION').read_text().strip()
        for name, sdk, target, debug in [
                ('release-simulator', simulator_sdk, 'arm64-apple-ios17.4-simulator', 0),
                ('debug-device', device_sdk, 'arm64-apple-ios17.4', 1)]:
            obj = out / (name + '.o')
            run(['xcrun', 'clang', '-c', '-fobjc-arc', '-fblocks', '-fmodules', f'-DDEBUG={debug}',
                 '-DCKSIM_SDK_SOURCE=1', f'-DCKSIM_RUNTIME_VERSION="{version}"', '-isysroot', sdk,
                 '-target', target, str(ROOT / 'Sources/Interposition/CKInterposition.m'), '-o', str(obj)])
            symbols = run(['xcrun', 'nm', str(obj)]).stdout
            if any(marker in symbols for marker in ['CKSimInstallProviderCreationObserver',
                    'sdkDebugProviderCreationObserver', 'observeSDKDebugProviderCreation']):
                raise RuntimeError('Debug simulator observer leaked into ' + name)
            checks.append('observer-excluded:' + name)
    print(json.dumps({"success": True, "checks": checks, "count": len(checks)}, indent=2))


if __name__ == "__main__":
    main()
