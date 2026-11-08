#import <TargetConditionals.h>

#if VOIP_CONVERSATIONS_SIMULATOR && DEBUG && TARGET_OS_SIMULATOR && TARGET_OS_IOS
#import "CKRuntimeBridge.h"
#endif
