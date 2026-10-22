#import <Foundation/Foundation.h>

#if DEBUG
NS_ASSUME_NONNULL_BEGIN
BOOL VSProviderMonitorInstall(Class providerClass, void (^diagnostic)(NSString *));
void VSProviderMonitorBeginOwnedCreation(void);
void VSProviderMonitorEndOwnedCreation(void);
NS_ASSUME_NONNULL_END
#endif
