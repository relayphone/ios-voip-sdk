#import <UIKit/UIKit.h>
#import <CallKit/CallKit.h>
#import <PushKit/PushKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

static NSUInteger genuineReports;
static NSUInteger genuineOperations;
static IMP originalSetValue;
static NSString *scenario;
static BOOL failed;
static NSTimeInterval started;
static char refusedQueueKey;
static NSUInteger providerInitializations, controllerInitializations, pushSetterCalls;
static IMP savedProviderInitializer, savedControllerInitializer;
typedef id (*ObjectInitializer)(id __attribute__((ns_consumed)), SEL, id) __attribute__((ns_returns_retained));
typedef id (*QueueInitializer)(id __attribute__((ns_consumed)), SEL, dispatch_queue_t) __attribute__((ns_returns_retained));
__attribute__((ns_returns_retained)) static id countedProviderInit(id __attribute__((ns_consumed)) self, SEL selector, id configuration) {
  providerInitializations++;
  return ((ObjectInitializer)savedProviderInitializer)(self, selector, configuration);
}
__attribute__((ns_returns_retained)) static id countedControllerInit(id __attribute__((ns_consumed)) self, SEL selector, dispatch_queue_t queue) {
  controllerInitializations++;
  return ((QueueInitializer)savedControllerInitializer)(self, selector, queue);
}
@interface ABIPushDelegateRegistry : PKPushRegistry @end
@implementation ABIPushDelegateRegistry
- (void)setDelegate:(id<PKPushRegistryDelegate>)delegate { pushSetterCalls++; }
@end
@interface ABIPushTypesRegistry : PKPushRegistry @end
@implementation ABIPushTypesRegistry
- (void)setDesiredPushTypes:(NSSet<PKPushType> *)types { pushSetterCalls++; }
@end
static void trace(NSString *event, NSDictionary *fields) {
  NSMutableDictionary *row = fields.mutableCopy;
  row[@"event"] = event;
  row[@"t_ms"] = @((long long)((NSProcessInfo.processInfo.systemUptime - started) * 1000));
  row[@"runID"] = NSProcessInfo.processInfo.environment[@"CKSIM_RUN_ID"] ?: @"";
  row[@"bundleID"] = NSBundle.mainBundle.bundleIdentifier;
  row[@"main"] = @(NSThread.isMainThread);
  row[@"pid"] = @(getpid());
  row[@"case"] = scenario;
  NSData *data = [NSJSONSerialization dataWithJSONObject:row options:NSJSONWritingSortedKeys error:nil];
  fprintf(stderr, "PROBE %s\n", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
}
static void check(BOOL condition, NSString *label) {
  trace(@"abi.check", @{@"label":label, @"passed":@(condition)});
  failed |= !condition;
}
static void genuineIncoming(id self, SEL selector, NSUUID *uuid, CXCallUpdate *update, void (^completion)(NSError *)) {
  genuineReports++;
  completion([NSError errorWithDomain:@"ABIProbeGenuineReport" code:999 userInfo:nil]);
}
static void genuineVoid(id self, SEL selector) { genuineOperations++; }
static void genuineDelegate(id self, SEL selector, id delegate, dispatch_queue_t queue) { genuineOperations++; }
static void genuineTwoObjects(id self, SEL selector, id first, id second) { genuineOperations++; }
static void genuineEnded(id self, SEL selector, id uuid, id date, CXCallEndedReason reason) { genuineOperations++; }
static id genuineArray(id self, SEL selector) { genuineOperations++; return @[]; }
static id genuinePending(id self, SEL selector, Class cls, NSUUID *uuid) { genuineOperations++; return @[]; }
static void genuineRequest(id self, SEL selector, id input, void (^completion)(NSError *)) {
  genuineOperations++;
  completion([NSError errorWithDomain:@"ABIProbeGenuineRequest" code:999 userInfo:nil]);
}
static void override(Class cls, SEL selector, IMP implementation) {
  Method method = class_getInstanceMethod(cls, selector);
  class_replaceMethod(cls, selector, implementation, method_getTypeEncoding(method));
}
static void faultySetValue(id self, SEL selector, id value, NSString *key) {
  NSString *ignoredKey = [scenario hasPrefix:@"kvc-ignored-"] ? [scenario substringFromIndex:@"kvc-ignored-".length] : nil;
  if ([key isEqual:@"hasConnected"]) {
    if ([scenario isEqual:@"kvc-exception"]) [NSException raise:NSUndefinedKeyException format:@"ABI probe renamed snapshot key"];
  }
  if ([key isEqual:ignoredKey]) return;
  ((void (*)(id, SEL, id, id))originalSetValue)(self, selector, value, key);
}

// A leaf override, an intermediate override, and an inheriting sibling expose
// duplicate or skipped original dispatch when a saved implementation calls super.
static NSMutableArray<NSString *> *actionOrder;
@interface ABIMiddleAction : CXAction @end
@implementation ABIMiddleAction
- (void)fulfill { [actionOrder addObject:@"middle.fulfill"]; [super fulfill]; }
- (void)fail { [actionOrder addObject:@"middle.fail"]; [super fail]; }
- (NSDate *)timeoutDate { [actionOrder addObject:@"middle.deadline"]; return [super timeoutDate]; }
@end
@interface ABILeafAction : ABIMiddleAction @end
@implementation ABILeafAction
- (void)fulfill { [actionOrder addObject:@"leaf.fulfill"]; [super fulfill]; }
- (void)fail { [actionOrder addObject:@"leaf.fail"]; [super fail]; }
- (NSDate *)timeoutDate { [actionOrder addObject:@"leaf.deadline"]; return [super timeoutDate]; }
@end
@interface ABISiblingAction : ABIMiddleAction @end
@implementation ABISiblingAction @end

static NSArray<NSNumber *> *datedFulfillmentState(void) {
  NSUUID *uuid = NSUUID.UUID;
  CXStartCallAction *start = [[CXStartCallAction alloc] initWithCallUUID:uuid handle:[[CXHandle alloc] initWithType:CXHandleTypeGeneric value:@"ABI standalone"]];
  CXAnswerCallAction *answer = [[CXAnswerCallAction alloc] initWithCallUUID:uuid];
  CXEndCallAction *end = [[CXEndCallAction alloc] initWithCallUUID:uuid];
  [start fulfillWithDateStarted:NSDate.date];
  [answer fulfillWithDateConnected:NSDate.date];
  [end fulfillWithDateEnded:NSDate.date];
  return @[@(start.isComplete), @(answer.isComplete), @(end.isComplete)];
}

@interface ABIProbeScene : UIResponder <UIWindowSceneDelegate>
@property(nonatomic) UIWindow *window;
@end
static dispatch_block_t runWhenSceneActive;
@implementation ABIProbeScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
  self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
  self.window.rootViewController = [UIViewController new];
  [self.window makeKeyAndVisible];
}
- (void)sceneDidBecomeActive:(UIScene *)scene {
  if (!runWhenSceneActive) return;
  dispatch_block_t run = runWhenSceneActive;
  runWhenSceneActive = nil;
  trace(@"abi.sceneActive", @{});
  dispatch_async(dispatch_get_main_queue(), run);
}
@end

@interface ABIProbe : UIResponder <UIApplicationDelegate, CXProviderDelegate>
@property(nonatomic) UIWindow *window;
@property(nonatomic) CXProvider *provider;
@property(nonatomic) CXCallController *controller;
@property(nonatomic) CXCallObserver *observer;
@end
@implementation ABIProbe
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
  started = NSProcessInfo.processInfo.systemUptime;
  scenario = NSProcessInfo.processInfo.environment[@"CKSIM_ABI_CASE"];
  trace(@"app.entry", @{});
  trace(@"launch", @{});
  // Complete UIKit launch before this deliberately short scenario can finish.
  // The supervisor still obtains the launcher's PID after owned termination.
  runWhenSceneActive = ^{ [self run]; };
  return YES;
}
- (void)checkRefusedQueues:(dispatch_block_t)done {
  dispatch_queue_t queue = dispatch_queue_create("dev.callkitsim.abi.refused", DISPATCH_QUEUE_SERIAL);
  dispatch_queue_set_specific(queue, &refusedQueueKey, &refusedQueueKey, NULL);
  CXProvider *custom = [[CXProvider alloc] initWithConfiguration:[CXProviderConfiguration new]];
  [custom setDelegate:nil queue:queue];
  [custom reportNewIncomingCallWithUUID:NSUUID.UUID update:[CXCallUpdate new] completion:^(NSError *error) {
    check([error.domain isEqual:@"CKSimRuntimeErrorDomain"] && dispatch_get_specific(&refusedQueueKey) == &refusedQueueKey, @"refused-incoming-custom-queue");
    CXProvider *main = [[CXProvider alloc] initWithConfiguration:[CXProviderConfiguration new]];
    [main setDelegate:nil queue:nil];
    [main reportNewIncomingCallWithUUID:NSUUID.UUID update:[CXCallUpdate new] completion:^(NSError *error) {
      check([error.domain isEqual:@"CKSimRuntimeErrorDomain"] && NSThread.isMainThread, @"refused-incoming-main-queue");
      CXCallController *controller = [[CXCallController alloc] initWithQueue:queue];
      CXAction *action = [[CXAnswerCallAction alloc] initWithCallUUID:NSUUID.UUID];
      [controller requestTransactionWithAction:action completion:^(NSError *error) {
        check([error.domain isEqual:@"CKSimRuntimeErrorDomain"] && dispatch_get_specific(&refusedQueueKey) == &refusedQueueKey, @"refused-request-action-queue");
        [controller requestTransaction:[[CXTransaction alloc] initWithAction:action] completion:^(NSError *error) {
          check([error.domain isEqual:@"CKSimRuntimeErrorDomain"] && dispatch_get_specific(&refusedQueueKey) == &refusedQueueKey, @"refused-request-transaction-queue");
          [controller requestTransactionWithActions:@[action] completion:^(NSError *error) {
            check([error.domain isEqual:@"CKSimRuntimeErrorDomain"] && dispatch_get_specific(&refusedQueueKey) == &refusedQueueKey, @"refused-request-actions-queue");
            done();
          }];
        }];
      }];
    }];
  }];
}
- (void)run {
  actionOrder = [NSMutableArray new];
  CXAction *reference = [ABILeafAction new];
  [actionOrder removeAllObjects];
  [reference fulfill];
  NSArray *fulfillOrder = actionOrder.copy;
  BOOL fulfillComplete = reference.isComplete;
  reference = [ABILeafAction new];
  [actionOrder removeAllObjects];
  [reference fail];
  NSArray *failOrder = actionOrder.copy;
  BOOL failComplete = reference.isComplete;
  reference = [ABILeafAction new];
  [actionOrder removeAllObjects];
  BOOL hasDeadline = reference.timeoutDate != nil;
  NSArray *deadlineOrder = actionOrder.copy;
  NSArray *datedState = datedFulfillmentState();
  trace(@"abi.originalReference", @{@"fulfillOrder":fulfillOrder, @"failOrder":failOrder, @"deadlineOrder":deadlineOrder,
    @"fulfillComplete":@(fulfillComplete), @"failComplete":@(failComplete), @"hasDeadline":@(hasDeadline), @"datedState":datedState});
  check([fulfillOrder isEqual:@[@"leaf.fulfill", @"middle.fulfill"]] && [failOrder isEqual:@[@"leaf.fail", @"middle.fail"]] &&
    [deadlineOrder isEqual:@[@"leaf.deadline", @"middle.deadline"]], @"original-reference-chain");
  // Touch the genuine class cluster before loading the runtime. The sentinel
  // proves that neither concrete overrides nor refusal reach genuine reports.
  CXProvider *sample = [[CXProvider alloc] initWithConfiguration:[CXProviderConfiguration new]];
  Class concrete = object_getClass(sample);
  savedProviderInitializer = class_getMethodImplementation(concrete, @selector(initWithConfiguration:));
  override(concrete, @selector(initWithConfiguration:), (IMP)countedProviderInit);
  SEL incoming = @selector(reportNewIncomingCallWithUUID:update:completion:);
  override(concrete, incoming, (IMP)genuineIncoming);
  override(concrete, @selector(setDelegate:queue:), (IMP)genuineDelegate);
  override(concrete, @selector(reportCallWithUUID:updated:), (IMP)genuineTwoObjects);
  override(concrete, @selector(reportCallWithUUID:endedAtDate:reason:), (IMP)genuineEnded);
  override(concrete, @selector(reportOutgoingCallWithUUID:startedConnectingAtDate:), (IMP)genuineTwoObjects);
  override(concrete, @selector(reportOutgoingCallWithUUID:connectedAtDate:), (IMP)genuineTwoObjects);
  override(concrete, @selector(pendingTransactions), (IMP)genuineArray);
  override(concrete, @selector(pendingCallActionsOfClass:withCallUUID:), (IMP)genuinePending);
  override(concrete, @selector(invalidate), (IMP)genuineVoid);
  Class controller = object_getClass([CXCallController new]);
  savedControllerInitializer = class_getMethodImplementation(controller, @selector(initWithQueue:));
  override(controller, @selector(initWithQueue:), (IMP)countedControllerInit);
  override(controller, @selector(requestTransaction:completion:), (IMP)genuineRequest);
  override(controller, @selector(requestTransactionWithAction:completion:), (IMP)genuineRequest);
  override(controller, @selector(requestTransactionWithActions:completion:), (IMP)genuineRequest);
  Class observer = object_getClass([CXCallObserver new]);
  override(observer, @selector(calls), (IMP)genuineArray);
  override(observer, @selector(setDelegate:queue:), (IMP)genuineDelegate);
  if ([scenario hasPrefix:@"kvc-"]) {
    Method setter = class_getInstanceMethod(CXCall.class, @selector(setValue:forKey:));
    originalSetValue = method_getImplementation(setter);
    class_replaceMethod(CXCall.class, @selector(setValue:forKey:), (IMP)faultySetValue, method_getTypeEncoding(setter));
  }
  void *runtime = dlopen([NSProcessInfo.processInfo.environment[@"CKSIM_RUNTIME_PATH"] fileSystemRepresentation], RTLD_NOW | RTLD_GLOBAL);
  check(runtime != NULL, @"runtime-loads");
  BOOL (*active)(void) = runtime ? dlsym(runtime, "CKSimRuntimeIsActive") : NULL;
  BOOL refusal = ![scenario isEqual:@"concrete-override"];
  check(active && active() == !refusal, @"activation-result");
  genuineOperations = 0; // Preflight may dispose its genuine sample provider.
  providerInitializations = controllerInitializations = 0;
  @autoreleasepool {
    CXProviderConfiguration *configuration = [CXProviderConfiguration new];
    configuration.maximumCallsPerCallGroup = 3;
    self.provider = [[CXProvider alloc] initWithConfiguration:configuration];
    self.controller = [CXCallController new];
    self.observer = [CXCallObserver new];
  } // Initializer results must remain owned after temporary autoreleases drain.
  check(self.provider != nil && self.controller != nil, @"nonnull-initializers");
  if ([scenario hasPrefix:@"missing-"] && ![scenario isEqual:@"missing-selector"]) {
    check(providerInitializations == 1 && controllerInitializations == 1 && self.provider.configuration.maximumCallsPerCallGroup == 3 && self.controller.callObserver != nil,
      @"genuine-initializer-state");
  }
  if ([scenario hasPrefix:@"push-"]) {
    PKPushRegistry *registry = [[NSClassFromString([scenario isEqual:@"push-delegate-override"] ? @"ABIPushDelegateRegistry" : @"ABIPushTypesRegistry") alloc] initWithQueue:dispatch_get_main_queue()];
    pushSetterCalls = 0;
    if ([scenario isEqual:@"push-delegate-override"]) registry.delegate = nil; else registry.desiredPushTypes = [NSSet setWithObject:PKPushTypeVoIP];
    check(pushSetterCalls == 1, @"push-concrete-original-preserved");
  }
  CXAction *standalone = [ABILeafAction new];
  [actionOrder removeAllObjects];
  [standalone fulfill];
  check(refusal ? !standalone.isComplete && actionOrder.count == 0 : standalone.isComplete == fulfillComplete && [actionOrder isEqual:fulfillOrder], @"original-fulfill-chain");
  standalone = [ABILeafAction new];
  [actionOrder removeAllObjects];
  [standalone fail];
  check(refusal ? !standalone.isComplete && actionOrder.count == 0 : standalone.isComplete == failComplete && [actionOrder isEqual:failOrder], @"original-fail-chain");
  standalone = [ABILeafAction new];
  [actionOrder removeAllObjects];
  NSDate *timeout = standalone.timeoutDate;
  check(refusal ? [timeout isKindOfClass:NSDate.class] && actionOrder.count == 0 : (timeout != nil) == hasDeadline && [actionOrder isEqual:deadlineOrder], @"original-deadline-chain");
  check([datedFulfillmentState() isEqual:refusal ? @[@NO, @NO, @NO] : datedState], @"original-dated-fulfill");
  [self.provider setDelegate:self queue:nil];
  [self.observer setDelegate:nil queue:nil];
  NSUUID *uuid = NSUUID.UUID;
  [self.provider reportNewIncomingCallWithUUID:uuid update:[CXCallUpdate new] completion:^(NSError *error) {
    check(refusal ? [error.domain isEqual:@"CKSimRuntimeErrorDomain"] : error == nil, @"incoming-result");
    NSString *detail = [scenario isEqual:@"shadow-concrete-override"] ? @"setDelegate:queue:" : (([scenario isEqual:@"missing-selector"] || [scenario isEqual:@"refused-queues"]) ? @"pendingTransactions" :
      ([scenario hasPrefix:@"kvc-ignored-"] ? [scenario substringFromIndex:@"kvc-ignored-".length] : @"hasConnected"));
    if ([scenario isEqual:@"missing-provider-init"]) detail = @"initWithConfiguration:";
    if ([scenario isEqual:@"missing-controller-init"]) detail = @"initWithQueue:";
    if ([scenario isEqual:@"push-delegate-override"]) detail = @"setDelegate:";
    if ([scenario isEqual:@"push-types-override"]) detail = @"setDesiredPushTypes:";
    check(!refusal || [error.localizedDescription containsString:detail], @"diagnostic-identifies-abi");
    check(genuineReports == 0, @"no-genuine-report");
    check(refusal ? self.observer.calls.count == 0 : self.observer.calls.count == 1, @"snapshot-result");
    CXAnswerCallAction *action = [[CXAnswerCallAction alloc] initWithCallUUID:uuid];
    [self.controller requestTransactionWithAction:action completion:^(NSError *requestError) {
      check(refusal ? [requestError.domain isEqual:@"CKSimRuntimeErrorDomain"] : requestError == nil, @"transaction-result");
      CXSetHeldCallAction *hold = [[CXSetHeldCallAction alloc] initWithCallUUID:uuid onHold:YES];
      [self.controller requestTransaction:[[CXTransaction alloc] initWithAction:hold] completion:^(NSError *directError) {
        check(refusal ? [directError.domain isEqual:@"CKSimRuntimeErrorDomain"] : directError == nil, @"transaction-direct-result");
        CXSetHeldCallAction *unhold = [[CXSetHeldCallAction alloc] initWithCallUUID:uuid onHold:NO];
        [self.controller requestTransactionWithActions:@[unhold] completion:^(NSError *arrayError) {
          check(refusal ? [arrayError.domain isEqual:@"CKSimRuntimeErrorDomain"] : arrayError == nil, @"transaction-array-result");
          dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            check(genuineReports == 0, @"no-genuine-report-after-request");
            check(refusal ? self.provider.pendingTransactions.count == 0 : self.observer.calls.firstObject.hasConnected, @"final-state");
            [self.provider pendingCallActionsOfClass:CXAnswerCallAction.class withCallUUID:uuid];
            [self.provider reportCallWithUUID:uuid updated:[CXCallUpdate new]];
            [self.provider reportOutgoingCallWithUUID:uuid startedConnectingAtDate:nil];
            [self.provider reportOutgoingCallWithUUID:uuid connectedAtDate:nil];
            [self.provider reportCallWithUUID:uuid endedAtDate:nil reason:CXCallEndedReasonRemoteEnded];
            [self.provider invalidate];
            check(genuineOperations == 0, @"no-genuine-operations");
            dispatch_block_t finish = ^{
              trace(@"abi.result", @{@"success":@((BOOL)!failed), @"concreteClass":NSStringFromClass(concrete)});
              trace(@"done", @{});
            };
            if ([scenario isEqual:@"refused-queues"]) [self checkRefusedQueues:finish]; else finish();
          });
        }];
      }];
    }];
  }];
}
- (void)providerDidReset:(CXProvider *)provider {}
- (void)provider:(CXProvider *)provider performAnswerCallAction:(CXAnswerCallAction *)action { [action fulfill]; }
- (void)provider:(CXProvider *)provider performSetHeldCallAction:(CXSetHeldCallAction *)action { [action fulfill]; }
@end

int main(int argc, char **argv) {
  @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(ABIProbe.class)); }
}
