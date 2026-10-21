#import "CKRuntimeSeam.h"

#if TARGET_OS_SIMULATOR && TARGET_OS_IOS
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdatomic.h>

#ifndef CKSIM_HAS_VOIP_METADATA
#if __has_include(<PushKit/PKVoIPPushMetadata.h>)
#define CKSIM_HAS_VOIP_METADATA 1
#else
#define CKSIM_HAS_VOIP_METADATA 0
#endif
#endif

@interface CKRuntimePayload : PKPushPayload
@property(nonatomic, copy) NSDictionary *contents;
@end
@implementation CKRuntimePayload
- (PKPushType)type { return PKPushTypeVoIP; }
- (NSDictionary *)dictionaryPayload { return self.contents; }
@end
#if CKSIM_HAS_VOIP_METADATA
API_AVAILABLE(ios(26.4))
@interface CKRuntimeMetadata : PKVoIPPushMetadata
@property(nonatomic) BOOL required;
@end
@implementation CKRuntimeMetadata
- (BOOL)mustReport { return self.required; }
@end
#endif

// Registry bookkeeping belongs to main. Actual delivery uses each registry's
// configured queue, and synchronous report correlation uses thread-local scope.
static NSHashTable<PKPushRegistry *> *registries;
static NSMapTable<PKPushRegistry *, dispatch_queue_t> *registryQueues;
static NSMutableArray<NSDictionary *> *waiting;
static atomic_bool pushHooksActive;
static int fixtureNotificationToken = NOTIFY_TOKEN_INVALID;
static IMP originalInit, originalDelegate, originalTypes;
typedef id (*QueueInitializer)(id __attribute__((ns_consumed)), SEL, dispatch_queue_t) __attribute__((ns_returns_retained));
static NSString *const contextKey=@"dev.callkitsim.push-context";
NSString *CKSimCurrentPushID(void) { return NSThread.currentThread.threadDictionary[contextKey] ?: @""; }
static void deliver(PKPushRegistry *registry, NSDictionary *item) {
  if (!pushHooksActive) return;
  id delegate=registry.delegate;
  if (!delegate) return;
  NSString *identifier=item[@"id"];
  NSMutableDictionary *thread=NSThread.currentThread.threadDictionary;
  id previous=thread[contextKey]; thread[contextKey]=identifier;
  @try {
    CKRuntimePayload *payload=[CKRuntimePayload new]; payload.contents=item[@"payload"];
    __block NSString *api=@"legacy";
    void (^completion)(void)=^{
      CKSimEmit(@"push.completed",@{@"pushID":identifier,@"api":api});
      NSString *receipt=NSProcessInfo.processInfo.environment[@"CKSIM_PUSH_COMPLETION_NOTIFICATION"];
      if (receipt.length) { notify_post(receipt.UTF8String); notify_post([[receipt stringByAppendingFormat:@".%@",api] UTF8String]); }
    };
    SEL metadata=NSSelectorFromString(@"pushRegistry:didReceiveIncomingVoIPPushWithPayload:metadata:withCompletionHandler:");
    #if CKSIM_HAS_VOIP_METADATA
    if (@available(iOS 26.4,*)) {
      if ([delegate respondsToSelector:metadata]) {
        api=@"metadata";
        CKRuntimeMetadata *value=[CKRuntimeMetadata new]; value.required=[item[@"mustReport"] boolValue];
        CKSimEmit(@"push.received",@{@"pushID":identifier,@"api":api,@"mustReport":@(value.required)});
        ((void (*)(id,SEL,id,id,id,id))objc_msgSend)(delegate,metadata,registry,payload,value,completion);
        return;
      }
    }
    #endif
    if ([delegate respondsToSelector:@selector(pushRegistry:didReceiveIncomingPushWithPayload:forType:withCompletionHandler:)]) {
      CKSimEmit(@"push.received",@{@"pushID":identifier,@"api":api,@"mustReport":@YES});
      [delegate pushRegistry:registry didReceiveIncomingPushWithPayload:payload forType:PKPushTypeVoIP withCompletionHandler:completion];
    }
  } @finally { if (previous) thread[contextKey]=previous; else [thread removeObjectForKey:contextKey]; }
}
static void attempt(void) {
  NSCAssert(NSThread.isMainThread,@"Registry bookkeeping belongs to main");
  if (!pushHooksActive) return;
  for (NSDictionary *item in waiting.copy) {
    BOOL scheduled=NO;
    for (PKPushRegistry *registry in registries) {
      if (!registry.delegate || ![registry.desiredPushTypes containsObject:PKPushTypeVoIP]) continue;
      dispatch_queue_t queue=[registryQueues objectForKey:registry] ?: dispatch_get_main_queue();
      dispatch_async(queue,^{deliver(registry,item);}); scheduled=YES;
    }
    if (scheduled) [waiting removeObjectIdenticalTo:item];
  }
}
void CKSimInjectPush(NSDictionary *payload, BOOL mustReport, NSString *identifier) {
  dispatch_async(dispatch_get_main_queue(),^{
    if (!pushHooksActive) return;
    [waiting addObject:@{@"payload":payload,@"mustReport":@(mustReport),@"id":identifier}]; attempt();
  });
}
static void ready(PKPushRegistry *registry) {
  __weak PKPushRegistry *weak=registry;
  dispatch_async(dispatch_get_main_queue(),^{if (pushHooksActive && weak) [registries addObject:weak];attempt();});
}
__attribute__((ns_returns_retained)) static id registryInit(PKPushRegistry * __attribute__((ns_consumed)) self,SEL selector,dispatch_queue_t queue) {
  id registry=((QueueInitializer)originalInit)(self,selector,queue);
  __weak PKPushRegistry *weak=registry;
  dispatch_async(dispatch_get_main_queue(),^{if(pushHooksActive && weak){[registryQueues setObject:queue ?: dispatch_get_main_queue() forKey:weak];[registries addObject:weak];attempt();}});
  return registry;
}
static void setDelegate(PKPushRegistry *self,SEL selector,id delegate) { ((void (*)(id,SEL,id))originalDelegate)(self,selector,delegate);ready(self); }
static void setTypes(PKPushRegistry *self,SEL selector,NSSet *types) { ((void (*)(id,SEL,id))originalTypes)(self,selector,types);ready(self); }
NSString *CKSimInstallPushHooks(void) {
  Class concrete;
  @try { concrete=object_getClass([[PKPushRegistry alloc] initWithQueue:dispatch_get_main_queue()]); }
  @catch(NSException *exception) { return [NSString stringWithFormat:@"PKPushRegistry preflight: %@: %@",exception.name,exception.reason]; }
  if (!concrete) return @"PKPushRegistry initializer returned nil";
  SEL selectors[]={@selector(initWithQueue:),@selector(setDelegate:),@selector(setDesiredPushTypes:)};
  IMP replacements[]={(IMP)registryInit,(IMP)setDelegate,(IMP)setTypes};
  IMP *originals[]={&originalInit,&originalDelegate,&originalTypes};
  for (NSUInteger i=0;i<3;i++) {
    Method method=class_getInstanceMethod(PKPushRegistry.class,selectors[i]);
    if (!method || !class_getInstanceMethod(concrete,selectors[i]))
      return [NSString stringWithFormat:@"%@ missing selector %@",NSStringFromClass(concrete),NSStringFromSelector(selectors[i])];
    if (i==0 && class_getMethodImplementation(concrete,selectors[i])!=method_getImplementation(method))
      return [NSString stringWithFormat:@"%@ overrides %@",NSStringFromClass(concrete),NSStringFromSelector(selectors[i])];
  }
  // Save concrete inherited IMPs before changing PKPushRegistry itself.
  for (NSUInteger i=0;i<3;i++) {
    CKSimCaptureHook(PKPushRegistry.class,selectors[i]);
    CKSimCaptureHook(concrete,selectors[i]);
    *originals[i]=class_getMethodImplementation(PKPushRegistry.class,selectors[i]);
  }
  registries=[NSHashTable weakObjectsHashTable];registryQueues=[NSMapTable weakToStrongObjectsMapTable];waiting=[NSMutableArray new];
  for (NSUInteger i=0;i<3;i++) {
    Method method=class_getInstanceMethod(PKPushRegistry.class,selectors[i]);
    const char *encoding=method_getTypeEncoding(method);
    NSString *failure=CKSimReplaceHook(PKPushRegistry.class,selectors[i],replacements[i],encoding);
    if (failure) return failure;
    if (i>0 && concrete!=PKPushRegistry.class) {
      failure=CKSimReplaceHook(concrete,selectors[i],replacements[i],encoding);
      if (failure) return failure;
    }
    if (class_getMethodImplementation(concrete,selectors[i])!=replacements[i])
      return [NSString stringWithFormat:@"%@ failed to bind %@",NSStringFromClass(concrete),NSStringFromSelector(selectors[i])];
  }
  pushHooksActive=true;
  NSDictionary *env=NSProcessInfo.processInfo.environment;
  void (^fixture)(void)=^{
    CKSimInjectPush(@{@"aps":@{},@"from":@"+15555550142",@"callId":@"synthetic-1"},[env[@"CKSIM_PUSH_MUST_REPORT"] isEqual:@"1"],NSUUID.UUID.UUIDString);
  };
  if ([env[@"CKSIM_PUSH_TRIGGER_NOTIFICATION"] length]) {
    notify_register_dispatch([env[@"CKSIM_PUSH_TRIGGER_NOTIFICATION"] UTF8String],&fixtureNotificationToken,dispatch_get_main_queue(),^(int t){fixture();});
  } else if ([env[@"CKSIM_PUSH_AFTER"] length]) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)([env[@"CKSIM_PUSH_AFTER"] doubleValue]*NSEC_PER_SEC)),dispatch_get_main_queue(),fixture);
  }
  return nil;
}
void CKSimReleasePushHooks(void) {
  pushHooksActive=false;
  if (fixtureNotificationToken != NOTIFY_TOKEN_INVALID) {
    notify_cancel(fixtureNotificationToken);
    fixtureNotificationToken=NOTIFY_TOKEN_INVALID;
  }
}
#endif
