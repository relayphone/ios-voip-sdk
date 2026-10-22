#import "HostSupport.h"
int main(void) { @autoreleasepool {
  CHECK(NSClassFromString(@"RTCAudioSession") == Nil);
  VSSelectedMediaBinding *binding = [VSSelectedMediaBinding new];
  AVAudioSession *audio = [AVAudioSession new];
  completeOperation(^(VSMediaCompletion completion) { [binding prepareWithCompletion:completion]; }, 1);
  [binding setSystemAudioAuthorization:YES];
  completeOperation(^(VSMediaCompletion completion) { [binding activate:audio completion:completion]; }, 1);
  completeOperation(^(VSMediaCompletion completion) { [binding deactivate:audio completion:completion]; }, 1);
  puts("passed: absent optional RTCAudioSession links and returns explicit adapter-unavailable errors");
} return 0; }
