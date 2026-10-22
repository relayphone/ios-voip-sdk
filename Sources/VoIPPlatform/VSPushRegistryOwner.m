#import "include/VSPushRegistryOwner.h"
#import "VSCompletionOnce.h"
#import <TargetConditionals.h>
#if defined(SDK_DEVICE_QA) && SDK_DEVICE_QA
#import "include/VSDeviceQADiagnostics.h"
#endif

#if TARGET_OS_IOS || TARGET_OS_WATCH
#import <PushKit/PushKit.h>
#if __has_include(<PushKit/PKVoIPPushMetadata.h>)
#import <PushKit/PKVoIPPushMetadata.h>
#define VS_HAS_VOIP_METADATA 1
#endif

static BOOL fail(NSError **error, NSInteger code, NSString *reason) {
  if (error) *error = [NSError errorWithDomain:@"VoIPSDK.PushRegistration" code:code
                                    userInfo:@{NSLocalizedDescriptionKey:reason}];
  return NO;
}

@interface VSPushRegistryOwner () <PKPushRegistryDelegate>
- (instancetype)initWithReceiver:(id<VSPushReceiver>)receiver;
@end

@implementation VSPushRegistryOwner {
  id<VSPushReceiver> _receiver;
  PKPushRegistry *_registry;
}

+ (instancetype)sharedOwnerWithReceiver:(id<VSPushReceiver>)receiver error:(NSError **)error {
  static VSPushRegistryOwner *owner;
  if (![NSThread isMainThread]) {
    fail(error, 1, @"Create the native push receiver on main during app launch.");
    return nil;
  }
  if (!receiver || ![receiver respondsToSelector:@selector(pushTokenDidUpdate:)] ||
      ![receiver respondsToSelector:@selector(pushTokenDidInvalidate)] ||
      ![receiver respondsToSelector:@selector(receiveVoIPPush:mustReport:completion:)]) {
    fail(error, 2, @"A complete native push receiver is required before registration.");
    return nil;
  }
  if (owner && owner->_receiver != receiver) {
    fail(error, 3, @"The process already owns a different native PushKit receiver.");
    return nil;
  }
  if (!owner) owner = [[self alloc] initWithReceiver:receiver];
  return owner;
}

- (instancetype)initWithReceiver:(id<VSPushReceiver>)receiver {
  if ((self = [super init])) _receiver = receiver;
  return self;
}

- (BOOL)isStarted { return _registry != nil; }

- (BOOL)startWithError:(NSError **)error {
  if (![NSThread isMainThread])
    return fail(error, 1, @"Register PushKit on main during app launch.");
  if (_registry) return YES;
  PKPushRegistry *registry = [[PKPushRegistry alloc] initWithQueue:dispatch_get_main_queue()];
  if (!registry) return fail(error, 4, @"PushKit could not create the process registry.");
  registry.delegate = self;
  // Retain before registration: a framework callback may arrive immediately.
  _registry = registry;
  registry.desiredPushTypes = [NSSet setWithObject:PKPushTypeVoIP];
  return YES;
}

- (void)pushRegistry:(PKPushRegistry *)registry
    didUpdatePushCredentials:(PKPushCredentials *)credentials forType:(PKPushType)type {
  if (![type isEqualToString:PKPushTypeVoIP]) return;
  NSData *token = [credentials.token copy];
  id<VSPushReceiver> receiver = _receiver;
  dispatch_block_t deliver = ^{ [receiver pushTokenDidUpdate:token]; };
  if ([NSThread isMainThread]) deliver();
  else dispatch_async(dispatch_get_main_queue(), deliver);
}

- (void)pushRegistry:(PKPushRegistry *)registry didInvalidatePushTokenForType:(PKPushType)type {
  if (![type isEqualToString:PKPushTypeVoIP]) return;
  id<VSPushReceiver> receiver = _receiver;
  dispatch_block_t deliver = ^{ [receiver pushTokenDidInvalidate]; };
  if ([NSThread isMainThread]) deliver();
  else dispatch_async(dispatch_get_main_queue(), deliver);
}

- (void)deliverPayload:(PKPushPayload *)payload mustReport:(BOOL)mustReport
          #if defined(SDK_DEVICE_QA) && SDK_DEVICE_QA
                  api:(NSString *)api
          #endif
           completion:(dispatch_block_t)completion {
  NSDictionary *dictionary = [payload.dictionaryPayload copy];
  id<VSPushReceiver> receiver = _receiver;
  #if defined(SDK_DEVICE_QA) && SDK_DEVICE_QA
  NSUUID *deliveryID = [NSUUID UUID];
  VSDeviceQAEmitPushEvent(@"push.ingress", deliveryID, api, mustReport);
  completion = VSDeviceQAObserveCompletion(deliveryID, api, mustReport, completion);
  #endif
  VSCompletionOnce *once = [[VSCompletionOnce alloc] initWithCompletion:completion retaining:receiver];
  dispatch_block_t deliver = ^{
    #if defined(SDK_DEVICE_QA) && SDK_DEVICE_QA
    VSDeviceQAWithDelivery(deliveryID, ^{
      [receiver receiveVoIPPush:dictionary mustReport:mustReport completion:^{ [once finish]; }];
    });
    #else
    [receiver receiveVoIPPush:dictionary mustReport:mustReport completion:^{ [once finish]; }];
    #endif
  };
  if ([NSThread isMainThread]) deliver();
  else dispatch_async(dispatch_get_main_queue(), deliver);
}

- (void)pushRegistry:(PKPushRegistry *)registry
    didReceiveIncomingPushWithPayload:(PKPushPayload *)payload
    forType:(PKPushType)type withCompletionHandler:(dispatch_block_t)completion {
  if (![type isEqualToString:PKPushTypeVoIP]) {
    VSCompletionOnce *once = [[VSCompletionOnce alloc] initWithCompletion:completion retaining:_receiver];
    [once finish];
    return;
  }
  [self deliverPayload:payload mustReport:YES
    #if defined(SDK_DEVICE_QA) && SDK_DEVICE_QA
                  api:@"legacy"
    #endif
           completion:completion];
}

#if VS_HAS_VOIP_METADATA
- (void)pushRegistry:(PKPushRegistry *)registry
    didReceiveIncomingVoIPPushWithPayload:(PKPushPayload *)payload
    metadata:(PKVoIPPushMetadata *)metadata
    withCompletionHandler:(dispatch_block_t)completion
    API_AVAILABLE(ios(26.4), watchos(26.4), macCatalyst(26.4)) {
  BOOL mustReport = YES;
  if (@available(iOS 26.4, watchOS 26.4, macCatalyst 26.4, *)) mustReport = metadata.mustReport;
  [self deliverPayload:payload mustReport:mustReport
    #if defined(SDK_DEVICE_QA) && SDK_DEVICE_QA
                  api:@"metadata"
    #endif
           completion:completion];
}
#endif
@end
#endif
