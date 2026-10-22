#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN
typedef void (^VSMediaCompletion)(NSError * _Nullable error);

/// Implemented by exactly one selected backend. Operations complete off main.
@interface VSSelectedMediaBinding : NSObject
+ (instancetype)sharedBinding NS_SWIFT_NAME(shared());
- (void)setSystemAudioAuthorization:(BOOL)active;
- (void)prepareWithCompletion:(VSMediaCompletion)completion NS_SWIFT_NAME(prepare(completion:));
- (void)activate:(AVAudioSession *)session completion:(VSMediaCompletion)completion;
- (void)deactivate:(AVAudioSession *)session completion:(VSMediaCompletion)completion;
@end
NS_ASSUME_NONNULL_END
