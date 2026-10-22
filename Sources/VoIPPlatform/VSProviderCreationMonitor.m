#import "include/VSProviderCreationMonitor.h"
#import "VSProviderMonitorInternal.h"
#import <TargetConditionals.h>

#if DEBUG && (TARGET_OS_IOS || TARGET_OS_WATCH)
#import <CallKit/CXProvider.h>
#endif

#if DEBUG && TARGET_OS_IOS && TARGET_OS_SIMULATOR
static BOOL (^simulatorProviderCreationSource)(void (^)(id));
#endif

@implementation VSProviderCreationMonitor
+ (void)installWithDiagnosticHandler:(void (^)(NSString *))diagnosticHandler {
#if DEBUG && (TARGET_OS_IOS || TARGET_OS_WATCH)
  #if TARGET_OS_IOS && TARGET_OS_SIMULATOR
  if (simulatorProviderCreationSource) {
    VSProviderMonitorInstallWithSource(CXProvider.class, diagnosticHandler, simulatorProviderCreationSource);
    return;
  }
  #endif
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
#if TARGET_OS_IOS && TARGET_OS_SIMULATOR
+ (void)prepareSimulatorProviderCreationSource:(BOOL (^)(void (^)(id)))registerObserver {
  #if DEBUG
  // Activation and monitor installation are both SDK launch work on main.
  if ([NSThread isMainThread] && !simulatorProviderCreationSource)
    simulatorProviderCreationSource = [registerObserver copy];
  #endif
}
#endif
@end
