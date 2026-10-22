#import "HostSupport.h"
#import <React/RCTBridgeModule.h>
@import livekit_react_native_webrtc;

static NSUInteger deviceConstructions;
@interface LKRTCAudioDeviceModule (Host)
- (NSArray<NSNumber *> *)events;
- (void)observeAvailability:(BOOL)active semaphore:(dispatch_semaphore_t)semaphore;
@end
@implementation LKRTCAudioDeviceModule {
  LKRTCAudioEngineAvailability _availability;
  NSMutableArray<NSNumber *> *_events;
  dispatch_semaphore_t _observed;
  BOOL _expected;
}
- (instancetype)init { if ((self = [super init])) { deviceConstructions++; _events = [NSMutableArray new]; _availability.isInputAvailable = YES; _availability.isOutputAvailable = YES; } return self; }
- (NSInteger)setEngineAvailability:(LKRTCAudioEngineAvailability)value {
  CHECK(!NSThread.isMainThread && value.isInputAvailable == value.isOutputAvailable);
  @synchronized(self) {
    _availability = value; [_events addObject:@(value.isInputAvailable)];
    if (_observed && value.isInputAvailable == _expected) { dispatch_semaphore_signal(_observed); _observed = nil; }
  }
  return 0;
}
- (LKRTCAudioEngineAvailability)engineAvailability { @synchronized(self) { return _availability; } }
- (NSArray<NSNumber *> *)events { @synchronized(self) { return [_events copy]; } }
- (void)observeAvailability:(BOOL)active semaphore:(dispatch_semaphore_t)semaphore { @synchronized(self) { _expected = active; _observed = semaphore; } }
@end
static NSUInteger moduleConstructions;
@interface WebRTCModule (Host)
- (instancetype)initWithDevice:(LKRTCAudioDeviceModule *)device;
@end
@implementation WebRTCModule {
  LKRTCAudioDeviceModule *_testDevice;
}
- (instancetype)initWithDevice:(LKRTCAudioDeviceModule *)device { if ((self = [super init])) { moduleConstructions++; _testDevice = device; } return self; }
- (LKRTCAudioDeviceModule *)audioDeviceModule { return _testDevice; }
@end
@implementation RCTModuleRegistry
- (id)moduleForClass:(Class)moduleClass { return nil; }
@end
@interface ExistingRegistry : RCTModuleRegistry
- (instancetype)initWithModule:(WebRTCModule *)module;
@property(nonatomic, readonly) NSUInteger lookupCount;
@end
@implementation ExistingRegistry {
  WebRTCModule *_module;
  NSUInteger _lookups;
}
- (instancetype)initWithModule:(WebRTCModule *)module { if ((self = [super init])) _module = module; return self; }
- (id)moduleForClass:(Class)moduleClass { CHECK(moduleClass == WebRTCModule.class); @synchronized(self) { _lookups++; return _module; } }
- (NSUInteger)lookupCount { @synchronized(self) { return _lookups; } }
@end
// Private production attachment methods are declared only in this host control.
@interface VSSelectedMediaBinding (HostRegistryContract)
- (uint64_t)beginOwner;
- (void)attach:(LKRTCAudioDeviceModule *)device owner:(uint64_t)owner;
- (void)invalidateOwner:(uint64_t)owner;
@end
@protocol HostRegistryLifecycle <NSObject>
@property(nonatomic, weak, readwrite) RCTModuleRegistry *moduleRegistry;
- (void)initialize;
- (void)invalidate;
@end
static id<HostRegistryLifecycle> helper(RCTModuleRegistry *registry) {
  Class cls = NSClassFromString(@"VoIPSDKMediaRegistry"); CHECK(cls);
  id<HostRegistryLifecycle> value = [cls new]; value.moduleRegistry = registry; return value;
}
static void flushActivation(VSSelectedMediaBinding *binding, AVAudioSession *audio) {
  completeOperation(^(VSMediaCompletion completion) { [binding activate:audio completion:completion]; }, 0);
}
int main(void) { @autoreleasepool {
  VSSelectedMediaBinding *binding = [VSSelectedMediaBinding sharedBinding];
  AVAudioSession *audio = [AVAudioSession new];
  completeOperation(^(VSMediaCompletion completion) { [binding prepareWithCompletion:completion]; }, 0);
  [binding setSystemAudioAuthorization:YES];
  completeOperation(^(VSMediaCompletion completion) { [binding activate:audio completion:completion]; }, 1);
  LKRTCAudioDeviceModule *first = [LKRTCAudioDeviceModule new];
  ExistingRegistry *firstRegistry = [[ExistingRegistry alloc] initWithModule:[[WebRTCModule alloc] initWithDevice:first]];
  id<HostRegistryLifecycle> old = helper(firstRegistry);
  dispatch_semaphore_t firstEnabled = dispatch_semaphore_create(0); [first observeAvailability:YES semaphore:firstEnabled];
  [old initialize]; waitFor(firstEnabled);
  CHECK(firstRegistry.lookupCount == 1 && moduleConstructions == 1 && deviceConstructions == 1);
  CHECK([first.events isEqual:@[@NO, @YES]]);
  LKRTCAudioDeviceModule *second = [LKRTCAudioDeviceModule new];
  ExistingRegistry *secondRegistry = [[ExistingRegistry alloc] initWithModule:[[WebRTCModule alloc] initWithDevice:second]];
  id<HostRegistryLifecycle> current = helper(secondRegistry);
  dispatch_semaphore_t secondEnabled = dispatch_semaphore_create(0); [second observeAvailability:YES semaphore:secondEnabled];
  [current initialize]; waitFor(secondEnabled);
  CHECK(moduleConstructions == 2 && deviceConstructions == 2 && secondRegistry.lookupCount == 1);
  CHECK([first.events.lastObject isEqual:@NO]);
  [old invalidate]; flushActivation(binding, audio);
  CHECK([second.events isEqual:@[@NO, @YES, @YES]]);
  // A delayed registry acquisition carries this owner token into attach. Drive
  // the exact production attachment path after a newer token already won.
  uint64_t staleOwner = [binding beginOwner];
  uint64_t latestOwner = [binding beginOwner];
  LKRTCAudioDeviceModule *stale = [LKRTCAudioDeviceModule new], *latest = [LKRTCAudioDeviceModule new];
  [binding attach:latest owner:latestOwner]; flushActivation(binding, audio);
  [binding attach:stale owner:staleOwner]; flushActivation(binding, audio);
  CHECK([stale.events isEqual:@[@NO]] && !stale.engineAvailability.isInputAvailable);
  CHECK([latest.events isEqual:@[@NO, @YES, @YES, @YES]]);
  [binding attach:latest owner:staleOwner]; flushActivation(binding, audio);
  CHECK([latest.events isEqual:@[@NO, @YES, @YES, @YES, @YES]]);
  [binding invalidateOwner:staleOwner]; flushActivation(binding, audio);
  CHECK([latest.events.lastObject isEqual:@YES]);
  dispatch_semaphore_t reset = dispatch_semaphore_create(0); [latest observeAvailability:NO semaphore:reset];
  [binding setSystemAudioAuthorization:NO]; waitFor(reset);
  CHECK([latest.events.lastObject isEqual:@NO]);
  uint64_t invalidatedOwner = [binding beginOwner];
  [binding invalidateOwner:invalidatedOwner];
  LKRTCAudioDeviceModule *orphan = [LKRTCAudioDeviceModule new];
  CHECK(orphan.engineAvailability.isInputAvailable);
  [binding attach:orphan owner:invalidatedOwner];
  completeOperation(^(VSMediaCompletion completion) { [binding prepareWithCompletion:completion]; }, 0);
  CHECK([orphan.events isEqual:@[@NO]] && !orphan.engineAvailability.isInputAvailable);
  dispatch_semaphore_t diagnostic = dispatch_semaphore_create(0); expectDiagnostic(diagnostic);
  id<HostRegistryLifecycle> missing = helper(nil); [missing initialize]; waitFor(diagnostic);
  [missing invalidate]; [current invalidate];
  puts("passed: existing registry/ADM binding, recorded authorization late-bind replay, off-main work, reload generation isolation, stale acquisition retirement/same-ADM preservation, invalidated-owner retirement, reset revocation, missing registry diagnostic");
} return 0; }
