#import <Foundation/Foundation.h>
#include <stdbool.h>

NS_ASSUME_NONNULL_BEGIN
typedef NS_ENUM(NSInteger, VSAudioSessionLifecycleKind) {
  VSAudioSessionLifecycleKindActive,
  VSAudioSessionLifecycleKindInactive,
  VSAudioSessionLifecycleKindResumptionRecommended,
  VSAudioSessionLifecycleKindMediaServicesReset
};

/// Only immutable scalar observations cross the platform boundary. No session or
/// notification object is delivered to the SDK actor.
typedef struct {
  VSAudioSessionLifecycleKind kind;
  NSInteger source;
  NSUInteger interruptionReason;
  bool hasSource;
  bool hasInterruptionReason;
  bool shouldResume;
} VSAudioSessionLifecycleValue;
typedef void (^VSAudioSessionLifecycleHandler)(VSAudioSessionLifecycleValue value);

/// Compiles the iOS/watchOS 27 API only when the selected SDK declares it; older
/// SDK builds retain the legacy notification path without referencing new names.
/// The handler is delivered on NSOperationQueue.mainQueue.
@interface VSAudioSessionLifecycleObserver : NSObject
- (instancetype)initWithHandler:(VSAudioSessionLifecycleHandler)handler;
- (void)invalidate;
@end
NS_ASSUME_NONNULL_END
