#import "../../Sources/VoIPPlatform/include/VSDeviceQADiagnostics.h"
#if defined(SDK_DEVICE_QA) && SDK_DEVICE_QA
BOOL QAContextRestoresAfterException(NSUUID *outer, NSUUID *inner);
void QAExerciseCompletionOnce(NSUUID *deliveryID, void (^checked)(NSInteger originalCount));
#endif
