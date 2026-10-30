#import "VSPushCompletion.h"
#import <os/lock.h>
#import <os/log.h>

static dispatch_queue_t watchdogQueue(void) {
  static dispatch_queue_t queue;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    queue = dispatch_queue_create("VoIPPushKit.PushCompletion.watchdog", DISPATCH_QUEUE_SERIAL);
  });
  return queue;
}

@implementation VSPushCompletion {
  os_unfair_lock _lock;
  dispatch_block_t _completion;
  dispatch_source_t _watchdog;
}

- (instancetype)initWithCompletion:(dispatch_block_t)completion watchdog:(NSTimeInterval)watchdog {
  if ((self = [super init])) {
    _lock = OS_UNFAIR_LOCK_INIT;
    _completion = [completion copy];
    _watchdog = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, watchdogQueue());
    dispatch_source_set_timer(_watchdog,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(watchdog * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER, 0);
    // The handler keeps this object alive until the push finishes or the watchdog fires.
    dispatch_source_set_event_handler(_watchdog, ^{
      if ([self complete]) {
        os_log_error(OS_LOG_DEFAULT, "VoIPPushKit: a VoIP push wasn't finished before the watchdog");
      }
    });
    dispatch_resume(_watchdog);
  }
  return self;
}

- (void)finish {
  [self complete];
}

/// Calls the completion handler outside the lock, and returns whether this call ran it.
- (BOOL)complete {
  os_unfair_lock_lock(&_lock);
  dispatch_block_t completion = _completion;
  dispatch_source_t watchdog = _watchdog;
  _completion = nil;
  _watchdog = nil;
  os_unfair_lock_unlock(&_lock);
  if (watchdog) {
    dispatch_source_set_event_handler(watchdog, nil);
    dispatch_source_cancel(watchdog);
  }
  if (!completion) return NO;
  completion();
  return YES;
}
@end
