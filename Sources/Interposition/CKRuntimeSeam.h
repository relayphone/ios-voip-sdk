#pragma once
#import "include/CKRuntimeBridge.h"

// Internal simulator journal instrumentation, excluded from the public module.
#if TARGET_OS_SIMULATOR && TARGET_OS_IOS
NS_ASSUME_NONNULL_BEGIN
void CKSimEmit(NSString *event, NSDictionary *fields);
NS_ASSUME_NONNULL_END
#endif
