#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Calls a PushKit completion handler exactly once: when the SDK finishes the push, or when the
/// watchdog fires first.
///
/// PushKit's completion handler isn't sendable, but the SDK may finish a push after the delegate
/// method returned, and the watchdog fires on its own queue. This object owns the handler, so it
/// can cross those boundaries.
NS_SWIFT_SENDABLE
@interface VSPushCompletion : NSObject
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/// Takes ownership of a completion handler and starts the watchdog.
///
/// @param completion PushKit's completion handler.
/// @param watchdog Seconds after which the handler is called even if the push isn't finished.
- (instancetype)initWithCompletion:(dispatch_block_t)completion
                          watchdog:(NSTimeInterval)watchdog NS_DESIGNATED_INITIALIZER;

/// Calls the completion handler, unless it was already called. It may be called on any thread.
- (void)finish;
@end

NS_ASSUME_NONNULL_END
