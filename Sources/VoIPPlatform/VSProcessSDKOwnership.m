#import "include/VSProcessSDKOwnership.h"
#import <objc/runtime.h>

@implementation VSProcessSDKOwnership
+ (BOOL)claimModuleIdentity:(NSString *)moduleIdentity ownerToken:(NSString *)ownerToken {
  if (!moduleIdentity.length || !ownerToken.length) return NO;
  NSString *module = [moduleIdentity copy];
  NSString *token = [ownerToken copy];
  NSProcessInfo *process = NSProcessInfo.processInfo;
  // Selector identities are canonical across loaded images. A file-local
  // address or per-Objective-C-class static would give each linkage a new gate.
  const void *key = (const void *)NSSelectorFromString(@"dev.ziahamza.iosVoipSDK.processOwnership.v1");
  @synchronized (process) {
    NSDictionary *owner = objc_getAssociatedObject(process, key);
    if (owner) return [owner[@"module"] isEqualToString:module] && [owner[@"token"] isEqualToString:token];
    objc_setAssociatedObject(process, key, @{@"module":module, @"token":token}, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return YES;
  }
}
@end
