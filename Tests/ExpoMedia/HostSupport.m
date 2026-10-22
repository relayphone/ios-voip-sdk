#import "HostSupport.h"
#import <stdarg.h>
@implementation AVAudioSession
@end
static dispatch_semaphore_t diagnostic;
void expectDiagnostic(dispatch_semaphore_t semaphore) { @synchronized (AVAudioSession.class) { diagnostic = semaphore; } }
void VSHostMediaLog(NSString *format, ...) {
  va_list args; va_start(args, format);
  NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
  va_end(args);
  fprintf(stderr, "%s\n", message.UTF8String);
  @synchronized (AVAudioSession.class) {
    if ([message containsString:@"selected LiveKit React Native audio module is unavailable"] && diagnostic) {
      dispatch_semaphore_signal(diagnostic);
      diagnostic = nil;
    }
  }
}
void waitFor(dispatch_semaphore_t semaphore) {
  CHECK(dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0);
}
void completeOperation(void (^operation)(VSMediaCompletion), NSInteger expectedError) {
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  operation(^(NSError *error) {
    CHECK(!NSThread.isMainThread);
    CHECK((error ? error.code : 0) == expectedError);
    if (error) CHECK([error.domain isEqual:@"VoIPSDK.MediaAdapter"]);
    dispatch_semaphore_signal(done);
  });
  waitFor(done);
}
