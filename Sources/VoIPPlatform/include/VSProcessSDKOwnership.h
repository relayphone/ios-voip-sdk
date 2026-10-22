#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Process-wide linkage claim. The token is supplied by each linked Swift SDK,
/// so duplicate Objective-C class/symbol coalescing cannot merge their identity.
NS_SWIFT_NAME(SDKProcessOwnership)
@interface VSProcessSDKOwnership : NSObject
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
+ (BOOL)claimModuleIdentity:(NSString *)moduleIdentity ownerToken:(NSString *)ownerToken
    NS_SWIFT_NAME(claim(moduleIdentity:ownerToken:));
@end
NS_ASSUME_NONNULL_END
