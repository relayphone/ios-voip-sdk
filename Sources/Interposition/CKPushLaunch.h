#pragma once
#include <TargetConditionals.h>
#if (TARGET_OS_SIMULATOR && TARGET_OS_IOS) || CKSIM_PUSH_LAUNCH_HOST_TEST
#import <Foundation/Foundation.h>
#include <sys/types.h>
// Private runtime transport. The caller supplies its own fixed Documents path,
// current run/bundle, clock and uid; none are read from an incoming payload.
NSDictionary * _Nullable CKSimConsumeLaunchPush(NSString * _Nonnull directory, NSString * _Nonnull runID,
    NSString * _Nonnull bundleID, NSTimeInterval now, uid_t owner, NSString * _Nullable * _Nullable reason);
#endif
