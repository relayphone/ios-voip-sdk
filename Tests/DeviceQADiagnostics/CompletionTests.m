#import "Bridge.h"
#import "../../Sources/VoIPPlatform/VSCompletionOnce.h"

BOOL QAContextRestoresAfterException(NSUUID *outer, NSUUID *inner) {
  __block BOOL restored = NO;
  VSDeviceQAWithDelivery(outer, ^{
    @try {
      VSDeviceQAWithDelivery(inner, ^{ @throw [NSException exceptionWithName:@"SyntheticQA" reason:nil userInfo:nil]; });
    } @catch (NSException *exception) {
      restored = [VSDeviceQACurrentDeliveryID() isEqual:outer];
    }
  });
  return restored && VSDeviceQACurrentDeliveryID() == nil;
}

void QAExerciseCompletionOnce(NSUUID *deliveryID, void (^checked)(NSInteger)) {
  __block NSInteger originals = 0;
  __block VSCompletionOnce *once;
  dispatch_block_t observed = VSDeviceQAObserveCompletion(deliveryID, @"metadata", YES, ^{
    originals++;
    [once finish]; // Reentrant settlement must also leave the original completion consumed.
  });
  once = [[VSCompletionOnce alloc] initWithCompletion:observed retaining:[NSObject new]];
  [once finish];
  [once finish];
  dispatch_async(dispatch_get_main_queue(), ^{
    checked(originals);
    once = nil;
  });
}
