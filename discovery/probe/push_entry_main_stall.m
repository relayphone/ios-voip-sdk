#import "push_entry_main_stall.h"
#import "../../Sources/Interposition/CKRuntimeSeam.h"

#if TARGET_OS_IOS && TARGET_OS_SIMULATOR
#import <PushKit/PushKit.h>
#import <stdatomic.h>

// The implementation is the SDK's exact linked method, not a copied facade.
// Both PushKit delegate overloads call this method in production.
@interface VSPushRegistryOwner (MainStallProbe)
- (void)deliverPayload:(PKPushPayload *)payload mustReport:(BOOL)mustReport
           completion:(dispatch_block_t)completion;
@end

@interface CKProbeMainStallPayload : PKPushPayload
@property(nonatomic, copy) NSDictionary *contents;
@end
@implementation CKProbeMainStallPayload
- (PKPushType)type { return PKPushTypeVoIP; }
- (NSDictionary *)dictionaryPayload { return self.contents; }
@end

static atomic_int completionCount;
static atomic_bool callbackReturned;
static NSString *ownerIdentity;

NSString *CKProbeMainStallOwnerIdentity(void) { return ownerIdentity ?: @""; }
NSInteger CKProbeMainStallCompletionCount(void) { return atomic_load(&completionCount); }
BOOL CKProbeMainStallCallbackReturned(void) { return atomic_load(&callbackReturned); }

void CKProbeRunIncomingMainStall(VSPushRegistryOwner *owner, NSDictionary *payload) {
  NSCAssert(NSThread.isMainThread, @"The fixture must hold the actual main thread.");
  NSCAssert(owner && owner.isStarted, @"The fixture requires the existing started SDK registry owner.");
  atomic_store(&completionCount, 0);
  atomic_store(&callbackReturned, false);
  ownerIdentity = [NSString stringWithFormat:@"%p", (__bridge void *)owner];
  NSString *identity = ownerIdentity;
  NSString *runID = NSProcessInfo.processInfo.environment[@"CKSIM_RUN_ID"] ?: @"";
  NSString *fixtureID = [runID stringByAppendingString:@"-native-main-stall"];
  CKProbeMainStallPayload *value = [CKProbeMainStallPayload new];
  value.contents = payload;
  dispatch_semaphore_t start = dispatch_semaphore_create(0);
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    if (dispatch_semaphore_wait(start, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC))) return;
    CKSimEmit(@"fixture.nativeCallbackBegin", @{@"owner":identity, @"fixtureID":fixtureID,
        @"main":@(NSThread.isMainThread)});
    [owner deliverPayload:value mustReport:YES completion:^{
      int ordinal = atomic_fetch_add(&completionCount, 1) + 1;
      CKSimEmit(@"fixture.nativeCompletion", @{@"owner":identity, @"fixtureID":fixtureID,
          @"ordinal":@(ordinal), @"main":@(NSThread.isMainThread)});
    }];
    atomic_store(&callbackReturned, true);
    CKSimEmit(@"fixture.nativeCallbackReturned", @{@"owner":identity, @"fixtureID":fixtureID,
        @"main":@(NSThread.isMainThread)});
  });
  NSTimeInterval began = NSProcessInfo.processInfo.systemUptime;
  CKSimEmit(@"fixture.mainStallBegan", @{@"owner":identity, @"fixtureID":fixtureID,
      @"seconds":@3.0, @"main":@(NSThread.isMainThread)});
  dispatch_semaphore_signal(start);
  [NSThread sleepForTimeInterval:3.0];
  CKSimEmit(@"fixture.mainStallEnded", @{@"owner":identity, @"fixtureID":fixtureID,
      @"elapsedSeconds":@(NSProcessInfo.processInfo.systemUptime - began), @"main":@(NSThread.isMainThread)});
}
#endif
