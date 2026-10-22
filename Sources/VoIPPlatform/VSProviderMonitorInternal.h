#import <Foundation/Foundation.h>

#if DEBUG
NS_ASSUME_NONNULL_BEGIN
BOOL VSProviderMonitorInstall(Class providerClass, void (^diagnostic)(NSString *));
BOOL VSProviderMonitorInstallWithSource(Class providerClass, void (^diagnostic)(NSString *),
    BOOL (^ _Nullable registerObserver)(void (^observer)(id provider)));
void VSProviderMonitorBeginOwnedCreation(void);
void VSProviderMonitorEndOwnedCreation(void);
NS_ASSUME_NONNULL_END
#endif
