#!/usr/bin/env python3
"""Host delivery races and compiler-only API checks; no app or PushKit run."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PLATFORM = ROOT / 'Sources/VoIPPlatform'

HOST = r'''
#import <Foundation/Foundation.h>
#import <stdatomic.h>
#import "include/VSPushDelivery.h"
#import "VSCompletionOnce.h"

@interface VSPushDelivery (HostControl)
- (instancetype)initWithCompletion:(dispatch_block_t)completion retaining:(id)receiver
                 completionTimeout:(NSTimeInterval)timeout;
- (BOOL)waitForSettlement:(NSTimeInterval)timeout;
@end

static atomic_uint completed, destroyed;
static atomic_bool mainRan;
static dispatch_semaphore_t receiverReleased;
static char callbackKey;
static void require(BOOL value, const char *reason) {
  if (!value) { fprintf(stderr, "%s\n", reason); exit(1); }
}
@interface FixtureReceiver : NSObject @end
@implementation FixtureReceiver
- (void)dealloc {
  atomic_fetch_add(&destroyed, 1);
  dispatch_semaphore_signal(receiverReleased);
}
@end

static void passed(void) { puts("passed"); exit(0); }
static void independentCompletion(void) {
  require(!NSThread.isMainThread, "system completion must not use main");
  require(!dispatch_get_specific(&callbackKey), "completion must not use the blocked callback queue");
  require(atomic_fetch_add(&completed, 1) == 0, "system completion must run exactly once");
}
static void verifyReleased(void) {
  require(atomic_load(&completed) == 1, "completion must run before verification");
  require(atomic_load(&destroyed) == 1, "ticket must release receiver after actual completion");
  passed();
}
static dispatch_time_t deadline(NSTimeInterval seconds) {
  return dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC));
}
int main(int argc, const char **argv) {
  @autoreleasepool {
    require(argc == 2, "one host control is required");
    receiverReleased = dispatch_semaphore_create(0);
    NSString *mode = @(argv[1]);
    dispatch_queue_t callback = dispatch_queue_create("fixture.pushkit", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(callback, &callbackKey, &callbackKey, NULL);
    if ([mode isEqual:@"legacy-main-once"]) {
      FixtureReceiver *receiver = [FixtureReceiver new];
      __weak FixtureReceiver *weakReceiver = receiver;
      VSCompletionOnce *once = [[VSCompletionOnce alloc] initWithCompletion:^{
        require(NSThread.isMainThread, "legacy completion must remain on main");
        require(weakReceiver != nil, "legacy receiver must survive actual completion");
        require(atomic_fetch_add(&completed, 1) == 0, "legacy completion must run once");
        dispatch_async(dispatch_get_main_queue(), ^{ verifyReleased(); });
      } retaining:receiver];
      receiver = nil;
      dispatch_async(callback, ^{ [once finish]; [once finish]; });
    } else if ([mode isEqual:@"main-wait-refused"]) {
      FixtureReceiver *receiver = [FixtureReceiver new];
      __weak FixtureReceiver *weakReceiver = receiver;
      VSPushDelivery *delivery = [[VSPushDelivery alloc] initWithCompletion:^{
        independentCompletion();
        require(weakReceiver != nil, "receiver must survive completion");
      } retaining:receiver completionTimeout:0.3];
      receiver = nil;
      // Exceed the host process guard: entering the semaphore wait must fail
      // the control, without imposing a scheduler-dependent refusal latency.
      require(![delivery waitForSettlement:120], "main wait must refuse without blocking");
      [delivery finish];
      dispatch_after(deadline(0.08), callback, ^{ verifyReleased(); });
    } else {
      dispatch_async(callback, ^{
        @autoreleasepool {
          FixtureReceiver *receiver = [FixtureReceiver new];
          __weak FixtureReceiver *weakReceiver = receiver;
          __block VSPushDelivery *delivery;
          NSTimeInterval watchdog = ([mode isEqual:@"watchdog"] || [mode isEqual:@"late-finish"] ||
                                     [mode isEqual:@"watchdog-race"]) ? 0.06 : 0.4;
          delivery = [[VSPushDelivery alloc] initWithCompletion:^{
            independentCompletion();
            require(weakReceiver != nil, "receiver must survive actual completion");
            if ([mode isEqual:@"late-finish"]) {
              [NSThread sleepForTimeInterval:0.2];
              require(weakReceiver != nil, "receiver must survive a slow completion");
            }
            if ([mode isEqual:@"completion-reentrancy"]) {
              [delivery finish];
              require([delivery waitForSettlement:0.01], "completion may reenter ticket without a held lock");
            }
          } retaining:receiver completionTimeout:watchdog];
          receiver = nil;
          require(weakReceiver != nil, "pending ticket must retain the receiver");
          if ([mode isEqual:@"normal"]) {
            dispatch_after(deadline(0.02), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ [delivery finish]; });
            require([delivery waitForSettlement:0.2], "settled report must acknowledge callback wait");
          } else if ([mode isEqual:@"callback-timeout"]) {
            require(![delivery waitForSettlement:0.02], "unsettled report must not acknowledge");
            require(atomic_load(&completed) == 0 && weakReceiver != nil,
                    "callback wait expiry must not complete or release pending work");
            [delivery finish];
          } else if ([mode isEqual:@"watchdog"]) {
            require(![delivery waitForSettlement:0.02], "callback wait must expire before watchdog");
            // Keep this callback queue blocked beyond the watchdog deadline.
            require(dispatch_semaphore_wait(receiverReleased, deadline(2)) == 0,
                    "watchdog must release the receiver while callback queue is blocked");
            require(atomic_load(&completed) == 1, "watchdog completion must run while callback queue is blocked");
            require(![delivery waitForSettlement:0.01], "watchdog completion must never fabricate a settlement ACK");
          } else if ([mode isEqual:@"late-finish"]) {
            require(![delivery waitForSettlement:0.02], "callback wait must expire before late settlement");
            require(dispatch_semaphore_wait(receiverReleased, deadline(2)) == 0,
                    "watchdog must release the receiver before late finish");
            require(atomic_load(&completed) == 1 && weakReceiver == nil,
                    "watchdog must complete and release receiver before late finish");
            [delivery finish]; [delivery finish];
            require([delivery waitForSettlement:0.01], "late actual settlement must be recorded without recompleting");
          } else if ([mode isEqual:@"double-finish"] || [mode isEqual:@"watchdog-race"]) {
            dispatch_time_t when = deadline([mode isEqual:@"watchdog-race"] ? 0.06 : 0.01);
            for (NSUInteger i = 0; i < 250; i++)
              dispatch_after(when, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ [delivery finish]; });
            require([delivery waitForSettlement:0.3], "concurrent finishes must acknowledge actual settlement");
          } else if ([mode isEqual:@"main-free"]) {
            dispatch_async(dispatch_get_main_queue(), ^{
              require(NSThread.isMainThread, "main proof must execute on main");
              atomic_store(&mainRan, true);
              [delivery finish];
            });
            require([delivery waitForSettlement:0.2] && atomic_load(&mainRan),
                    "main must remain able to settle while background callback waits");
          } else if ([mode isEqual:@"completion-reentrancy"]) {
            [delivery finish];
            require([delivery waitForSettlement:0.1], "synchronous finish must be acknowledged");
          } else { require(NO, "unknown host control"); }
          dispatch_after(deadline(0.12), callback, ^{
            [delivery finish];
            verifyReleased();
          });
        }
      });
    }
    [[NSRunLoop mainRunLoop] run];
  }
  return 1;
}
'''

SWIFT = '''
import Foundation
import VoIPPlatform
@MainActor final class Receiver: NSObject, PushReceiver {
  func pushTokenDidUpdate(_ token: Data) {}
  func pushTokenDidInvalidate() {}
  nonisolated func receiveVoIPPush(_ payload: [AnyHashable: Any], mustReport: Bool,
                                   delivery: PushDelivery) {
    Task.detached { delivery.finish() }
  }
}
func requireSendable<T: Sendable>(_ value: T) {}
func receiveOffMain(_ receiver: any PushReceiver, delivery: PushDelivery) {
  requireSendable(delivery)
  receiver.receiveVoIPPush([:], mustReport: true, delivery: delivery)
  Task.detached { delivery.finish() }
}
@MainActor func lifecycle() throws {
  let owner = try PushRegistryOwner.shared(receiver: Receiver())
  try owner.start()
}
'''


def run(command, expected_success=True):
    result = subprocess.run(command, text=True, capture_output=True, timeout=60)
    if expected_success is not None and (result.returncode == 0) != expected_success:
        raise RuntimeError(result.stdout + result.stderr)
    return result


def main():
    checks = []
    with tempfile.TemporaryDirectory(prefix='ios-voip-delivery-') as temporary:
        out = Path(temporary)
        host = out / 'host.m'
        host.write_text(HOST)
        binary = out / 'host'
        run(['xcrun', 'clang', '-O2', '-fobjc-arc', '-fblocks', '-Wall', '-Wextra', '-Werror',
             '-Wno-unused-parameter', '-I', str(PLATFORM), str(host), str(PLATFORM / 'VSPushDelivery.m'),
             str(PLATFORM / 'VSCompletionOnce.m'), '-framework', 'Foundation', '-o', str(binary)])
        for case in ('normal', 'callback-timeout', 'watchdog', 'late-finish', 'double-finish',
                     'watchdog-race', 'main-free', 'main-wait-refused', 'completion-reentrancy', 'legacy-main-once'):
            result = run([str(binary), case])
            if result.stdout.strip() != 'passed':
                raise RuntimeError('host control did not acknowledge success: ' + case)
            if case in ('watchdog', 'late-finish'):
                assert 'Push report settlement exceeded the completion watchdog.' in result.stderr
            if case == 'main-wait-refused':
                assert 'Push report settlement must never be awaited on main.' in result.stderr
            checks.append('host:' + case)
        (out / 'module.modulemap').write_text(
            'module VoIPPlatform { umbrella header "' + str(PLATFORM / 'include/VoIPPlatform.h') + '" export * }\n')
        swift = out / 'import.swift'
        swift.write_text(SWIFT)
        negative = out / 'token-off-main.swift'
        negative.write_text('import VoIPPlatform\nfunc wrong(_ receiver: any PushReceiver) { receiver.pushTokenDidInvalidate() }\n')
        for sdk_name, target in (('iphonesimulator', 'arm64-apple-ios26.0-simulator'),
                                 ('watchos', 'arm64_32-apple-watchos10.4')):
            sdk = run(['xcrun', '--sdk', sdk_name, '--show-sdk-path']).stdout.strip()
            implementations = [str(PLATFORM / name) for name in ('VSPushRegistryOwner.m', 'VSPushDelivery.m', 'VSCompletionOnce.m')]
            run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-fsyntax-only', '-Wall', '-Wextra', '-Werror',
                 '-Wno-unused-parameter', '-isysroot', sdk, '-target', target, *implementations])
            checks.append('syntax:' + sdk_name)
            command = ['xcrun', 'swiftc', '-typecheck', '-swift-version', '6', '-strict-concurrency=complete',
                       '-warnings-as-errors', '-sdk', sdk, '-target', target, '-I', str(out),
                       '-module-cache-path', str(out / 'modules')]
            run([*command, str(swift)])
            checks.append('swift-api:' + sdk_name)
            # Clang-imported actor annotations may be compatibility warnings,
            # even in Swift 6; require the isolation diagnostic, not its severity.
            rejected = run([*command, str(negative)], expected_success=None)
            assert 'main actor-isolated' in rejected.stderr
            checks.append('token-main-actor-diagnosed:' + sdk_name)
    sources = [PLATFORM / 'VSPushDelivery.m', PLATFORM / 'include/VSPushDelivery.h',
               PLATFORM / 'VSPushRegistryOwner.m', PLATFORM / 'include/VSPushRegistryOwner.h',
               PLATFORM / 'include/VoIPPlatform.h', Path(__file__)]
    print(json.dumps(dict(success=True, classification='host controls and compiler-only checks; no native PushKit acceptance',
                         count=len(checks), checks=checks,
                         sourceFiles={str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}), indent=2))


if __name__ == '__main__':
    main()
