#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
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

#if DEBUG && TARGET_OS_SIMULATOR
/// Internal source-compiled acceptance sink. Receives scalars on the observer's
/// main queue; no notification or session object escapes and no I/O is performed.
typedef void (^VSAudioSessionLifecycleDiagnosticHandler)(NSString *notificationName,
  NSString *contextClass, bool mainThread, VSAudioSessionLifecycleValue value);
FOUNDATION_EXPORT void VSAudioSessionSetLifecycleDiagnosticHandler(
  VSAudioSessionLifecycleDiagnosticHandler _Nullable handler);
#endif

/// Compiles the iOS/watchOS 27 API only when the selected SDK declares it; older
/// SDK builds retain the legacy notification path without referencing new names.
/// The handler is delivered on NSOperationQueue.mainQueue.
@interface VSAudioSessionLifecycleObserver : NSObject
- (instancetype)initWithHandler:(VSAudioSessionLifecycleHandler)handler;
- (void)invalidate;
@end
NS_ASSUME_NONNULL_END
