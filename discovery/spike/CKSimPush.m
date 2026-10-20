// Spike: synthetic VoIP pushes delivered to an unchanged PKPushRegistryDelegate.
#import <Foundation/Foundation.h>
#import <PushKit/PushKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

@interface CKSimPayload : PKPushPayload
@property(nonatomic, copy) NSDictionary *payload;
@end
@implementation CKSimPayload
- (PKPushType)type { return PKPushTypeVoIP; }
- (NSDictionary *)dictionaryPayload { return self.payload; }
@end

#if CKSIM_HAS_VOIP_METADATA
@interface CKSimMetadata : PKVoIPPushMetadata
@end
@implementation CKSimMetadata
- (BOOL)mustReport { return YES; }
@end
#endif

static NSHashTable<PKPushRegistry *> *registries;
static IMP origSetDelegate;
static void ck_setDelegate(PKPushRegistry *self, SEL _cmd, id delegate) {
  [registries addObject:self];
  ((void (*)(id, SEL, id))origSetDelegate)(self, _cmd, delegate);
}

void CKSimDeliverVoIPPush(NSDictionary *payload) {
  for (PKPushRegistry *registry in registries) {
    id delegate = registry.delegate;
    CKSimPayload *p = [CKSimPayload new];
    p.payload = payload;
    void (^completion)(void) = ^{ fprintf(stderr, "CKSIM push completion called\n"); };
    SEL withMetadata = NSSelectorFromString(@"pushRegistry:didReceiveIncomingVoIPPushWithPayload:metadata:withCompletionHandler:");
    SEL legacy = @selector(pushRegistry:didReceiveIncomingPushWithPayload:forType:withCompletionHandler:);
    #if CKSIM_HAS_VOIP_METADATA
    if (@available(iOS 26.4, *)) {
      if ([delegate respondsToSelector:withMetadata]) {
      ((void (*)(id, SEL, id, id, id, id))objc_msgSend)(delegate, withMetadata, registry, p, [CKSimMetadata new], completion);
      fprintf(stderr, "CKSIM push delivered via metadata API\n");
        continue;
      }
    }
    #endif
    if ([delegate respondsToSelector:legacy]) {
      [delegate pushRegistry:registry didReceiveIncomingPushWithPayload:p forType:PKPushTypeVoIP withCompletionHandler:completion];
      fprintf(stderr, "CKSIM push delivered via legacy API\n");
    }
  }
}

__attribute__((constructor)) static void CKSimPushInstall(void) {
  NSString *after = NSProcessInfo.processInfo.environment[@"CKSIM_PUSH_AFTER"];
  if (!after) return;
  registries = [NSHashTable weakObjectsHashTable];
  Method m = class_getInstanceMethod(PKPushRegistry.class, @selector(setDelegate:));
  origSetDelegate = method_setImplementation(m, (IMP)ck_setDelegate);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(after.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    CKSimDeliverVoIPPush(@{@"aps": @{}, @"from": @"+15555550142", @"callId": @"synthetic-1"});
  });
}
