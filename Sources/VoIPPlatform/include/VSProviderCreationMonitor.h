#import <Foundation/Foundation.h>
#import <TargetConditionals.h>

NS_ASSUME_NONNULL_BEGIN
/// A diagnostic aid for D13, not a provider backend or a manager factory.
/// Install after simulator activation, then bracket the sole manager's creation.
NS_SWIFT_UI_ACTOR
NS_SWIFT_NAME(ProviderCreationMonitor)
@interface VSProviderCreationMonitor : NSObject
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
+ (void)installWithDiagnosticHandler:(void (^)(NSString *message))diagnosticHandler
    NS_SWIFT_NAME(install(diagnosticHandler:));
+ (void)beginOwnedManagerCreation;
+ (void)endOwnedManagerCreation;
#if TARGET_OS_IOS && TARGET_OS_SIMULATOR
/// SDK-internal preparation after successful runtime activation, before install.
/// The source observes completed initializers without replacing their IMPs.
+ (void)prepareSimulatorProviderCreationSource:(BOOL (^)(void (^observer)(id provider)))registerObserver;
#endif
@end
NS_ASSUME_NONNULL_END
