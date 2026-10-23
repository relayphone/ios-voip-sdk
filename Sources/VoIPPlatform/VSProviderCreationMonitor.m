#import "include/VSProviderCreationMonitor.h"
#import "VSProviderMonitorInternal.h"
#import <TargetConditionals.h>

#if (DEBUG || VSSDK_ENABLE_PROVIDER_DIAGNOSTICS) && TARGET_OS_IOS && TARGET_OS_SIMULATOR
static BOOL (^simulatorProviderCreationSource)(void (^)(id));
#endif

#if DEBUG || VSSDK_ENABLE_PROVIDER_DIAGNOSTICS || (TARGET_OS_IOS && TARGET_OS_SIMULATOR)
@implementation VSProviderCreationMonitor
+ (void)installWithDiagnosticHandler:(void (^)(NSString *))diagnosticHandler {
#if (DEBUG || VSSDK_ENABLE_PROVIDER_DIAGNOSTICS) && (TARGET_OS_IOS || TARGET_OS_WATCH)
  // Do not load CallKit or add a linker dependency for diagnostics. Monitoring
  // is available only when the system has already made the provider class visible.
  Class providerClass = NSClassFromString(@"CXProvider");
  if (!providerClass) {
    diagnosticHandler(@"The system provider class is unavailable; creation monitoring is disabled.");
    return;
  }
  #if TARGET_OS_IOS && TARGET_OS_SIMULATOR
  if (simulatorProviderCreationSource) {
    VSProviderMonitorInstallWithSource(providerClass, diagnosticHandler, simulatorProviderCreationSource);
    return;
  }
  #endif
  VSProviderMonitorInstall(providerClass, diagnosticHandler);
#endif
}
+ (void)setOwnershipConflictHandler:(void (^)(void))handler {
#if (DEBUG || VSSDK_ENABLE_PROVIDER_DIAGNOSTICS) && (TARGET_OS_IOS || TARGET_OS_WATCH)
  VSProviderMonitorSetOwnershipConflictHandler(handler);
#endif
}
+ (void)beginOwnedManagerCreation {
#if (DEBUG || VSSDK_ENABLE_PROVIDER_DIAGNOSTICS) && (TARGET_OS_IOS || TARGET_OS_WATCH)
  VSProviderMonitorBeginOwnedCreation();
#endif
}
+ (void)endOwnedManagerCreation {
#if (DEBUG || VSSDK_ENABLE_PROVIDER_DIAGNOSTICS) && (TARGET_OS_IOS || TARGET_OS_WATCH)
  VSProviderMonitorEndOwnedCreation();
#endif
}
#if TARGET_OS_IOS && TARGET_OS_SIMULATOR
+ (void)prepareSimulatorProviderCreationSource:(BOOL (^)(void (^)(id)))registerObserver {
  #if DEBUG || VSSDK_ENABLE_PROVIDER_DIAGNOSTICS
  // Activation and monitor installation are both SDK launch work on main.
  if ([NSThread isMainThread] && !simulatorProviderCreationSource)
    simulatorProviderCreationSource = [registerObserver copy];
  #endif
}
#endif
@end
#endif
