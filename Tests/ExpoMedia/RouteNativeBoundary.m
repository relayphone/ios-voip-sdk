#import "RouteNativeBoundary.h"
#import "WebRTCAudioContract.h"
#import "VSAudioSessionLifecycleObserver.h"

// Inert framework boundaries: production Core, adapter, native queue and route
// binding run unchanged; no system session or media engine is constructed.
@implementation AVAudioSession @end
@implementation VSAudioSessionLifecycleObserver
- (instancetype)initWithHandler:(VSAudioSessionLifecycleHandler)handler { return [super init]; }
- (void)invalidate {}
@end

@interface RTCAudioSession : NSObject <VSMediaRTCAudioSession, VSMediaRTCAudioSessionFactory>
+ (instancetype)sharedInstance;
@property(nonatomic) BOOL useManualAudio;
@property(nonatomic) BOOL isAudioEnabled;
@property(nonatomic) BOOL configurationLocked;
@property(nonatomic) NSUInteger gateMutations;
@property(nonatomic) NSUInteger locks;
@end
@implementation RTCAudioSession
+ (instancetype)sharedInstance {
  static RTCAudioSession *value; static dispatch_once_t once;
  dispatch_once(&once, ^{ value = [self new]; }); return value;
}
- (void)lockForConfiguration {
  NSCAssert(VSAudioSessionIsOnQueue() && !NSThread.isMainThread && !_configurationLocked, @"route lock queue/scope");
  _configurationLocked = YES; _locks++;
}
- (void)unlockForConfiguration {
  NSCAssert(VSAudioSessionIsOnQueue() && _configurationLocked, @"route unlock scope");
  _configurationLocked = NO;
}
- (void)setUseManualAudio:(BOOL)value { _useManualAudio = value; _gateMutations++; }
- (void)setIsAudioEnabled:(BOOL)value { _isAudioEnabled = value; _gateMutations++; }
- (void)audioSessionDidActivate:(AVAudioSession *)session { NSCAssert(NO, @"Routes cannot activate media"); }
- (void)audioSessionDidDeactivate:(AVAudioSession *)session { NSCAssert(NO, @"Routes cannot deactivate media"); }
@end
BOOL VSRouteConfigurationLocked(void) { return [RTCAudioSession sharedInstance].configurationLocked; }
NSUInteger VSRouteGateMutationCount(void) { return [RTCAudioSession sharedInstance].gateMutations; }
NSUInteger VSRouteLockCount(void) { return [RTCAudioSession sharedInstance].locks; }
