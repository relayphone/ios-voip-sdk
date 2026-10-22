#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A lock-owned delivery ticket that may cross native task and actor boundaries.
/// Finish only after the platform report settles, or the non-report plan is handled.
NS_SWIFT_SENDABLE
NS_SWIFT_NAME(PushDelivery)
@interface VSPushDelivery : NSObject
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
/// Idempotent. A watchdog completion does not acknowledge report settlement.
- (void)finish;
@end

NS_ASSUME_NONNULL_END
