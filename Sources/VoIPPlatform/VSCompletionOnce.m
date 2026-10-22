#import "VSCompletionOnce.h"

@implementation VSCompletionOnce {
  NSLock *_lock;
  dispatch_block_t _completion;
  id _receiver;
}
- (instancetype)initWithCompletion:(dispatch_block_t)completion retaining:(id)receiver {
  if ((self = [super init])) {
    _lock = [NSLock new];
    _completion = [completion copy];
    _receiver = receiver;
  }
  return self;
}
- (void)finish {
  [_lock lock];
  dispatch_block_t completion = _completion;
  id receiver = _receiver;
  _completion = nil;
  _receiver = nil;
  [_lock unlock];
  if (!completion) return;
  dispatch_block_t finish = ^{
    // Keep the native receiver alive through the actual system completion.
    (void)[receiver class];
    completion();
  };
  if ([NSThread isMainThread]) finish();
  else dispatch_async(dispatch_get_main_queue(), finish);
}
@end
