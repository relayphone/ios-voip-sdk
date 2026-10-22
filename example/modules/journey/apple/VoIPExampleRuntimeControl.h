#import <TargetConditionals.h>
#if TARGET_OS_IOS && TARGET_OS_SIMULATOR
#import <Foundation/Foundation.h>
// Example-only instrumentation; absent from the published SDK public headers.
FOUNDATION_EXPORT void CKSimInjectPush(NSDictionary * _Nonnull payload, BOOL mustReport, NSString * _Nonnull identifier);
#endif
