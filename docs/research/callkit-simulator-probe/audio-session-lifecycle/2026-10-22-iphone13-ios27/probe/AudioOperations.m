#import "AudioOperations.h"
#import <AVFAudio/AVFAudio.h>
#import "VSAudioSessionQueue.h"
#include <stdatomic.h>
#include <string.h>

static _Atomic(uint64_t) frames, callbacks;
@interface AudioOperations : NSObject
@property(nonatomic, strong) AVAudioEngine *engine;
@property(nonatomic, strong) AVAudioSourceNode *source;
@property(nonatomic) BOOL mayNeedDeactivation;
@end
@implementation AudioOperations
- (BOOL)startOutput:(NSError **)error {
  NSAssert(VSAudioSessionIsOnQueue(), @"Audio queue required");
  if (!self.engine) {
    self.engine = [AVAudioEngine new];
    self.source = [[AVAudioSourceNode alloc] initWithRenderBlock:^OSStatus(BOOL *silence,
        const AudioTimeStamp *timestamp, AVAudioFrameCount count, AudioBufferList *data) {
      *silence = YES;
      for (UInt32 index = 0; index < data->mNumberBuffers; index++)
        memset(data->mBuffers[index].mData, 0, data->mBuffers[index].mDataByteSize);
      atomic_fetch_add_explicit(&frames, count, memory_order_relaxed);
      atomic_fetch_add_explicit(&callbacks, 1, memory_order_relaxed);
      return 0;
    }];
    [self.engine attachNode:self.source];
    AVAudioFormat *format = [self.engine.outputNode inputFormatForBus:0];
    if (format.sampleRate <= 0 || format.channelCount == 0) {
      if (error) *error = [NSError errorWithDomain:@"AudioLifecycleProbe" code:1 userInfo:nil];
      return NO;
    }
    if (@available(iOS 27.0, *)) {
      if (![self.engine connect:self.source to:self.engine.mainMixerNode format:format error:error]) return NO;
    } else return NO;
  }
  return [self.engine startAndReturnError:error];
}
@end
static AudioOperations *Owner(void) {
  static AudioOperations *owner; static dispatch_once_t once;
  dispatch_once(&once, ^{ owner = [AudioOperations new]; }); return owner;
}
static ProbeAudioValues Snapshot(void) {
  NSCAssert(VSAudioSessionIsOnQueue(), @"Audio queue required");
  ProbeAudioValues value = {0};
  value.engineRunning = Owner().engine.isRunning;
  value.renderFrames = atomic_load_explicit(&frames, memory_order_relaxed);
  value.renderCallbacks = atomic_load_explicit(&callbacks, memory_order_relaxed);
  return value;
}
static void Deliver(ProbeAudioValues value, NSString *sessionDomain, NSString *ioDomain, ProbeAudioCompletion completion) {
  dispatch_async(dispatch_get_main_queue(), ^{ completion(value, sessionDomain, ioDomain); });
}
void ProbeAudioRun(int32_t operation, bool silentOutput, ProbeAudioCompletion completion) {
  dispatch_async(VSAudioSessionGetQueue(), ^{
    BOOL callMain = NSThread.isMainThread, callQueue = VSAudioSessionIsOnQueue();
    if (operation % 2 == 1) [Owner().engine stop]; // Always before requesting deactivation.
    if (operation % 2 == 0) Owner().mayNeedDeactivation = YES;
    void (^settled)(BOOL, NSError *) = ^(BOOL success, NSError *error) {
      BOOL completionMain = NSThread.isMainThread;
      NSString *domain = [error.domain copy] ?: @""; NSInteger code = error.code;
      dispatch_async(VSAudioSessionGetQueue(), ^{
        if (operation % 2 == 1 && success && !code) Owner().mayNeedDeactivation = NO;
        NSError *ioError = nil; BOOL ioSuccess = YES;
        if (success && !code && silentOutput && operation % 2 == 0) ioSuccess = [Owner() startOutput:&ioError];
        ProbeAudioValues value = Snapshot();
        value.sessionAttempted = true; value.sessionSuccess = success; value.sessionErrorCode = code;
        value.ioSuccess = ioSuccess; value.ioErrorCode = ioError.code;
        value.callMain = callMain; value.callAudioQueue = callQueue; value.completionMain = completionMain;
        Deliver(value, domain, ioError.domain ?: @"", completion);
      });
    };
    AVAudioSession *session = AVAudioSession.sharedInstance;
    if (operation < 2) {
      NSError *error = nil;
      BOOL success = [session setActive:operation == 0 withOptions:operation == 0 ? 0 : AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:&error];
      settled(success, error);
    } else if (@available(iOS 27.0, *)) {
      if (operation == 2) [session activateWithOptions:AVAudioSessionActivationOptionNone completionHandler:settled];
      else [session deactivateWithOptions:AVAudioSessionDeactivationOptionNotifyOthersOnDeactivation completionHandler:settled];
    } else settled(NO, [NSError errorWithDomain:@"AudioLifecycleProbe" code:2 userInfo:nil]);
  });
}
void ProbeAudioSnapshot(ProbeAudioCompletion completion) {
  dispatch_async(VSAudioSessionGetQueue(), ^{ Deliver(Snapshot(), @"", @"", completion); });
}
void ProbeAudioCleanup(ProbeAudioCompletion completion) {
  dispatch_async(VSAudioSessionGetQueue(), ^{
    [Owner().engine stop];
    BOOL requested = Owner().mayNeedDeactivation;
    NSError *error = nil; BOOL success = YES;
    if (requested) success = [AVAudioSession.sharedInstance setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:&error];
    if (success) Owner().mayNeedDeactivation = NO;
    ProbeAudioValues value = Snapshot(); value.cleanupDeactivationRequested = requested;
    value.sessionAttempted = requested; value.sessionSuccess = success; value.sessionErrorCode = error.code;
    value.callMain = NSThread.isMainThread; value.callAudioQueue = VSAudioSessionIsOnQueue();
    Deliver(value, error.domain ?: @"", @"", completion);
  });
}
