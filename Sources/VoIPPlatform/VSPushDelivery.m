#import "include/VSPushDelivery.h"

// Only the native owner and host controls use these injectable internal bounds.
// No environment setting changes the shipping watchdog or callback wait.
@interface VSPushDelivery ()
- (instancetype)initWithCompletion:(dispatch_block_t)completion
                         retaining:(id)receiver
                 completionTimeout:(NSTimeInterval)timeout;
- (BOOL)waitForSettlement:(NSTimeInterval)timeout;
- (void)completeWithSettlement:(BOOL)settled;
@end

static dispatch_queue_t completionQueue(void) {
  static dispatch_queue_t queue;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    queue = dispatch_queue_create("dev.iosvoipsdk.push-completion", DISPATCH_QUEUE_CONCURRENT);
  });
  return queue;
}

static dispatch_queue_t watchdogQueue(void) {
  static dispatch_queue_t queue;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    queue = dispatch_queue_create("dev.iosvoipsdk.push-watchdog", DISPATCH_QUEUE_SERIAL);
  });
  return queue;
}

@implementation VSPushDelivery {
  NSLock *_lock;
  dispatch_semaphore_t _settlement;
  dispatch_source_t _watchdog;
  dispatch_block_t _completion;
  id _receiver;
  BOOL _settled;
}

- (instancetype)initWithCompletion:(dispatch_block_t)completion
                         retaining:(id)receiver
                 completionTimeout:(NSTimeInterval)timeout {
  if ((self = [super init])) {
    _lock = [NSLock new];
    _settlement = dispatch_semaphore_create(0);
    _completion = [completion copy];
    _receiver = receiver;
    _watchdog = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, watchdogQueue());
    dispatch_source_set_timer(_watchdog,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), DISPATCH_TIME_FOREVER, 0);
    dispatch_source_set_event_handler(_watchdog, ^{ [self completeWithSettlement:NO]; });
    dispatch_resume(_watchdog);
  }
  return self;
}

- (void)finish { [self completeWithSettlement:YES]; }

- (BOOL)waitForSettlement:(NSTimeInterval)timeout {
  if ([NSThread isMainThread]) {
    NSLog(@"[VoIPSDK] Push report settlement must never be awaited on main.");
    return NO;
  }
  [_lock lock];
  BOOL settled = _settled;
  [_lock unlock];
  if (settled) return YES;
  dispatch_semaphore_wait(_settlement,
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)));
  [_lock lock];
  settled = _settled;
  [_lock unlock];
  return settled;
}

- (void)completeWithSettlement:(BOOL)settled {
  [_lock lock];
  BOOL acknowledge = settled && !_settled;
  if (settled) _settled = YES;
  dispatch_block_t completion = _completion;
  id receiver = _receiver;
  dispatch_source_t watchdog = _watchdog;
  _completion = nil;
  _receiver = nil;
  _watchdog = nil;
  [_lock unlock];

  if (acknowledge) dispatch_semaphore_signal(_settlement);
  if (watchdog) {
    dispatch_source_set_event_handler(watchdog, nil);
    dispatch_source_cancel(watchdog);
  }
  if (!completion) return;
  if (!settled)
    NSLog(@"[VoIPSDK] Push report settlement exceeded the completion watchdog.");
  dispatch_async(completionQueue(), ^{
    // Keep the native receiver alive until the system completion has returned.
    id __attribute__((objc_precise_lifetime)) retainedReceiver = receiver;
    completion();
    (void)retainedReceiver;
  });
}
@end
