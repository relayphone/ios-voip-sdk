#if defined(SDK_DEVICE_QA) && SDK_DEVICE_QA
#import "include/VSDeviceQADiagnostics.h"
#import <time.h>

static VSDeviceQAObserver observer;
static NSLock *observerLock(void) {
  static NSLock *lock;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ lock = [NSLock new]; });
  return lock;
}
void VSDeviceQASetObserver(VSDeviceQAObserver value) {
  NSLock *lock = observerLock();
  [lock lock]; observer = [value copy]; [lock unlock];
}
uint64_t VSDeviceQANanoseconds(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

static NSString *const deliveryKey = @"VoIPSDK.DeviceQA.CurrentDelivery";
NSUUID *VSDeviceQACurrentDeliveryID(void) {
  return [NSThread.currentThread.threadDictionary objectForKey:deliveryKey];
}
void VSDeviceQAWithDelivery(NSUUID *deliveryID, dispatch_block_t operation) {
  NSMutableDictionary *values = NSThread.currentThread.threadDictionary;
  id previous = values[deliveryKey];
  values[deliveryKey] = deliveryID;
  @try { operation(); }
  @finally {
    if (previous) values[deliveryKey] = previous;
    else [values removeObjectForKey:deliveryKey];
  }
}
void VSDeviceQAEmitPushEvent(NSString *event, NSUUID *deliveryID, NSString *api, BOOL mustReport) {
  uint64_t nanoseconds = VSDeviceQANanoseconds();
  BOOL mainThread = NSThread.isMainThread;
  NSLock *lock = observerLock();
  [lock lock]; VSDeviceQAObserver callback = observer; [lock unlock];
  if (callback) callback(event, deliveryID, api, mustReport, nanoseconds, mainThread);
}
dispatch_block_t VSDeviceQAObserveCompletion(NSUUID *deliveryID, NSString *api, BOOL mustReport,
                                            dispatch_block_t completion) {
  return ^{
    VSDeviceQAEmitPushEvent(@"push.completion", deliveryID, api, mustReport);
    completion();
  };
}
#endif
