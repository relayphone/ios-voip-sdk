#import <Foundation/Foundation.h>
#import <CallKit/CallKit.h>
#import <AVFoundation/AVFoundation.h>
#import <PushKit/PushKit.h>
#import <notify.h>

NS_ASSUME_NONNULL_BEGIN
@protocol CKRuntimeEngineProtocol <NSObject>
- (void)registerProvider:(CXProvider *)provider NS_SWIFT_NAME(register(provider:));
- (void)setProvider:(CXProvider *)provider delegate:(nullable id<CXProviderDelegate>)delegate queue:(nullable dispatch_queue_t)queue NS_SWIFT_NAME(set(provider:delegate:queue:));
- (void)registerController:(CXCallController *)controller queue:(nullable dispatch_queue_t)queue NS_SWIFT_NAME(register(controller:queue:));
- (void)requestTransaction:(CXTransaction *)transaction controller:(CXCallController *)controller completion:(void (^)(NSError * _Nullable))completion NS_SWIFT_NAME(request(transaction:controller:completion:));
- (BOOL)completeAction:(CXAction *)action fulfilled:(BOOL)fulfilled NS_SWIFT_NAME(complete(action:fulfilled:));
- (nullable NSDate *)deadlineForAction:(CXAction *)action NS_SWIFT_NAME(deadline(action:));
- (NSArray<CXCallAction *> *)pendingActionsForProvider:(CXProvider *)provider actionClass:(Class)actionClass uuid:(NSUUID *)uuid NS_SWIFT_NAME(pendingActions(provider:actionClass:uuid:));
- (void)incomingProvider:(CXProvider *)provider uuid:(NSUUID *)uuid update:(CXCallUpdate *)update completion:(void (^)(NSError * _Nullable))completion NS_SWIFT_NAME(incoming(provider:uuid:update:completion:));
- (void)updatedProvider:(CXProvider *)provider uuid:(NSUUID *)uuid update:(CXCallUpdate *)update NS_SWIFT_NAME(updated(provider:uuid:update:));
- (void)endedProvider:(CXProvider *)provider uuid:(NSUUID *)uuid reason:(NSInteger)reason NS_SWIFT_NAME(ended(provider:uuid:reason:));
- (void)connectedProvider:(CXProvider *)provider uuid:(NSUUID *)uuid NS_SWIFT_NAME(connected(provider:uuid:));
- (NSArray<CXTransaction *> *)pendingForProvider:(CXProvider *)provider NS_SWIFT_NAME(pending(provider:));
- (void)invalidateProvider:(CXProvider *)provider NS_SWIFT_NAME(invalidate(provider:));
- (NSArray<CXCall *> *)liveCalls;
- (void)setObserver:(CXCallObserver *)observer delegate:(nullable id<CXCallObserverDelegate>)delegate queue:(nullable dispatch_queue_t)queue NS_SWIFT_NAME(set(observer:delegate:queue:));
- (void)recordEvent:(NSString *)event fields:(NSDictionary<NSString *, id> *)fields NS_SWIFT_NAME(record(event:fields:));
@end

CXCall *CKSimMakeCall(NSUUID *uuid, BOOL outgoing, BOOL connected, BOOL held, BOOL ended);
void CKSimPerform(id<CXProviderDelegate> delegate, CXProvider *provider, CXTransaction *transaction);
void CKSimInjectPush(NSDictionary *payload, BOOL mustReport, NSString *identifier);
NSString * _Nullable CKSimInstallPushHooks(void);
NSString *CKSimCurrentPushID(void);
NSString *CKSimResourceDirectory(void);
void CKSimEmit(NSString *event, NSDictionary *fields);
NS_ASSUME_NONNULL_END
