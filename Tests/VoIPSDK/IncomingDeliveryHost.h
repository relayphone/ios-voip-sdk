#import <Foundation/Foundation.h>
#import "VSPushRegistryOwner.h"
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

/// Host-only: call once on main with the fixture's actual production receiver.
/// Dispatches the production owner's exact delivery method on a serial queue,
/// handshakes worker entry, and blocks main for exactly three seconds.
FOUNDATION_EXPORT void HostDrive(id<VSPushReceiver> receiver);
/// Call at the fixture reporting seam's actual entry, before it can suspend.
FOUNDATION_EXPORT void HostReportEntered(void);
FOUNDATION_EXPORT uint64_t HostCompletionCount(void);
FOUNDATION_EXPORT BOOL HostCallbackReturned(void);
FOUNDATION_EXPORT BOOL HostReportEnteredAtCallbackReturn(void);
FOUNDATION_EXPORT NSTimeInterval HostCallbackElapsedSeconds(void);
FOUNDATION_EXPORT NSTimeInterval HostReportEntryElapsedSeconds(void);
FOUNDATION_EXPORT BOOL HostCallbackWasMainThread(void);
FOUNDATION_EXPORT BOOL HostReturnedDuringMainStall(void);
FOUNDATION_EXPORT BOOL HostDriveHandshakeSucceeded(void);
/// Atomic host observations; report entry denotes the fixture seam, never LCK.
FOUNDATION_EXPORT NSString *HostMetricsJSON(void);

NS_ASSUME_NONNULL_END
