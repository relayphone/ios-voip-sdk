#if defined(SDK_DEVICE_QA) && SDK_DEVICE_QA
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
typedef void (^VSDeviceQAObserver)(NSString *event, NSUUID *deliveryID, NSString *api,
                                  BOOL mustReport, uint64_t nanoseconds, BOOL mainThread);
FOUNDATION_EXPORT void VSDeviceQASetObserver(VSDeviceQAObserver _Nullable observer);
FOUNDATION_EXPORT uint64_t VSDeviceQANanoseconds(void);
FOUNDATION_EXPORT NSUUID * _Nullable VSDeviceQACurrentDeliveryID(void);
FOUNDATION_EXPORT void VSDeviceQAWithDelivery(NSUUID *deliveryID, dispatch_block_t operation);
FOUNDATION_EXPORT void VSDeviceQAEmitPushEvent(NSString *event, NSUUID *deliveryID,
                                             NSString *api, BOOL mustReport);
FOUNDATION_EXPORT dispatch_block_t VSDeviceQAObserveCompletion(NSUUID *deliveryID,
                                                               NSString *api, BOOL mustReport,
                                                               dispatch_block_t completion);
NS_ASSUME_NONNULL_END
#endif
