#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The native receiver must be ready during app launch, before push registration.
/// It decides reporting policy and finishes each push after its native work settles.
NS_SWIFT_UI_ACTOR
NS_SWIFT_NAME(PushReceiver)
@protocol VSPushReceiver <NSObject>
- (void)pushTokenDidUpdate:(NSData *)token;
- (void)pushTokenDidInvalidate;
- (void)receiveVoIPPush:(NSDictionary *)payload
           mustReport:(BOOL)mustReport
           completion:(dispatch_block_t)completion;
@end

/// One process-lifetime registry and native receiver. Never logs a push token.
NS_SWIFT_UI_ACTOR
NS_SWIFT_NAME(PushRegistryOwner)
API_AVAILABLE(ios(17.4), watchos(10.4)) API_UNAVAILABLE(macos, tvos)
@interface VSPushRegistryOwner : NSObject
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/// Must be called on main. A different receiver cannot replace the first owner.
+ (nullable instancetype)sharedOwnerWithReceiver:(id<VSPushReceiver>)receiver
                                          error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(shared(receiver:));
/// Idempotent. Assigns the delegate before registering the VoIP push type.
- (BOOL)startWithError:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(start());
@property(nonatomic, readonly, getter=isStarted) BOOL started;
@end

NS_ASSUME_NONNULL_END
