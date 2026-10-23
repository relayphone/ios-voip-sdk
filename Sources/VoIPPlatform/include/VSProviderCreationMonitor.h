#import <Foundation/Foundation.h>
#import <TargetConditionals.h>

NS_ASSUME_NONNULL_BEGIN
#if DEBUG || VSSDK_ENABLE_PROVIDER_DIAGNOSTICS || (TARGET_OS_IOS && TARGET_OS_SIMULATOR)
/// A diagnostic aid for D13, not a provider backend or a manager factory.
/// Diagnostics require Debug or explicit build opt-in. Availability depends on
/// an already-loaded system provider class; this never loads a framework.
NS_SWIFT_UI_ACTOR
NS_SWIFT_NAME(ProviderCreationMonitor)
@interface VSProviderCreationMonitor : NSObject
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
+ (void)installWithDiagnosticHandler:(void (^)(NSString *message))diagnosticHandler
    NS_SWIFT_NAME(install(diagnosticHandler:));
/// Reports actual newly observed foreign providers, never coverage diagnostics.
+ (void)setOwnershipConflictHandler:(void (^ _Nullable)(void))handler;
+ (void)beginOwnedManagerCreation;
+ (void)endOwnedManagerCreation;
#if TARGET_OS_IOS && TARGET_OS_SIMULATOR
/// SDK-internal preparation after successful runtime activation, before install.
/// The source observes completed initializers without replacing their IMPs.
+ (void)prepareSimulatorProviderCreationSource:(BOOL (^)(void (^observer)(id provider)))registerObserver;
#endif
@end
#endif
NS_ASSUME_NONNULL_END
