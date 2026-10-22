#pragma once
#import <TargetConditionals.h>

#if TARGET_OS_SIMULATOR && TARGET_OS_IOS
#import <stdbool.h>
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

bool CKSimPrepareEngine(void);
void CKSimReleaseEngine(void);
// Returns a retained engine handle; the Objective-C bridge consumes ownership.
void * _Nullable CKSimGetEngine(void);
bool CKSimActivateRuntime(void);
bool CKSimRuntimeIsActive(void);
const char *CKSimRuntimeVersion(void);
// Runtime mailbox and example controls exist only in simulator builds.
void CKSimInjectPush(NSDictionary *payload, BOOL mustReport, NSString *identifier);
// SDK Debug simulator builds only. No implementation is linked in Release.
bool CKSimInstallProviderCreationObserver(void (^observer)(id provider));

// Capture before replacing any superclass implementation. SDK activation uses
// the same journal for CallKit and PushKit so a refusal restores both together.
void CKSimCaptureHook(Class cls, SEL selector);
NSString * _Nullable CKSimReplaceHook(Class cls, SEL selector, IMP replacement, const char *encoding);

CXCall *CKSimMakeCall(NSUUID *uuid, BOOL outgoing, BOOL connected, BOOL held, BOOL ended);
void CKSimPerform(id<CXProviderDelegate> delegate, CXProvider *provider, CXTransaction *transaction);
NSString * _Nullable CKSimInstallPushHooks(void);
void CKSimReleasePushHooks(void);
NSString *CKSimCurrentPushID(void);
NSString *CKSimResourceDirectory(void);
BOOL CKSimDelegateUsesLiveCommunicationKit(id _Nullable delegate);
NS_ASSUME_NONNULL_END
#endif
