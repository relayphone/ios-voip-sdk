#import "HostSupport.h"
#import "WebRTCAudioContract.h"
@interface RTCAudioSession : NSObject <VSMediaRTCAudioSession, VSMediaRTCAudioSessionFactory>
+ (instancetype)sharedInstance;
@property(nonatomic) BOOL useManualAudio;
@property(nonatomic) BOOL isAudioEnabled;
- (NSArray<NSString *> *)events;
- (void)blockActivation:(dispatch_semaphore_t)entered release:(dispatch_semaphore_t)release;
- (void)observeDisabled:(dispatch_semaphore_t)disabled;
@end
@implementation RTCAudioSession {
  BOOL _manual, _enabled;
  NSMutableArray<NSString *> *_events;
  dispatch_semaphore_t _entered, _release, _disabled;
}
+ (instancetype)sharedInstance { static RTCAudioSession *session; static dispatch_once_t once; dispatch_once(&once, ^{ session = [self new]; }); return session; }
- (instancetype)init { if ((self = [super init])) _events = [NSMutableArray new]; return self; }
- (BOOL)useManualAudio { @synchronized(self) { return _manual; } }
- (void)setUseManualAudio:(BOOL)value { CHECK(!NSThread.isMainThread); @synchronized(self) { _manual = value; [_events addObject:value ? @"manual:on" : @"manual:off"]; } }
- (BOOL)isAudioEnabled { @synchronized(self) { return _enabled; } }
- (void)setIsAudioEnabled:(BOOL)value {
  CHECK(!NSThread.isMainThread);
  @synchronized(self) {
    _enabled = value; [_events addObject:value ? @"enabled:on" : @"enabled:off"];
    if (!value && _disabled) { dispatch_semaphore_signal(_disabled); _disabled = nil; }
  }
}
- (void)audioSessionDidActivate:(AVAudioSession *)session {
  CHECK(!NSThread.isMainThread && session != nil);
  dispatch_semaphore_t entered, release;
  @synchronized(self) { [_events addObject:@"activate"]; entered = _entered; release = _release; _entered = nil; _release = nil; }
  if (entered) { dispatch_semaphore_signal(entered); waitFor(release); }
}
- (void)audioSessionDidDeactivate:(AVAudioSession *)session { CHECK(!NSThread.isMainThread && session != nil); @synchronized(self) { [_events addObject:@"deactivate"]; } }
- (NSArray<NSString *> *)events { @synchronized(self) { return [_events copy]; } }
- (void)blockActivation:(dispatch_semaphore_t)entered release:(dispatch_semaphore_t)release { @synchronized(self) { _entered = entered; _release = release; } }
- (void)observeDisabled:(dispatch_semaphore_t)disabled { @synchronized(self) { _disabled = disabled; } }
@end
int main(void) { @autoreleasepool {
  CHECK(NSThread.isMainThread);
  VSSelectedMediaBinding *binding = [VSSelectedMediaBinding new];
  RTCAudioSession *rtc = [RTCAudioSession sharedInstance]; AVAudioSession *audio = [AVAudioSession new];
  completeOperation(^(VSMediaCompletion completion) { [binding prepareWithCompletion:completion]; }, 0);
  CHECK(rtc.useManualAudio && !rtc.isAudioEnabled);
  CHECK([rtc.events isEqual:@[@"manual:on", @"enabled:off"]]);
  [binding setSystemAudioAuthorization:YES];
  completeOperation(^(VSMediaCompletion completion) { [binding activate:audio completion:completion]; }, 0);
  CHECK(rtc.isAudioEnabled && [rtc.events isEqual:@[@"manual:on", @"enabled:off", @"activate", @"enabled:on"]]);
  [binding setSystemAudioAuthorization:NO];
  completeOperation(^(VSMediaCompletion completion) { [binding deactivate:audio completion:completion]; }, 0);
  CHECK(!rtc.isAudioEnabled);
  CHECK([rtc.events[rtc.events.count - 2] isEqual:@"enabled:off"] && [rtc.events.lastObject isEqual:@"deactivate"]);
  dispatch_semaphore_t entered = dispatch_semaphore_create(0), release = dispatch_semaphore_create(0), completed = dispatch_semaphore_create(0);
  [rtc blockActivation:entered release:release]; [binding setSystemAudioAuthorization:YES];
  NSUInteger start = rtc.events.count;
  [binding activate:audio completion:^(NSError *error) { CHECK(!NSThread.isMainThread && !error); dispatch_semaphore_signal(completed); }];
  waitFor(entered); [binding setSystemAudioAuthorization:NO]; dispatch_semaphore_signal(release); waitFor(completed);
  CHECK(!rtc.isAudioEnabled);
  completeOperation(^(VSMediaCompletion completion) { [binding deactivate:audio completion:completion]; }, 0);
  NSArray *after = rtc.events;
  NSArray *late = [after subarrayWithRange:NSMakeRange(start, after.count - start)];
  CHECK(![late containsObject:@"enabled:on"]);
  [binding setSystemAudioAuthorization:YES];
  completeOperation(^(VSMediaCompletion completion) { [binding activate:audio completion:completion]; }, 0);
  dispatch_semaphore_t disabled = dispatch_semaphore_create(0); [rtc observeDisabled:disabled];
  [binding setSystemAudioAuthorization:NO]; waitFor(disabled);
  CHECK(!rtc.isAudioEnabled);
  NSArray *events = rtc.events;
  CHECK([[events filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF == 'activate'"]] count] == 3);
  CHECK([[events filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF == 'deactivate'"]] count] == 2);
  // The final reset revoked permission without fabricating a deactivation callback.
  puts("passed: WebRTC prepare/manual gate, callback order/balance, off-main work, withdrawn delayed activation, reset revocation");
} return 0; }
