#import <Foundation/Foundation.h>
#include <stdbool.h>
#include <stdint.h>
NS_ASSUME_NONNULL_BEGIN
typedef struct {
  bool sessionAttempted, sessionSuccess, ioSuccess, callMain, callAudioQueue, completionMain;
  bool engineRunning, cleanupDeactivationRequested;
  int64_t sessionErrorCode, ioErrorCode;
  uint64_t renderFrames, renderCallbacks;
} ProbeAudioValues;
/// Every callback is delivered on main. Values contain no framework objects.
typedef void (^ProbeAudioCompletion)(ProbeAudioValues values, NSString *sessionErrorDomain, NSString *ioErrorDomain);
FOUNDATION_EXPORT void ProbeAudioRun(int32_t operation, bool silentOutput, ProbeAudioCompletion completion);
FOUNDATION_EXPORT void ProbeAudioSnapshot(ProbeAudioCompletion completion);
FOUNDATION_EXPORT void ProbeAudioCleanup(ProbeAudioCompletion completion);
NS_ASSUME_NONNULL_END
