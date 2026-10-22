#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

// Declaration-only public RTCAudioSession surface. Implementation belongs to
// the app's existing WebRTC framework; this SDK supplies no WebRTC dependency.
// Contract: sdk/objc/components/audio/RTCAudioSession.h, Jitsi release155.
@protocol VSMediaRTCAudioSession <NSObject>
@property(nonatomic) BOOL useManualAudio;
@property(nonatomic) BOOL isAudioEnabled;
- (void)audioSessionDidActivate:(AVAudioSession *)session;
- (void)audioSessionDidDeactivate:(AVAudioSession *)session;
@end

@protocol VSMediaRTCAudioSessionFactory <NSObject>
+ (id<VSMediaRTCAudioSession>)sharedInstance;
@end
