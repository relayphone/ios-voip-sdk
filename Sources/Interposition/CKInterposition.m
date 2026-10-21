#import "CKRuntimeSeam.h"

#if TARGET_OS_SIMULATOR && TARGET_OS_IOS
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <stdatomic.h>

// Objective-C init consumes its receiver and returns +1. Both the C hook and
// calls through saved IMPs must preserve those ARC conventions.
typedef id (*ObjectInitializer)(id __attribute__((ns_consumed)), SEL, id) __attribute__((ns_returns_retained));
typedef id (*QueueInitializer)(id __attribute__((ns_consumed)), SEL, dispatch_queue_t) __attribute__((ns_returns_retained));
static atomic_bool installed;
static NSString *refusalReason;
static BOOL activationAttempted;
// Refusal callbacks still honor caller queues without creating the Swift engine.
static NSMapTable<CXProvider *, dispatch_queue_t> *providerQueues;
static NSMapTable<CXCallController *, dispatch_queue_t> *controllerQueues;
bool CKSimRuntimeIsActive(void) { return installed; }
#ifndef CKSIM_RUNTIME_VERSION
#error Build with scripts/build-runtime.sh to supply the runtime version.
#endif
const char *CKSimRuntimeVersion(void) { return CKSIM_RUNTIME_VERSION; }
static id<CKRuntimeEngineProtocol> Engine(void) { return (__bridge_transfer id)CKSimGetEngine(); }

typedef struct {
  __unsafe_unretained Class cls;
  SEL selector;
  IMP implementation;
} HookRestore;
static NSMutableArray<NSValue *> *hookRestores;
static NSValue *savedHook(Class cls, SEL selector) {
  for (NSValue *value in hookRestores) {
    HookRestore entry; [value getValue:&entry size:sizeof(entry)];
    if (entry.cls == cls && entry.selector == selector) return value;
  }
  return nil;
}
void CKSimCaptureHook(Class cls, SEL selector) {
  if (!cls || savedHook(cls, selector)) return;
  IMP original = class_getMethodImplementation(cls, selector);
  // A newly encountered concrete class can inherit an already swapped method.
  // Recover the defining class's saved IMP rather than journaling our hook.
  for (Class owner = cls; owner; owner = class_getSuperclass(owner)) {
    unsigned int count;
    Method *methods = class_copyMethodList(owner, &count);
    BOOL defines = NO;
    for (unsigned int i = 0; i < count; i++) if (method_getName(methods[i]) == selector) { defines = YES; break; }
    free(methods);
    if (!defines) continue;
    NSValue *saved = savedHook(owner, selector);
    if (saved) { HookRestore entry; [saved getValue:&entry size:sizeof(entry)]; original = entry.implementation; }
    break;
  }
  if (!hookRestores) hookRestores = [NSMutableArray new];
  HookRestore entry = {cls, selector, original};
  [hookRestores addObject:[NSValue valueWithBytes:&entry objCType:@encode(HookRestore)]];
}
NSString *CKSimReplaceHook(Class cls, SEL selector, IMP replacement, const char *encoding) {
  CKSimCaptureHook(cls, selector);
  if (!class_addMethod(cls, selector, replacement, encoding)) {
    Method local = class_getInstanceMethod(cls, selector);
    if (local) method_setImplementation(local, replacement);
  }
  return class_getMethodImplementation(cls, selector) == replacement ? nil :
    [NSString stringWithFormat:@"%@ failed to bind %@", NSStringFromClass(cls), NSStringFromSelector(selector)];
}
#if CKSIM_SDK_SOURCE
static void restoreHooks(void) {
  CKSimReleasePushHooks();
  for (NSValue *value in hookRestores.reverseObjectEnumerator) {
    HookRestore entry; [value getValue:&entry size:sizeof(entry)];
    Method method = class_getInstanceMethod(entry.cls, entry.selector);
    if (method && entry.implementation) method_setImplementation(method, entry.implementation);
  }
  [hookRestores removeAllObjects];
}
#endif
void CKSimEmit(NSString *event, NSDictionary *fields) { [Engine() recordEvent:event fields:fields]; }
NSString *CKSimResourceDirectory(void) {
  Dl_info info;
  return dladdr((void *)&CKSimResourceDirectory, &info) ? [@(info.dli_fname) stringByDeletingLastPathComponent] : @"";
}
CXCall *CKSimMakeCall(NSUUID *uuid, BOOL outgoing, BOOL connected, BOOL held, BOOL ended) {
  CXCall *call = ((ObjectInitializer)objc_msgSend)([CXCall alloc], NSSelectorFromString(@"initWithUUID:"), uuid);
  [call setValue:@(outgoing) forKey:@"outgoing"];
  [call setValue:@(connected) forKey:@"hasConnected"];
  [call setValue:@(held) forKey:@"onHold"];
  [call setValue:@(ended) forKey:@"hasEnded"];
  return call;
}
void CKSimPerform(id<CXProviderDelegate> delegate, CXProvider *provider, CXTransaction *transaction) {
  if ([delegate respondsToSelector:@selector(provider:executeTransaction:)] && [delegate provider:provider executeTransaction:transaction]) return;
  for (CXAction *action in transaction.actions) {
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
}

static IMP originalProviderInit, originalControllerInit, originalConcreteProviderInit, originalConcreteControllerInit;
static _Thread_local NSUInteger providerInitDepth, controllerInitDepth;
static void refuse(NSString *reason);
static IMP originalSetDelegate, originalIncoming;
static NSDictionary<NSString *, NSValue *> *actionOriginals;
typedef struct ActionFrame {
  void *receiver;
  SEL selector;
  __unsafe_unretained Class owner;
  struct ActionFrame *previous;
} ActionFrame;
static _Thread_local ActionFrame *actionFrame;
static NSString *actionKey(Class cls, SEL selector) {
  return [NSString stringWithFormat:@"%@/%@", NSStringFromClass(cls), NSStringFromSelector(selector)];
}
static id invokeOriginalAction(CXAction *action, SEL selector, NSDate *date) {
  Class owner = object_getClass(action);
  for (ActionFrame *frame = actionFrame; frame; frame = frame->previous) {
    if (frame->receiver == (__bridge void *)action && frame->selector == selector) {
      owner = class_getSuperclass(frame->owner);
      break;
    }
  }
  NSValue *value;
  while (owner && !(value = actionOriginals[actionKey(owner, selector)])) owner = class_getSuperclass(owner);
  if (!value) { refuse([NSString stringWithFormat:@"%@ missing original %@", NSStringFromClass(object_getClass(action)), NSStringFromSelector(selector)]); return selector == @selector(timeoutDate) ? NSDate.date : nil; }
  IMP original = (IMP)value.pointerValue;
  ActionFrame frame = {(__bridge void *)action, selector, owner, actionFrame};
  actionFrame = &frame;
  id result = nil;
  @try {
    if (selector == @selector(timeoutDate)) result = ((id (*)(id, SEL))original)(action, selector);
    else if (selector == @selector(fulfill) || selector == @selector(fail)) ((void (*)(id, SEL))original)(action, selector);
    else ((void (*)(id, SEL, id))original)(action, selector, date);
  } @finally { actionFrame = frame.previous; }
  return result;
}
@interface CKShadowDelegate : NSObject <CXProviderDelegate> @end
@implementation CKShadowDelegate
- (void)providerDidReset:(CXProvider *)provider {}
- (void)provider:(CXProvider *)provider performEndCallAction:(CXEndCallAction *)action { [action fulfill]; }
@end
static CKShadowDelegate *shadowInstance;
static void invalidate(CXProvider *self, SEL selector);
static void bindConcrete(Class concrete, Class root);
static void refuse(NSString *reason) {
  @synchronized(CXProvider.class) {
    BOOL wasInstalled = installed;
    if (!refusalReason) {
      refusalReason = reason.copy;
      fprintf(stderr, "CKSIM runtime refused: %s\n", reason.UTF8String);
    }
    installed = false;
    #if CKSIM_SDK_SOURCE
    if (wasInstalled) { restoreHooks(); CKSimReleaseEngine(); }
    #else
    (void)wasInstalled;
    #endif
  }
}
static dispatch_queue_t callbackQueue(NSMapTable *queues, id object) {
  @synchronized(CXProvider.class) { return [queues objectForKey:object] ?: dispatch_get_main_queue(); }
}
static void refusedCompletion(dispatch_queue_t queue, void (^completion)(NSError *)) {
  NSError *error = [NSError errorWithDomain:@"CKSimRuntimeErrorDomain" code:1
    userInfo:@{NSLocalizedDescriptionKey:refusalReason ?: @"Runtime activation failed"}];
  if (completion) dispatch_async(queue, ^{ completion(error); });
}
static BOOL Shadow(void) { return [NSProcessInfo.processInfo.environment[@"CKSIM_SHADOW"] isEqual:@"1"]; }
static void initializedProvider(CXProvider *provider) {
  if (!provider) return;
  @synchronized(CXProvider.class) { bindConcrete(object_getClass(provider), CXProvider.class); }
  if (!installed) return;
  [Engine() registerProvider:provider];
  Dl_info info = {0};
  IMP imp = class_getMethodImplementation(object_getClass(provider), @selector(invalidate));
  dladdr((void *)imp, &info);
  CKSimEmit(@"provider.abi", @{@"class":NSStringFromClass(object_getClass(provider)),
    @"invalidateImage": info.dli_fname ? [@(info.dli_fname) lastPathComponent] : @"unknown"});
}
static void initializedController(CXCallController *controller, dispatch_queue_t queue) {
  if (!controller) return;
  @synchronized(CXProvider.class) {
    [controllerQueues setObject:queue ?: dispatch_get_main_queue() forKey:controller];
    bindConcrete(object_getClass(controller), CXCallController.class);
  }
  if (installed) [Engine() registerController:controller queue:queue];
}
__attribute__((ns_returns_retained)) static id providerInit(CXProvider * __attribute__((ns_consumed)) self, SEL selector, CXProviderConfiguration *configuration) {
  providerInitDepth++;
  id provider;
  @try { provider = ((ObjectInitializer)originalProviderInit)(self, selector, configuration); }
  @finally { providerInitDepth--; }
  if (providerInitDepth == 0) initializedProvider(provider);
  return provider;
}
__attribute__((ns_returns_retained)) static id providerConcreteInit(CXProvider * __attribute__((ns_consumed)) self, SEL selector, CXProviderConfiguration *configuration) {
  providerInitDepth++;
  id provider;
  @try { provider = ((ObjectInitializer)originalConcreteProviderInit)(self, selector, configuration); }
  @finally { providerInitDepth--; }
  if (providerInitDepth == 0) initializedProvider(provider);
  return provider;
}
__attribute__((ns_returns_retained)) static id controllerInit(CXCallController * __attribute__((ns_consumed)) self, SEL selector, dispatch_queue_t queue) {
  controllerInitDepth++;
  id controller;
  @try { controller = ((QueueInitializer)originalControllerInit)(self, selector, queue); }
  @finally { controllerInitDepth--; }
  if (controllerInitDepth == 0) initializedController(controller, queue);
  return controller;
}
__attribute__((ns_returns_retained)) static id controllerConcreteInit(CXCallController * __attribute__((ns_consumed)) self, SEL selector, dispatch_queue_t queue) {
  controllerInitDepth++;
  id controller;
  @try { controller = ((QueueInitializer)originalConcreteControllerInit)(self, selector, queue); }
  @finally { controllerInitDepth--; }
  if (controllerInitDepth == 0) initializedController(controller, queue);
  return controller;
}
static void providerDelegate(CXProvider *self, SEL selector, id delegate, dispatch_queue_t queue) {
  @synchronized(CXProvider.class) { [providerQueues setObject:queue ?: dispatch_get_main_queue() forKey:self]; }
  if (!installed) return;
  [Engine() setProvider:self delegate:delegate queue:queue];
  if (Shadow()) {
    static dispatch_once_t once; dispatch_once(&once, ^{ shadowInstance = [CKShadowDelegate new]; });
    ((void (*)(id, SEL, id, dispatch_queue_t))originalSetDelegate)(self, selector, shadowInstance, nil);
  }
}
static void incoming(CXProvider *self, SEL selector, NSUUID *uuid, CXCallUpdate *update, void (^completion)(NSError *)) {
  if (!installed) { refusedCompletion(callbackQueue(providerQueues, self), completion); return; }
  if (Shadow()) ((void (*)(id, SEL, id, id, id))originalIncoming)(self, selector, uuid, update, ^(NSError *error) {});
  [Engine() incomingProvider:self uuid:uuid update:update completion:completion];
}
static void updated(CXProvider *self, SEL selector, NSUUID *uuid, CXCallUpdate *update) { if (installed) [Engine() updatedProvider:self uuid:uuid update:update]; }
static void ended(CXProvider *self, SEL selector, NSUUID *uuid, NSDate *date, CXCallEndedReason reason) { if (installed) [Engine() endedProvider:self uuid:uuid reason:reason]; }
static void connecting(CXProvider *self, SEL selector, NSUUID *uuid, NSDate *date) {}
static void connected(CXProvider *self, SEL selector, NSUUID *uuid, NSDate *date) { if (installed) [Engine() connectedProvider:self uuid:uuid]; }
static NSArray *pending(CXProvider *self, SEL selector) { return installed ? [Engine() pendingForProvider:self] : @[]; }
static NSArray *pendingActions(CXProvider *self, SEL selector, Class cls, NSUUID *uuid) {
  return installed ? [Engine() pendingActionsForProvider:self actionClass:cls uuid:uuid] : @[];
}
static NSDate *deadline(CXAction *self, SEL selector) { if (!installed) return NSDate.date; return [Engine() deadlineForAction:self] ?: invokeOriginalAction(self, selector, nil); }
static void invalidate(CXProvider *self, SEL selector) { if (installed) [Engine() invalidateProvider:self]; }
static void request(CXCallController *self, SEL selector, CXTransaction *transaction, void (^completion)(NSError *)) { if (installed) [Engine() requestTransaction:transaction controller:self completion:completion]; else refusedCompletion(callbackQueue(controllerQueues, self), completion); }
static void requestAction(CXCallController *self, SEL selector, CXAction *action, void (^completion)(NSError *)) { request(self, selector, [[CXTransaction alloc] initWithAction:action], completion); }
static void requestActions(CXCallController *self, SEL selector, NSArray *actions, void (^completion)(NSError *)) { request(self, selector, [[CXTransaction alloc] initWithActions:actions], completion); }
static NSArray *calls(CXCallObserver *self, SEL selector) { return installed ? [Engine() liveCalls] : @[]; }
static void observerDelegate(CXCallObserver *self, SEL selector, id delegate, dispatch_queue_t queue) { if (installed) [Engine() setObserver:self delegate:delegate queue:queue]; }
static void fulfill(CXAction *self, SEL selector) { if (!installed) return; if (![Engine() completeAction:self fulfilled:YES]) invokeOriginalAction(self, selector, nil); }
static void fail(CXAction *self, SEL selector) { if (!installed) return; if (![Engine() completeAction:self fulfilled:NO]) invokeOriginalAction(self, selector, nil); }
static void startFulfill(CXAction *self, SEL selector, NSDate *date) { if (!installed) return; if (![Engine() completeAction:self fulfilled:YES]) invokeOriginalAction(self, selector, date); }
static void answerFulfill(CXAction *self, SEL selector, NSDate *date) { if (!installed) return; if (![Engine() completeAction:self fulfilled:YES]) invokeOriginalAction(self, selector, date); }
static void endFulfill(CXAction *self, SEL selector, NSDate *date) { if (!installed) return; if (![Engine() completeAction:self fulfilled:YES]) invokeOriginalAction(self, selector, date); }
// Public and concrete initializers keep separate original IMPs. Their nested
// super calls register only at the outermost return. Operational methods bind
// on both public classes and each returned concrete class.
typedef struct {
  Class root;
  SEL selector;
  IMP replacement;
  IMP *original;
  const char *encoding;
  BOOL initializer;
} Hook;
static Hook hooks[22];
static NSUInteger hookCount;

static void bindHook(Class cls, Hook hook, BOOL captureOriginal) {
  #if CKSIM_SDK_SOURCE
  if (refusalReason) return;
  #endif
  Method method = class_getInstanceMethod(cls, hook.selector);
  #if CKSIM_ABI_TESTING
  // Fault the lookup seam, so the production missing-method guard and fallback
  // encoding run. This branch is absent from distributed runtime builds.
  if ([NSProcessInfo.processInfo.environment[@"CKSIM_TEST_MISSING_SELECTOR"] isEqual:NSStringFromSelector(hook.selector)]) method = NULL;
  #endif
  if (!method) refuse([NSString stringWithFormat:@"%@ missing selector %@", NSStringFromClass(cls), NSStringFromSelector(hook.selector)]);
  #if CKSIM_SDK_SOURCE
  if (!method) return;
  #endif
  // Keep the genuine constructor cached before validation faults or mutation.
  if (hook.initializer && (!hook.original || !*hook.original)) return;
  IMP previous = method ? method_getImplementation(method) : NULL;
  const char *encoding = method ? method_getTypeEncoding(method) : hook.encoding;
  NSString *failure = CKSimReplaceHook(cls, hook.selector, hook.replacement, encoding);
  if (captureOriginal && hook.original && previous) *hook.original = previous;
  if (failure) refuse(failure);
}
static void bindConcrete(Class concrete, Class root) {
  for (NSUInteger i = 0; i < hookCount; i++) {
    Hook hook = hooks[i];
    if (hook.root != root) continue;
    if (!hook.initializer) bindHook(concrete, hook, NO);
    IMP actual = class_getMethodImplementation(concrete, hook.selector);
    BOOL concreteInitializer = hook.initializer &&
      ((root == CXProvider.class && actual == (IMP)providerConcreteInit) ||
       (root == CXCallController.class && actual == (IMP)controllerConcreteInit));
    if (actual != hook.replacement && !concreteInitializer)
      refuse([NSString stringWithFormat:@"%@ overrides %@", NSStringFromClass(concrete), NSStringFromSelector(hook.selector)]);
  }
}
static void captureActionOriginals(NSArray<CXAction *> *actions) {
  NSMutableDictionary<NSString *, NSValue *> *originals = [NSMutableDictionary new];
  for (CXAction *action in actions) {
    for (NSUInteger i = 0; i < hookCount; i++) {
      Hook hook = hooks[i];
      if (![action isKindOfClass:hook.root]) continue;
      BOOL found = NO;
      // Capture every defining level before mutation, then hook the same chain.
      // Each original-to-super transition crosses a hook and advances once.
      for (Class owner = object_getClass(action); owner && [owner isSubclassOfClass:hook.root]; owner = class_getSuperclass(owner)) {
        unsigned int count;
        Method *methods = class_copyMethodList(owner, &count);
        for (unsigned int j = 0; j < count; j++) {
          if (method_getName(methods[j]) != hook.selector) continue;
          originals[actionKey(owner, hook.selector)] = [NSValue valueWithPointer:(const void *)method_getImplementation(methods[j])];
          found = YES;
        }
        free(methods);
      }
      if (!found) refuse([NSString stringWithFormat:@"%@ missing selector %@", NSStringFromClass(object_getClass(action)), NSStringFromSelector(hook.selector)]);
    }
  }
  actionOriginals = originals.copy;
}
static void bindActions(NSArray<CXAction *> *actions) {
  for (CXAction *action in actions) {
    for (NSUInteger i = 0; i < hookCount; i++) {
      Hook hook = hooks[i];
      for (Class cls = object_getClass(action); cls && [cls isSubclassOfClass:hook.root]; cls = class_getSuperclass(cls)) bindHook(cls, hook, NO);
    }
  }
}
static void verifySnapshot(void) {
  NSString *key = @"initWithUUID:";
  @try {
    SEL initializer = NSSelectorFromString(key);
    if (![CXCall instancesRespondToSelector:initializer]) { refuse(@"CXCall missing initWithUUID:"); return; }
    CXCall *call = ((ObjectInitializer)objc_msgSend)([CXCall alloc], initializer, NSUUID.UUID);
    if (!call) { refuse(@"CXCall initWithUUID: returned nil"); return; }
    NSArray *keys = @[@"outgoing", @"hasConnected", @"onHold", @"hasEnded"];
    SEL getters[] = {@selector(isOutgoing), @selector(hasConnected), @selector(isOnHold), @selector(hasEnded)};
    for (NSUInteger i = 0; i < keys.count; i++) {
      key = keys[i];
      for (NSNumber *value in @[@YES, @NO]) {
        [call setValue:value forKey:key];
        BOOL actual = ((BOOL (*)(id, SEL))objc_msgSend)(call, getters[i]);
        if (actual != value.boolValue || ![[call valueForKey:key] isEqual:value]) {
          refuse([NSString stringWithFormat:@"CXCall snapshot key %@ failed readback (%@)", key, value]);
          return;
        }
      }
    }
  } @catch (NSException *exception) {
    refuse([NSString stringWithFormat:@"CXCall snapshot key %@: %@: %@", key, exception.name, exception.reason]);
  }
}
static void installHooks(void) {
  @autoreleasepool {
    Hook configured[] = {
      {CXProvider.class,@selector(initWithConfiguration:),(IMP)providerInit,&originalProviderInit,"@@:@",YES},
      {CXCallController.class,@selector(initWithQueue:),(IMP)controllerInit,&originalControllerInit,"@@:@",YES},
      {CXProvider.class,@selector(setDelegate:queue:),(IMP)providerDelegate,&originalSetDelegate,"v@:@@",NO},
      {CXProvider.class,@selector(reportNewIncomingCallWithUUID:update:completion:),(IMP)incoming,&originalIncoming,"v@:@@@?",NO},
      {CXProvider.class,@selector(reportCallWithUUID:updated:),(IMP)updated,NULL,"v@:@@",NO},
      {CXProvider.class,@selector(reportCallWithUUID:endedAtDate:reason:),(IMP)ended,NULL,"v@:@@q",NO},
      {CXProvider.class,@selector(reportOutgoingCallWithUUID:startedConnectingAtDate:),(IMP)connecting,NULL,"v@:@@",NO},
      {CXProvider.class,@selector(reportOutgoingCallWithUUID:connectedAtDate:),(IMP)connected,NULL,"v@:@@",NO},
      {CXProvider.class,@selector(pendingTransactions),(IMP)pending,NULL,"@@:",NO},
      {CXProvider.class,@selector(pendingCallActionsOfClass:withCallUUID:),(IMP)pendingActions,NULL,"@@:#@",NO},
      {CXProvider.class,@selector(invalidate),(IMP)invalidate,NULL,"v@:",NO},
      {CXCallController.class,@selector(requestTransaction:completion:),(IMP)request,NULL,"v@:@@?",NO},
      {CXCallController.class,@selector(requestTransactionWithAction:completion:),(IMP)requestAction,NULL,"v@:@@?",NO},
      {CXCallController.class,@selector(requestTransactionWithActions:completion:),(IMP)requestActions,NULL,"v@:@@?",NO},
      {CXCallObserver.class,@selector(calls),(IMP)calls,NULL,"@@:",NO},
      {CXCallObserver.class,@selector(setDelegate:queue:),(IMP)observerDelegate,NULL,"v@:@@",NO},
      {CXAction.class,@selector(fulfill),(IMP)fulfill,NULL,"v@:",NO},
      {CXAction.class,@selector(fail),(IMP)fail,NULL,"v@:",NO},
      {CXAction.class,@selector(timeoutDate),(IMP)deadline,NULL,"@@:",NO},
      {CXStartCallAction.class,@selector(fulfillWithDateStarted:),(IMP)startFulfill,NULL,"v@:@",NO},
      {CXAnswerCallAction.class,@selector(fulfillWithDateConnected:),(IMP)answerFulfill,NULL,"v@:@",NO},
      {CXEndCallAction.class,@selector(fulfillWithDateEnded:),(IMP)endFulfill,NULL,"v@:@",NO}
    };
    _Static_assert(sizeof(configured) == sizeof(hooks), "Hook table storage must match configured hooks");
    hookCount = sizeof(configured) / sizeof(configured[0]);
    memcpy(hooks, configured, sizeof(configured));
    Class providerClass = CXProvider.class;
    Class controllerClass = CXCallController.class;
    Class observerClass = CXCallObserver.class;
    providerQueues = [NSMapTable weakToStrongObjectsMapTable];
    controllerQueues = [NSMapTable weakToStrongObjectsMapTable];
    // Capture before validation fault injection or mutation. Never allocate an
    // object whose public constructor is genuinely absent from this Apple ABI.
    Method providerInitializer = class_getInstanceMethod(CXProvider.class, @selector(initWithConfiguration:));
    Method controllerInitializer = class_getInstanceMethod(CXCallController.class, @selector(initWithQueue:));
    originalProviderInit = providerInitializer ? method_getImplementation(providerInitializer) : NULL;
    originalControllerInit = controllerInitializer ? method_getImplementation(controllerInitializer) : NULL;
    if (!providerInitializer) refuse(@"CXProvider missing selector initWithConfiguration:");
    if (!controllerInitializer) refuse(@"CXCallController missing selector initWithQueue:");
    NSArray<CXAction *> *actions = @[];
    @try {
      if (providerInitializer) {
        CXProvider *sample = [[CXProvider alloc] initWithConfiguration:[CXProviderConfiguration new]];
        providerClass = object_getClass(sample) ?: providerClass;
        if (!sample) refuse(@"CXProvider initializer returned nil");
        [sample invalidate];
      }
      if (controllerInitializer) {
        CXCallController *controller = [[CXCallController alloc] initWithQueue:dispatch_get_main_queue()];
        controllerClass = object_getClass(controller) ?: controllerClass;
        if (!controller) refuse(@"CXCallController initializer returned nil");
        observerClass = object_getClass(controller.callObserver) ?: observerClass;
      }
      NSUUID *uuid = NSUUID.UUID;
      actions = @[[CXAction new], [[CXStartCallAction alloc] initWithCallUUID:uuid handle:[[CXHandle alloc] initWithType:CXHandleTypeGeneric value:@"ABI preflight"]],
        [[CXAnswerCallAction alloc] initWithCallUUID:uuid], [[CXEndCallAction alloc] initWithCallUUID:uuid],
        [[CXSetHeldCallAction alloc] initWithCallUUID:uuid onHold:NO], [[CXSetMutedCallAction alloc] initWithCallUUID:uuid muted:NO],
        [[CXSetGroupCallAction alloc] initWithCallUUID:uuid callUUIDToGroupWith:nil],
        [[CXPlayDTMFCallAction alloc] initWithCallUUID:uuid digits:@"1" type:CXPlayDTMFCallActionTypeSingleTone]];
      #if CKSIM_ABI_TESTING
      for (NSString *name in [NSProcessInfo.processInfo.environment[@"CKSIM_TEST_ACTION_CLASSES"] componentsSeparatedByString:@","]) {
        Class cls = NSClassFromString(name);
        if (cls && [cls isSubclassOfClass:CXAction.class]) actions = [actions arrayByAddingObject:[cls new]];
      }
      #endif
    } @catch (NSException *exception) {
      refuse([NSString stringWithFormat:@"CallKit concrete-class preflight: %@: %@", exception.name, exception.reason]);
    }
    verifySnapshot();
    captureActionOriginals(actions);
    if (Shadow()) {
      SEL selectors[] = {@selector(setDelegate:queue:), @selector(reportNewIncomingCallWithUUID:update:completion:)};
      for (NSUInteger i = 0; i < sizeof(selectors) / sizeof(selectors[0]); i++) {
        if (class_getMethodImplementation(providerClass, selectors[i]) != class_getMethodImplementation(CXProvider.class, selectors[i]))
          refuse([NSString stringWithFormat:@"Shadow mode cannot forward %@ override %@", NSStringFromClass(providerClass), NSStringFromSelector(selectors[i])]);
      }
    }
    Method concreteProviderInitializer = class_getInstanceMethod(providerClass, @selector(initWithConfiguration:));
    Method concreteControllerInitializer = class_getInstanceMethod(controllerClass, @selector(initWithQueue:));
    originalConcreteProviderInit = concreteProviderInitializer ? method_getImplementation(concreteProviderInitializer) : NULL;
    originalConcreteControllerInit = concreteControllerInitializer ? method_getImplementation(concreteControllerInitializer) : NULL;
    #if CKSIM_SDK_SOURCE
    if (refusalReason) return;
    #endif
    // Snapshot every known concrete target before changing any root class.
    // Otherwise an inherited method would be recorded as our replacement.
    for (NSUInteger i = 0; i < hookCount; i++) {
      Hook hook = hooks[i];
      CKSimCaptureHook(hook.root, hook.selector);
      if (hook.root == CXProvider.class) CKSimCaptureHook(providerClass, hook.selector);
      if (hook.root == CXCallController.class) CKSimCaptureHook(controllerClass, hook.selector);
      if (hook.root == CXCallObserver.class) {
        CKSimCaptureHook(observerClass, hook.selector);
        CKSimCaptureHook(object_getClass([CXCallObserver new]), hook.selector);
      }
      for (CXAction *action in actions)
        for (Class cls = object_getClass(action); cls && [cls isSubclassOfClass:hook.root]; cls = class_getSuperclass(cls))
          CKSimCaptureHook(cls, hook.selector);
    }
    for (NSUInteger i = 0; i < hookCount; i++) {
      Hook hook = hooks[i];
      bindHook(hook.root, hook, YES);
    }
    if (providerClass != CXProvider.class) {
      Hook hook = hooks[0]; hook.replacement = (IMP)providerConcreteInit; hook.original = &originalConcreteProviderInit;
      bindHook(providerClass, hook, NO);
    }
    if (controllerClass != CXCallController.class) {
      Hook hook = hooks[1]; hook.replacement = (IMP)controllerConcreteInit; hook.original = &originalConcreteControllerInit;
      bindHook(controllerClass, hook, NO);
    }
    bindConcrete(providerClass, CXProvider.class);
    bindConcrete(controllerClass, CXCallController.class);
    bindConcrete(observerClass, CXCallObserver.class);
    bindConcrete(object_getClass([CXCallObserver new]), CXCallObserver.class);
    bindActions(actions);
    if (refusalReason) return;
    NSString *pushFailure = CKSimInstallPushHooks();
    if (pushFailure) { refuse(pushFailure); return; }
    #if CKSIM_ABI_TESTING
    if ([NSProcessInfo.processInfo.environment[@"CKSIM_TEST_FAILURE"] isEqual:@"push-after-install"]) {
      refuse(@"ABI test failure after PushKit hook installation"); return;
    }
    #endif
    installed = true;
    CKSimEmit(@"runtime.installed",@{@"version":@(CKSimRuntimeVersion())});
  }
}

bool CKSimActivateRuntime(void) {
  @autoreleasepool {
    @synchronized(CXProvider.class) {
      if (installed) return true;
      if (activationAttempted) return false;
      activationAttempted = YES;
      @try {
        if (!CKSimPrepareEngine()) {
          refuse(@"Engine preparation failed; see preceding runtime diagnostic");
          #if CKSIM_SDK_SOURCE
          return false;
          #endif
        }
        installHooks();
      } @catch (NSException *exception) {
        refuse([NSString stringWithFormat:@"Runtime activation: %@: %@", exception.name, exception.reason]);
      } @finally {
        if (!installed) {
          #if CKSIM_SDK_SOURCE
          restoreHooks();
          #endif
          CKSimReleaseEngine();
        }
      }
      return installed;
    }
  }
}

#if !CKSIM_SDK_SOURCE
__attribute__((constructor)) static void install(void) {
  if ([NSProcessInfo.processInfo.environment[@"CKSIM_ENABLED"] isEqual:@"1"]) CKSimActivateRuntime();
}
#endif
#endif
