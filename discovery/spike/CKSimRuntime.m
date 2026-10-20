// Spike: an in-process stand-in for callservicesd, injected into an unmodified
// app in the simulator. Rules follow the iPhone 13 (iOS 27.0) reference traces.
#import <AVFoundation/AVFoundation.h>
#import <CallKit/CallKit.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

static void CKLog(NSString *format, ...) {
  va_list args;
  va_start(args, format);
  NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
  va_end(args);
  fprintf(stderr, "CKSIM %s\n", line.UTF8String);
}

static BOOL CKDeviceLatency(void) { return [NSProcessInfo.processInfo.environment[@"CKSIM_LATENCY"] isEqualToString:@"device"]; }
static NSString *const CKRequestDomain = @"com.apple.CallKit.error.requesttransaction";
static NSString *const CKIncomingDomain = @"com.apple.CallKit.error.incomingcall";

@interface CKSimCall : NSObject
@property(nonatomic, strong) NSUUID *uuid;
@property(nonatomic, weak) CXProvider *provider;
@property(nonatomic) BOOL outgoing, connected, held, ended;
@end
@implementation CKSimCall
@end

@interface CKSimPending : NSObject
@property(nonatomic, strong) CXAction *action;
@property(nonatomic, weak) CXProvider *provider;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) BOOL expired;
@end
@implementation CKSimPending
@end

@interface CKSimEngine : NSObject
@property(nonatomic, strong) NSMapTable<CXProvider *, id> *delegates;
@property(nonatomic, strong) NSMapTable<CXProvider *, dispatch_queue_t> *queues;
@property(nonatomic, strong) NSMapTable<CXCallObserver *, id> *observerDelegates;
@property(nonatomic, strong) NSMapTable<CXCallObserver *, dispatch_queue_t> *observerQueues;
@property(nonatomic, strong) NSMutableDictionary<NSUUID *, CKSimCall *> *calls;
@property(nonatomic, strong) NSMutableDictionary<NSUUID *, CKSimPending *> *pending;
@property(nonatomic, weak) CXProvider *currentProvider;
@property(nonatomic) BOOL audioActive;
@property(nonatomic) NSUInteger generation;
@end

static CKSimEngine *engine;
static bool installed;
bool CKSimRuntimeIsActive(void) { return installed; }

@implementation CKSimEngine
- (instancetype)init {
  if ((self = [super init])) {
    _delegates = [NSMapTable weakToWeakObjectsMapTable];
    _queues = [NSMapTable weakToStrongObjectsMapTable];
    _observerDelegates = [NSMapTable weakToWeakObjectsMapTable];
    _observerQueues = [NSMapTable weakToStrongObjectsMapTable];
    _calls = [NSMutableDictionary dictionary];
    _pending = [NSMutableDictionary dictionary];
  }
  return self;
}

// All engine state is confined to the main queue in this spike.
static void CKAfter(double seconds, dispatch_block_t block) {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), block);
}

- (dispatch_queue_t)queueFor:(CXProvider *)provider {
  return [self.queues objectForKey:provider] ?: dispatch_get_main_queue();
}

- (void)onDelegateOf:(CXProvider *)provider run:(void (^)(id delegate))block {
  id delegate = [self.delegates objectForKey:provider];
  if (!delegate) return;
  dispatch_async([self queueFor:provider], ^{ block(delegate); });
}

- (CXCall *)callObject:(CKSimCall *)state {
  CXCall *call = ((CXCall * (*)(id, SEL, NSUUID *)) objc_msgSend)([CXCall alloc], NSSelectorFromString(@"initWithUUID:"), state.uuid);
  [call setValue:@(state.outgoing) forKey:@"outgoing"];
  [call setValue:@(state.connected) forKey:@"hasConnected"];
  [call setValue:@(state.ended) forKey:@"hasEnded"];
  [call setValue:@(state.held) forKey:@"onHold"];
  return call;
}

- (NSArray<CXCall *> *)liveCalls {
  NSMutableArray *result = [NSMutableArray array];
  for (CKSimCall *call in self.calls.allValues)
    if (!call.ended) [result addObject:[self callObject:call]];
  return result;
}

- (void)changed:(CKSimCall *)state {
  CXCall *snapshot = [self callObject:state];
  for (CXCallObserver *observer in self.observerDelegates.keyEnumerator) {
    id delegate = [self.observerDelegates objectForKey:observer];
    dispatch_queue_t queue = [self.observerQueues objectForKey:observer] ?: dispatch_get_main_queue();
    dispatch_async(queue, ^{ [delegate callObserver:observer callChanged:snapshot]; });
  }
  if (state.ended) [self.calls removeObjectForKey:state.uuid];
}

#pragma mark Audio

- (BOOL)hasActiveUnheldCall {
  for (CKSimCall *call in self.calls.allValues)
    if (!call.ended && !call.held && (call.connected || call.outgoing)) return YES;
  return NO;
}

- (void)activateAudioAfter:(double)delay provider:(CXProvider *)provider {
  CKAfter(delay, ^{
    if (self.audioActive || ![self hasActiveUnheldCall]) return;
    NSError *error;
    BOOL ok = [AVAudioSession.sharedInstance setActive:YES error:&error];
    CKLog(@"audio activate ok=%d error=%@", ok, error);
    if (!ok) return;
    self.audioActive = YES;
    [self onDelegateOf:provider run:^(id delegate) {
      if ([delegate respondsToSelector:@selector(provider:didActivateAudioSession:)])
        [delegate provider:provider didActivateAudioSession:AVAudioSession.sharedInstance];
    }];
  });
}

- (void)deactivateAudioAfter:(double)delay provider:(CXProvider *)provider {
  CKAfter(delay, ^{
    if (!self.audioActive || [self hasActiveUnheldCall]) return;
    self.audioActive = NO;
    [AVAudioSession.sharedInstance setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
    [self onDelegateOf:provider run:^(id delegate) {
      if ([delegate respondsToSelector:@selector(provider:didDeactivateAudioSession:)])
        [delegate provider:provider didDeactivateAudioSession:AVAudioSession.sharedInstance];
    }];
  });
}

#pragma mark Actions

- (NSTimeInterval)deadlineFor:(CXAction *)action {
  if ([action isKindOfClass:CXStartCallAction.class]) return 600;
  if ([action isKindOfClass:CXAnswerCallAction.class]) return 60;
  return 5;
}

- (void)deliver:(NSArray<CXAction *> *)actions provider:(CXProvider *)provider system:(BOOL)system {
  NSUInteger generation = ++self.generation;
  for (CXAction *action in actions) {
    CKSimPending *pending = [CKSimPending new];
    pending.action = action;
    pending.provider = provider;
    pending.generation = generation;
    self.pending[action.UUID] = pending;
    NSTimeInterval deadline = [self deadlineFor:action];
    BOOL answer = [action isKindOfClass:CXAnswerCallAction.class];
    CKAfter(answer ? deadline - 0.4 : deadline + 0.2, ^{ [self expire:pending]; });
  }
  CXTransaction *transaction = [[CXTransaction alloc] initWithActions:actions];
  [self onDelegateOf:provider run:^(id delegate) {
    if ([delegate respondsToSelector:@selector(provider:executeTransaction:)] && [delegate provider:provider executeTransaction:transaction]) return;
    for (CXAction *action in actions) {
      SEL selector = NULL;
      if ([action isKindOfClass:CXStartCallAction.class]) selector = @selector(provider:performStartCallAction:);
      else if ([action isKindOfClass:CXAnswerCallAction.class]) selector = @selector(provider:performAnswerCallAction:);
      else if ([action isKindOfClass:CXEndCallAction.class]) selector = @selector(provider:performEndCallAction:);
      else if ([action isKindOfClass:CXSetHeldCallAction.class]) selector = @selector(provider:performSetHeldCallAction:);
      else if ([action isKindOfClass:CXSetMutedCallAction.class]) selector = @selector(provider:performSetMutedCallAction:);
      else if ([action isKindOfClass:CXSetGroupCallAction.class]) selector = @selector(provider:performSetGroupCallAction:);
      else if ([action isKindOfClass:CXPlayDTMFCallAction.class]) selector = @selector(provider:performPlayDTMFCallAction:);
      if (selector && [delegate respondsToSelector:selector]) ((void (*)(id, SEL, id, id))objc_msgSend)(delegate, selector, provider, action);
      else [action fail];
    }
  }];
  if (system) CKLog(@"system delivered %@", actions);
}

- (void)expire:(CKSimPending *)pending {
  CXAction *action = pending.action;
  if (!self.pending[action.UUID] || pending.expired) return;
  CXProvider *provider = pending.provider;
  if ([action isKindOfClass:CXAnswerCallAction.class]) {
    // Device: no timeout callback; the system ends the call and the answer stays pending.
    pending.expired = YES;
    NSUUID *callUUID = ((CXCallAction *)action).callUUID;
    if (self.calls[callUUID]) [self deliver:@[ [[CXEndCallAction alloc] initWithCallUUID:callUUID] ] provider:provider system:YES];
    return;
  }
  [self.pending removeObjectForKey:action.UUID];
  [self onDelegateOf:provider run:^(id delegate) {
    if ([delegate respondsToSelector:@selector(provider:timedOutPerformingAction:)]) [delegate provider:provider timedOutPerformingAction:action];
  }];
  if ([action isKindOfClass:CXEndCallAction.class]) [self endCall:((CXCallAction *)action).callUUID provider:provider after:0.02];
}

- (void)endCall:(NSUUID *)uuid provider:(CXProvider *)provider after:(double)delay {
  CKAfter(delay, ^{
    CKSimCall *call = self.calls[uuid];
    if (!call || call.ended) return;
    BOOL only = self.calls.count == 1;
    call.ended = YES;
    [self changed:call];
    [self deactivateAudioAfter:(only ? 0.1 : 1.15) provider:provider];
  });
}

// Returns YES when the engine owned the action.
- (BOOL)complete:(CXAction *)action fulfilled:(BOOL)fulfilled {
  CKSimPending *pending = self.pending[action.UUID];
  if (!pending) return NO;
  [self.pending removeObjectForKey:action.UUID];
  if (pending.expired) return YES;  // late completion of an expired answer: accepted, no effect
  CXProvider *provider = pending.provider;
  NSUUID *callUUID = [action isKindOfClass:CXCallAction.class] ? ((CXCallAction *)action).callUUID : nil;
  CKSimCall *call = callUUID ? self.calls[callUUID] : nil;
  if (!call) {
    // Device: a completion for a call that no longer exists is ignored and later times out.
    CKAfter(5.2, ^{
      [self onDelegateOf:provider run:^(id delegate) {
        if ([delegate respondsToSelector:@selector(provider:timedOutPerformingAction:)]) [delegate provider:provider timedOutPerformingAction:action];
      }];
    });
    return YES;
  }
  if ([action isKindOfClass:CXAnswerCallAction.class]) {
    if (fulfilled) {
      CKAfter(0.01, ^{ call.connected = YES; [self changed:call]; });
      [self activateAudioAfter:0.29 provider:provider];
    } else {
      [self endCall:callUUID provider:provider after:0.29];
      CKAfter(0.3, ^{ [self deliver:@[ [[CXEndCallAction alloc] initWithCallUUID:callUUID] ] provider:provider system:YES]; });
    }
  } else if ([action isKindOfClass:CXStartCallAction.class]) {
    if (fulfilled) [self activateAudioAfter:0.23 provider:provider];
    else [self endCall:callUUID provider:provider after:0.17];
  } else if ([action isKindOfClass:CXEndCallAction.class]) {
    if (fulfilled) [self endCall:callUUID provider:provider after:0.01];
  } else if ([action isKindOfClass:CXSetHeldCallAction.class] && fulfilled) {
    BOOL held = ((CXSetHeldCallAction *)action).isOnHold;
    CKAfter(0.02, ^{
      call.held = held;
      [self changed:call];
      if (held) [self deactivateAudioAfter:0.09 provider:provider];
      else [self activateAudioAfter:0.18 provider:provider];
    });
  }
  return YES;
}

#pragma mark Requests and reports

- (NSError *)validate:(NSArray<CXAction *> *)actions {
  if (actions.count == 0) return [NSError errorWithDomain:CKRequestDomain code:CXErrorCodeRequestTransactionErrorUnentitled userInfo:nil];
  for (CXAction *action in actions) {
    if (![action isKindOfClass:CXCallAction.class]) continue;
    NSUUID *uuid = ((CXCallAction *)action).callUUID;
    CKSimCall *call = self.calls[uuid];
    if ([action isKindOfClass:CXStartCallAction.class]) {
      if (call) return [NSError errorWithDomain:CKRequestDomain code:CXErrorCodeRequestTransactionErrorCallUUIDAlreadyExists userInfo:nil];
      continue;
    }
    if (!call || call.ended) return [NSError errorWithDomain:CKRequestDomain code:CXErrorCodeRequestTransactionErrorUnknownCallUUID userInfo:nil];
    if ([action isKindOfClass:CXAnswerCallAction.class]) {
      for (CKSimCall *other in self.calls.allValues)
        if (other != call && !other.ended) return [NSError errorWithDomain:CKRequestDomain code:CXErrorCodeRequestTransactionErrorInvalidAction userInfo:nil];
    }
  }
  return nil;
}

- (void)request:(CXTransaction *)transaction queue:(dispatch_queue_t)queue completion:(void (^)(NSError *))completion {
  dispatch_async(dispatch_get_main_queue(), ^{
    NSArray<CXAction *> *actions = transaction.actions;
    NSError *error = [self validate:actions];
    CXProvider *provider = self.currentProvider;
    CKLog(@"request %@ -> %@", [actions valueForKey:@"class"], error ?: @"ok");
    if (!error) {
      for (CXAction *action in actions) {
        if (![action isKindOfClass:CXStartCallAction.class]) continue;
        CKSimCall *call = [CKSimCall new];
        call.uuid = ((CXStartCallAction *)action).callUUID;
        call.provider = provider;
        call.outgoing = YES;
        self.calls[call.uuid] = call;
        [self changed:call];
      }
    }
    dispatch_async(queue, ^{ if (completion) completion(error); });
    if (!error) CKAfter(0.005, ^{ [self deliver:actions provider:provider system:NO]; });
  });
}

- (void)reportIncoming:(NSUUID *)uuid provider:(CXProvider *)provider completion:(void (^)(NSError *))completion {
  double latency = CKDeviceLatency() ? 1.1 : 0.02;
  CKAfter(latency, ^{
    NSError *error;
    if (self.calls[uuid]) error = [NSError errorWithDomain:CKIncomingDomain code:CXErrorCodeIncomingCallErrorCallUUIDAlreadyExists userInfo:nil];
    else {
      CKSimCall *call = [CKSimCall new];
      call.uuid = uuid;
      call.provider = provider;
      self.calls[uuid] = call;
      [self changed:call];
    }
    CKLog(@"report incoming %@ -> %@", uuid.UUIDString, error ?: @"ok");
    dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(error); });
  });
}
@end

#pragma mark Shadow reports to genuine CallKit

// Receives only what the genuine daemon sends to the real provider; never the app's delegate.
@interface CKSimShadowDelegate : NSObject <CXProviderDelegate>
@end
@implementation CKSimShadowDelegate
- (void)providerDidReset:(CXProvider *)provider { CKLog(@"shadow providerDidReset"); }
- (void)providerDidBegin:(CXProvider *)provider { CKLog(@"shadow providerDidBegin"); }
- (void)provider:(CXProvider *)provider performEndCallAction:(CXEndCallAction *)action {
  CKLog(@"shadow end action for %@ (system teardown)", action.callUUID.UUIDString);
  [action fulfill];
}
- (void)provider:(CXProvider *)provider timedOutPerformingAction:(CXAction *)action { CKLog(@"shadow timeout %@", action.class); }
@end
static CKSimShadowDelegate *shadowDelegate;
static BOOL CKShadow(void) { return [NSProcessInfo.processInfo.environment[@"CKSIM_SHADOW"] isEqualToString:@"1"]; }
static IMP origSetProviderDelegate, origReportIncoming;

#pragma mark Swizzled implementations

static IMP origFulfill, origFail, origStartFulfill, origAnswerFulfill, origEndFulfill;

static void ck_fulfill(CXAction *self, SEL _cmd) {
  if (![engine complete:self fulfilled:YES]) ((void (*)(id, SEL))origFulfill)(self, _cmd);
}
static void ck_fail(CXAction *self, SEL _cmd) {
  if (![engine complete:self fulfilled:NO]) ((void (*)(id, SEL))origFail)(self, _cmd);
}
static void ck_startFulfill(CXAction *self, SEL _cmd, NSDate *date) {
  if (![engine complete:self fulfilled:YES]) ((void (*)(id, SEL, NSDate *))origStartFulfill)(self, _cmd, date);
}
static void ck_answerFulfill(CXAction *self, SEL _cmd, NSDate *date) {
  if (![engine complete:self fulfilled:YES]) ((void (*)(id, SEL, NSDate *))origAnswerFulfill)(self, _cmd, date);
}
static void ck_endFulfill(CXAction *self, SEL _cmd, NSDate *date) {
  if (![engine complete:self fulfilled:YES]) ((void (*)(id, SEL, NSDate *))origEndFulfill)(self, _cmd, date);
}

static void ck_setDelegate(CXProvider *self, SEL _cmd, id delegate, dispatch_queue_t queue) {
  [engine.delegates setObject:delegate forKey:self];
  if (queue) [engine.queues setObject:queue forKey:self];
  engine.currentProvider = self;
  if (CKShadow()) {
    shadowDelegate = shadowDelegate ?: [CKSimShadowDelegate new];
    ((void (*)(id, SEL, id, dispatch_queue_t))origSetProviderDelegate)(self, _cmd, shadowDelegate, nil);
  }
  CKLog(@"provider delegate set shadow=%d", CKShadow());
  [engine onDelegateOf:self run:^(id d) { if ([d respondsToSelector:@selector(providerDidBegin:)]) [d providerDidBegin:self]; }];
}
static void ck_reportIncoming(CXProvider *self, SEL _cmd, NSUUID *uuid, CXCallUpdate *update, void (^completion)(NSError *)) {
  engine.currentProvider = self;
  if (CKShadow()) {
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    ((void (*)(id, SEL, NSUUID *, CXCallUpdate *, void (^)(NSError *)))origReportIncoming)(self, _cmd, uuid, update, ^(NSError *error) {
      CKLog(@"shadow report %@ -> %@ after %.0f ms", uuid.UUIDString, error ?: @"ok", (CFAbsoluteTimeGetCurrent() - start) * 1000);
    });
  }
  [engine reportIncoming:uuid provider:self completion:completion];
}
static void ck_reportUpdated(CXProvider *self, SEL _cmd, NSUUID *uuid, CXCallUpdate *update) {}
static void ck_reportEnded(CXProvider *self, SEL _cmd, NSUUID *uuid, NSDate *date, CXCallEndedReason reason) {
  dispatch_async(dispatch_get_main_queue(), ^{ [engine endCall:uuid provider:self after:0.015]; });
}
static void ck_reportConnecting(CXProvider *self, SEL _cmd, NSUUID *uuid, NSDate *date) {}
static void ck_reportConnected(CXProvider *self, SEL _cmd, NSUUID *uuid, NSDate *date) {
  dispatch_async(dispatch_get_main_queue(), ^{
    CKSimCall *call = engine.calls[uuid];
    if (call && !call.ended) { call.connected = YES; [engine changed:call]; }
  });
}
static NSArray *ck_pendingTransactions(CXProvider *self, SEL _cmd) {
  NSMutableArray *result = [NSMutableArray array];
  for (CKSimPending *pending in engine.pending.allValues)
    if (pending.provider == self) [result addObject:[[CXTransaction alloc] initWithAction:pending.action]];
  return result;
}
static void ck_invalidate(CXProvider *self, SEL _cmd) {
  for (CKSimCall *call in engine.calls.allValues.copy) if (call.provider == self) [engine endCall:call.uuid provider:self after:0];
  [engine.delegates removeObjectForKey:self];
}
static void ck_request(CXCallController *self, SEL _cmd, CXTransaction *transaction, void (^completion)(NSError *)) {
  dispatch_queue_t queue = [self valueForKey:@"completionQueue"] ?: dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
  [engine request:transaction queue:queue completion:completion];
}
static NSArray *ck_calls(CXCallObserver *self, SEL _cmd) { return engine.liveCalls; }
static void ck_observerSetDelegate(CXCallObserver *self, SEL _cmd, id delegate, dispatch_queue_t queue) {
  [engine.observerDelegates setObject:delegate forKey:self];
  if (queue) [engine.observerQueues setObject:queue forKey:self];
}

static IMP CKSwap(Class cls, SEL selector, IMP replacement) {
  Method method = class_getInstanceMethod(cls, selector);
  if (!method) { CKLog(@"missing %@ %@", NSStringFromClass(cls), NSStringFromSelector(selector)); return NULL; }
  // Add on the exact class first so a subclass swap never changes its superclass.
  if (class_addMethod(cls, selector, replacement, method_getTypeEncoding(method))) return method_getImplementation(method);
  return method_setImplementation(method, replacement);
}

__attribute__((constructor)) static void CKSimInstall(void) {
  if (![NSProcessInfo.processInfo.environment[@"CKSIM_ENABLED"] isEqualToString:@"1"]) return;
  engine = [CKSimEngine new];
  origFulfill = CKSwap(CXAction.class, @selector(fulfill), (IMP)ck_fulfill);
  origFail = CKSwap(CXAction.class, @selector(fail), (IMP)ck_fail);
  origStartFulfill = CKSwap(CXStartCallAction.class, @selector(fulfillWithDateStarted:), (IMP)ck_startFulfill);
  origAnswerFulfill = CKSwap(CXAnswerCallAction.class, @selector(fulfillWithDateConnected:), (IMP)ck_answerFulfill);
  origEndFulfill = CKSwap(CXEndCallAction.class, @selector(fulfillWithDateEnded:), (IMP)ck_endFulfill);
  origSetProviderDelegate = CKSwap(CXProvider.class, @selector(setDelegate:queue:), (IMP)ck_setDelegate);
  origReportIncoming = CKSwap(CXProvider.class, @selector(reportNewIncomingCallWithUUID:update:completion:), (IMP)ck_reportIncoming);
  CKSwap(CXProvider.class, @selector(reportCallWithUUID:updated:), (IMP)ck_reportUpdated);
  CKSwap(CXProvider.class, @selector(reportCallWithUUID:endedAtDate:reason:), (IMP)ck_reportEnded);
  CKSwap(CXProvider.class, @selector(reportOutgoingCallWithUUID:startedConnectingAtDate:), (IMP)ck_reportConnecting);
  CKSwap(CXProvider.class, @selector(reportOutgoingCallWithUUID:connectedAtDate:), (IMP)ck_reportConnected);
  CKSwap(CXProvider.class, @selector(pendingTransactions), (IMP)ck_pendingTransactions);
  CKSwap(CXProvider.class, @selector(invalidate), (IMP)ck_invalidate);
  CKSwap(CXCallController.class, @selector(requestTransaction:completion:), (IMP)ck_request);
  CKSwap(CXCallObserver.class, @selector(calls), (IMP)ck_calls);
  CKSwap(CXCallObserver.class, @selector(setDelegate:queue:), (IMP)ck_observerSetDelegate);
  CKLog(@"installed latency=%@", CKDeviceLatency() ? @"device" : @"fast");
  installed = true;
}
