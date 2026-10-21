#import "CKRuntimeSeam.h"
#import <TargetConditionals.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>

#if !TARGET_OS_SIMULATOR
#error CallKit Simulator must never be built for a physical device.
#endif

extern void *CKSimGetEngine(void);
static BOOL installed;
bool CKSimRuntimeIsActive(void) { return installed; }
#ifndef CKSIM_RUNTIME_VERSION
#error Build with scripts/build-runtime.sh to supply the runtime version.
#endif
const char *CKSimRuntimeVersion(void) { return CKSIM_RUNTIME_VERSION; }
static id<CKRuntimeEngineProtocol> Engine(void) { return (__bridge id)CKSimGetEngine(); }
void CKSimEmit(NSString *event, NSDictionary *fields) { [Engine() recordEvent:event fields:fields]; }
NSString *CKSimResourceDirectory(void) {
  Dl_info info;
  return dladdr((void *)&CKSimResourceDirectory, &info) ? [@(info.dli_fname) stringByDeletingLastPathComponent] : @"";
}
CXCall *CKSimMakeCall(NSUUID *uuid, BOOL outgoing, BOOL connected, BOOL held, BOOL ended) {
  CXCall *call = ((id (*)(id, SEL, id))objc_msgSend)([CXCall alloc], NSSelectorFromString(@"initWithUUID:"), uuid);
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

static IMP originalProviderInit, originalControllerInit, originalFulfill, originalFail, originalDeadline;
static IMP originalStartFulfill, originalAnswerFulfill, originalEndFulfill, originalSetDelegate, originalIncoming;
@interface CKShadowDelegate : NSObject <CXProviderDelegate> @end
@implementation CKShadowDelegate
- (void)providerDidReset:(CXProvider *)provider {}
- (void)provider:(CXProvider *)provider performEndCallAction:(CXEndCallAction *)action { [action fulfill]; }
@end
static CKShadowDelegate *shadowInstance;
static void invalidate(CXProvider *self, SEL selector);
static IMP swap(Class cls, SEL selector, IMP replacement);
static BOOL Shadow(void) { return [NSProcessInfo.processInfo.environment[@"CKSIM_SHADOW"] isEqual:@"1"]; }
static id providerInit(CXProvider *self, SEL selector, CXProviderConfiguration *configuration) {
  id provider = ((id (*)(id, SEL, id))originalProviderInit)(self, selector, configuration);
  if (provider) {
    // CXProvider is a class cluster. The allocated implementation can override
    // invalidate without calling super, so bind the concrete class as well.
    Class concrete = object_getClass(provider);
    @synchronized(CXProvider.class) {
      if (class_getMethodImplementation(concrete, @selector(invalidate)) != (IMP)invalidate)
        swap(concrete, @selector(invalidate), (IMP)invalidate);
    }
    [Engine() registerProvider:provider];
    Dl_info info = {0};
    IMP imp = class_getMethodImplementation(object_getClass(provider), @selector(invalidate));
    dladdr((void *)imp, &info);
    CKSimEmit(@"provider.abi", @{@"class":NSStringFromClass(object_getClass(provider)),
      @"invalidateImage": info.dli_fname ? [@(info.dli_fname) lastPathComponent] : @"unknown"});
  }
  return provider;
}
static id controllerInit(CXCallController *self, SEL selector, dispatch_queue_t queue) {
  id controller = ((id (*)(id, SEL, dispatch_queue_t))originalControllerInit)(self, selector, queue);
  if (controller) [Engine() registerController:controller queue:queue];
  return controller;
}
static void providerDelegate(CXProvider *self, SEL selector, id delegate, dispatch_queue_t queue) {
  [Engine() setProvider:self delegate:delegate queue:queue];
  if (Shadow()) {
    static dispatch_once_t once; dispatch_once(&once, ^{ shadowInstance = [CKShadowDelegate new]; });
    ((void (*)(id, SEL, id, dispatch_queue_t))originalSetDelegate)(self, selector, shadowInstance, nil);
  }
}
static void incoming(CXProvider *self, SEL selector, NSUUID *uuid, CXCallUpdate *update, void (^completion)(NSError *)) {
  if (Shadow()) ((void (*)(id, SEL, id, id, id))originalIncoming)(self, selector, uuid, update, ^(NSError *error) {});
  [Engine() incomingProvider:self uuid:uuid update:update completion:completion];
}
static void updated(CXProvider *self, SEL selector, NSUUID *uuid, CXCallUpdate *update) { [Engine() updatedProvider:self uuid:uuid update:update]; }
static void ended(CXProvider *self, SEL selector, NSUUID *uuid, NSDate *date, CXCallEndedReason reason) { [Engine() endedProvider:self uuid:uuid reason:reason]; }
static void connecting(CXProvider *self, SEL selector, NSUUID *uuid, NSDate *date) {}
static void connected(CXProvider *self, SEL selector, NSUUID *uuid, NSDate *date) { [Engine() connectedProvider:self uuid:uuid]; }
static NSArray *pending(CXProvider *self, SEL selector) { return [Engine() pendingForProvider:self]; }
static NSArray *pendingActions(CXProvider *self, SEL selector, Class cls, NSUUID *uuid) {
  return [Engine() pendingActionsForProvider:self actionClass:cls uuid:uuid];
}
static NSDate *deadline(CXAction *self, SEL selector) { return [Engine() deadlineForAction:self] ?: ((id (*)(id, SEL))originalDeadline)(self,selector); }
static void invalidate(CXProvider *self, SEL selector) { [Engine() invalidateProvider:self]; }
static void request(CXCallController *self, SEL selector, CXTransaction *transaction, void (^completion)(NSError *)) { [Engine() requestTransaction:transaction controller:self completion:completion]; }
static void requestAction(CXCallController *self, SEL selector, CXAction *action, void (^completion)(NSError *)) { request(self, selector, [[CXTransaction alloc] initWithAction:action], completion); }
static void requestActions(CXCallController *self, SEL selector, NSArray *actions, void (^completion)(NSError *)) { request(self, selector, [[CXTransaction alloc] initWithActions:actions], completion); }
static NSArray *calls(CXCallObserver *self, SEL selector) { return [Engine() liveCalls]; }
static void observerDelegate(CXCallObserver *self, SEL selector, id delegate, dispatch_queue_t queue) { [Engine() setObserver:self delegate:delegate queue:queue]; }
static void fulfill(CXAction *self, SEL selector) { if (![Engine() completeAction:self fulfilled:YES]) ((void (*)(id, SEL))originalFulfill)(self, selector); }
static void fail(CXAction *self, SEL selector) { if (![Engine() completeAction:self fulfilled:NO]) ((void (*)(id, SEL))originalFail)(self, selector); }
static void startFulfill(CXAction *self, SEL selector, NSDate *date) { if (![Engine() completeAction:self fulfilled:YES]) ((void (*)(id, SEL, id))originalStartFulfill)(self, selector, date); }
static void answerFulfill(CXAction *self, SEL selector, NSDate *date) { if (![Engine() completeAction:self fulfilled:YES]) ((void (*)(id, SEL, id))originalAnswerFulfill)(self, selector, date); }
static void endFulfill(CXAction *self, SEL selector, NSDate *date) { if (![Engine() completeAction:self fulfilled:YES]) ((void (*)(id, SEL, id))originalEndFulfill)(self, selector, date); }
static IMP swap(Class cls, SEL selector, IMP replacement) {
  Method method = class_getInstanceMethod(cls, selector);
  if (!method) { fprintf(stderr,"CKSIM unsupported selector %s\n", sel_getName(selector)); abort(); }
  if (class_addMethod(cls, selector, replacement, method_getTypeEncoding(method))) return method_getImplementation(method);
  return method_setImplementation(method, replacement);
}
__attribute__((constructor)) static void install(void) {
  if (![NSProcessInfo.processInfo.environment[@"CKSIM_ENABLED"] isEqual:@"1"]) return;
  if (![CXCall instancesRespondToSelector:NSSelectorFromString(@"initWithUUID:")]) { fprintf(stderr,"CKSIM unsupported CallKit ABI\n"); return; }
  originalProviderInit = swap(CXProvider.class,@selector(initWithConfiguration:),(IMP)providerInit);
  originalControllerInit = swap(CXCallController.class,@selector(initWithQueue:),(IMP)controllerInit);
  originalSetDelegate = swap(CXProvider.class,@selector(setDelegate:queue:),(IMP)providerDelegate);
  originalIncoming = swap(CXProvider.class,@selector(reportNewIncomingCallWithUUID:update:completion:),(IMP)incoming);
  swap(CXProvider.class,@selector(reportCallWithUUID:updated:),(IMP)updated);
  swap(CXProvider.class,@selector(reportCallWithUUID:endedAtDate:reason:),(IMP)ended);
  swap(CXProvider.class,@selector(reportOutgoingCallWithUUID:startedConnectingAtDate:),(IMP)connecting);
  swap(CXProvider.class,@selector(reportOutgoingCallWithUUID:connectedAtDate:),(IMP)connected);
  swap(CXProvider.class,@selector(pendingTransactions),(IMP)pending);
  swap(CXProvider.class,@selector(pendingCallActionsOfClass:withCallUUID:),(IMP)pendingActions);
  swap(CXProvider.class,@selector(invalidate),(IMP)invalidate);
  swap(CXCallController.class,@selector(requestTransaction:completion:),(IMP)request);
  swap(CXCallController.class,@selector(requestTransactionWithAction:completion:),(IMP)requestAction);
  swap(CXCallController.class,@selector(requestTransactionWithActions:completion:),(IMP)requestActions);
  swap(CXCallObserver.class,@selector(calls),(IMP)calls);
  swap(CXCallObserver.class,@selector(setDelegate:queue:),(IMP)observerDelegate);
  originalFulfill=swap(CXAction.class,@selector(fulfill),(IMP)fulfill);
  originalFail=swap(CXAction.class,@selector(fail),(IMP)fail);
  originalDeadline=swap(CXAction.class,@selector(timeoutDate),(IMP)deadline);
  originalStartFulfill=swap(CXStartCallAction.class,@selector(fulfillWithDateStarted:),(IMP)startFulfill);
  originalAnswerFulfill=swap(CXAnswerCallAction.class,@selector(fulfillWithDateConnected:),(IMP)answerFulfill);
  originalEndFulfill=swap(CXEndCallAction.class,@selector(fulfillWithDateEnded:),(IMP)endFulfill);
  installed=YES;
  CKSimInstallPushHooks();
  CKSimEmit(@"runtime.installed",@{@"version":@(CKSimRuntimeVersion())});
}
