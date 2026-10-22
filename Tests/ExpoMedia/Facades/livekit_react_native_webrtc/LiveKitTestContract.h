// Host-only subset of the selected LiveKit public ObjC contract.
#import <Foundation/Foundation.h>
typedef struct {
  BOOL isInputAvailable;
  BOOL isOutputAvailable;
} LKRTCAudioEngineAvailability;
@interface LKRTCAudioDeviceModule : NSObject
@property(nonatomic, readonly) LKRTCAudioEngineAvailability engineAvailability;
- (NSInteger)setEngineAvailability:(LKRTCAudioEngineAvailability)availability;
@end
@interface WebRTCModule : NSObject
@property(nonatomic, readonly) LKRTCAudioDeviceModule *audioDeviceModule;
@end
