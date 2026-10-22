#import "include/VSProviderCreationMonitor.h"
#import "VSProviderMonitorInternal.h"
#import <TargetConditionals.h>

#if DEBUG && (TARGET_OS_IOS || TARGET_OS_WATCH)
#import <CallKit/CXProvider.h>
#endif

@implementation VSProviderCreationMonitor
+ (void)installWithDiagnosticHandler:(void (^)(NSString *))diagnosticHandler {
#if DEBUG && (TARGET_OS_IOS || TARGET_OS_WATCH)
  VSProviderMonitorInstall(CXProvider.class, diagnosticHandler);
#endif
}
+ (void)beginOwnedManagerCreation {
#if DEBUG && (TARGET_OS_IOS || TARGET_OS_WATCH)
  VSProviderMonitorBeginOwnedCreation();
#endif
}
+ (void)endOwnedManagerCreation {
#if DEBUG && (TARGET_OS_IOS || TARGET_OS_WATCH)
  VSProviderMonitorEndOwnedCreation();
#endif
}
@end
