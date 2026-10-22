#import <Foundation/Foundation.h>

#if DEBUG || VSSDK_ENABLE_PROVIDER_DIAGNOSTICS
NS_ASSUME_NONNULL_BEGIN
BOOL VSProviderMonitorInstall(Class providerClass, void (^diagnostic)(NSString *));
BOOL VSProviderMonitorInstallWithSource(Class providerClass, void (^diagnostic)(NSString *),
    BOOL (^ _Nullable registerObserver)(void (^observer)(id provider)));
void VSProviderMonitorSetOwnershipConflictHandler(void (^ _Nullable handler)(void));
void VSProviderMonitorBeginOwnedCreation(void);
void VSProviderMonitorEndOwnedCreation(void);
NS_ASSUME_NONNULL_END
#endif
