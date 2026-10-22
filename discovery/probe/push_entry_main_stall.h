#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#import "../../Sources/VoIPPlatform/include/VSPushRegistryOwner.h"

#if TARGET_OS_IOS && TARGET_OS_SIMULATOR
NS_ASSUME_NONNULL_BEGIN
// Probe-only direct invocation of the real native callback body. This does not
// simulate an APNs delivery or use CKSimInjectPush's main-queue bookkeeping.
void CKProbeRunIncomingMainStall(VSPushRegistryOwner *owner, NSDictionary *payload);
NSString *CKProbeMainStallOwnerIdentity(void);
NSInteger CKProbeMainStallCompletionCount(void);
BOOL CKProbeMainStallCallbackReturned(void);
NS_ASSUME_NONNULL_END
#endif
