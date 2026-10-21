// Spike: synthetic VoIP pushes delivered to an unchanged PKPushRegistryDelegate.
#import <Foundation/Foundation.h>
#import <PushKit/PushKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <notify.h>

@interface CKSimPayload : PKPushPayload
@property(nonatomic, copy) NSDictionary *payload;
@end
@implementation CKSimPayload
- (PKPushType)type { return PKPushTypeVoIP; }
- (NSDictionary *)dictionaryPayload { return self.payload; }
@end

#if CKSIM_HAS_VOIP_METADATA
API_AVAILABLE(ios(26.4))
@interface CKSimMetadata : PKVoIPPushMetadata
@end
@implementation CKSimMetadata
- (BOOL)mustReport { return YES; }
@end
#endif

static NSHashTable<PKPushRegistry *> *registries;
static IMP origSetDelegate;
static IMP origSetDesiredPushTypes;
static NSDictionary *pendingPayload; // Accessed only on main, like registries.

static NSUInteger deliver(NSDictionary *payload) {
  NSCAssert(NSThread.isMainThread, @"push fixture state belongs to main");
  NSUInteger delivered = 0;
  for (PKPushRegistry *registry in registries) {
    id delegate = registry.delegate;
    if (![registry.desiredPushTypes containsObject:PKPushTypeVoIP] || !delegate) continue;
    CKSimPayload *p = [CKSimPayload new];
    p.payload = payload;
    __block NSString *deliveryAPI = @"unknown";
    void (^completion)(void) = ^{
      fprintf(stderr, "CKSIM push completion called\n");
      // Optional fixture receipt for cross-process XCTest assertions. Carries
      // no payload or token and does not participate in application behavior.
      const char *receipt = getenv("CKSIM_PUSH_COMPLETION_NOTIFICATION");
      if (receipt && receipt[0]) {
        notify_post(receipt);
        notify_post([[NSString stringWithFormat:@"%s.%@", receipt, deliveryAPI] UTF8String]);
      }
    };
    SEL withMetadata = NSSelectorFromString(@"pushRegistry:didReceiveIncomingVoIPPushWithPayload:metadata:withCompletionHandler:");
    SEL legacy = @selector(pushRegistry:didReceiveIncomingPushWithPayload:forType:withCompletionHandler:);
    #if CKSIM_HAS_VOIP_METADATA
    if (@available(iOS 26.4, *)) {
      if ([delegate respondsToSelector:withMetadata]) {
      deliveryAPI = @"metadata";
      ((void (*)(id, SEL, id, id, id, id))objc_msgSend)(delegate, withMetadata, registry, p, [CKSimMetadata new], completion);
      fprintf(stderr, "CKSIM push delivered via metadata API\n");
        delivered++;
        continue;
      }
    }
    #endif
    if ([delegate respondsToSelector:legacy]) {
      deliveryAPI = @"legacy";
      [delegate pushRegistry:registry didReceiveIncomingPushWithPayload:p forType:PKPushTypeVoIP withCompletionHandler:completion];
      fprintf(stderr, "CKSIM push delivered via legacy API\n");
      delivered++;
    }
  }
  fprintf(stderr, "CKSIM push delivery eligible=%lu delivered=%lu\n", (unsigned long)registries.count, (unsigned long)delivered);
  return delivered;
}

void CKSimDeliverVoIPPush(NSDictionary *payload) {
  dispatch_async(dispatch_get_main_queue(), ^{ deliver(payload); });
}

static void attemptPending(void) {
  if (pendingPayload && deliver(pendingPayload)) pendingPayload = nil;
}

static void registerReady(PKPushRegistry *registry) {
  __weak PKPushRegistry *weakRegistry = registry;
  dispatch_async(dispatch_get_main_queue(), ^{
    PKPushRegistry *live = weakRegistry;
    if (!live) return;
    [registries addObject:live];
    fprintf(stderr, "CKSIM push registry ready-check\n");
    attemptPending();
  });
}

static void ck_setDelegate(PKPushRegistry *self, SEL _cmd, id delegate) {
  ((void (*)(id, SEL, id))origSetDelegate)(self, _cmd, delegate);
  registerReady(self);
}

static void ck_setDesiredPushTypes(PKPushRegistry *self, SEL _cmd, NSSet *types) {
  ((void (*)(id, SEL, id))origSetDesiredPushTypes)(self, _cmd, types);
  registerReady(self);
}

__attribute__((constructor)) static void CKSimPushInstall(void) {
  NSString *after = NSProcessInfo.processInfo.environment[@"CKSIM_PUSH_AFTER"];
  NSString *trigger = NSProcessInfo.processInfo.environment[@"CKSIM_PUSH_TRIGGER_NOTIFICATION"];
  if (!after.length && !trigger.length) return;
  registries = [NSHashTable weakObjectsHashTable];
  Method m = class_getInstanceMethod(PKPushRegistry.class, @selector(setDelegate:));
  origSetDelegate = method_setImplementation(m, (IMP)ck_setDelegate);
  Method desired = class_getInstanceMethod(PKPushRegistry.class, @selector(setDesiredPushTypes:));
  origSetDesiredPushTypes = method_setImplementation(desired, (IMP)ck_setDesiredPushTypes);
  fprintf(stderr, "CKSIM push hooks installed\n");
  void (^prepareFixture)(void) = ^{
    fprintf(stderr, "CKSIM push fixture ready\n");
    pendingPayload = @{@"aps": @{}, @"from": @"+15555550142", @"callId": @"synthetic-1"};
    attemptPending();
  };
  if (trigger.length) {
    int token;
    uint32_t status = notify_register_dispatch(trigger.UTF8String, &token, dispatch_get_main_queue(), ^(int notification) { prepareFixture(); });
    fprintf(stderr, "CKSIM push trigger installed status=%u\n", status);
  } else {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(after.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), prepareFixture);
  }
}
