#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "VSAudioSessionQueue.h"

NS_ASSUME_NONNULL_BEGIN
typedef void (^VSMediaCompletion)(NSError * _Nullable error);
typedef NSError * _Nullable (^VSMediaConfiguration)(void);

/// Implemented by exactly one selected backend. Operations complete off main.
@interface VSSelectedMediaBinding : NSObject
+ (instancetype)sharedBinding NS_SWIFT_NAME(shared());
- (void)setSystemAudioAuthorization:(BOOL)active;
- (void)prepareWithCheck:(VSMediaConfiguration)check configuration:(VSMediaConfiguration)configuration
              completion:(VSMediaCompletion)completion NS_SWIFT_NAME(prepare(check:configuration:completion:));
/// Runs only a synchronous route operation on the shared audio worker. It does
/// not prepare the backend or change media availability or session ownership.
- (void)configureAudioRoute:(VSMediaConfiguration)configuration completion:(VSMediaCompletion)completion
  NS_SWIFT_NAME(configureAudioRoute(_:completion:));
- (void)activate:(AVAudioSession *)session completion:(VSMediaCompletion)completion;
- (void)deactivate:(AVAudioSession *)session completion:(VSMediaCompletion)completion;
@end
NS_ASSUME_NONNULL_END
