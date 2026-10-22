#pragma once
#import "include/CKRuntimeBridge.h"

// Internal simulator instrumentation, excluded from the SDK public module.
#if TARGET_OS_SIMULATOR && TARGET_OS_IOS
NS_ASSUME_NONNULL_BEGIN
void CKSimInjectPush(NSDictionary *payload, BOOL mustReport, NSString *identifier);
void CKSimEmit(NSString *event, NSDictionary *fields);
NS_ASSUME_NONNULL_END
#endif
