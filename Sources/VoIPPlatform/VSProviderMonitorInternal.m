#import "VSProviderMonitorInternal.h"

#if DEBUG
#import <objc/runtime.h>

// Both entry points and saved IMP calls preserve Objective-C's +1 convention.
typedef id (*ProviderInitializer)(id __attribute__((ns_consumed)), SEL, id)
    __attribute__((ns_returns_retained));
typedef id (*ProviderAllocator)(Class, SEL, NSZone *) __attribute__((ns_returns_retained));

typedef struct VSInitializerFrame {
  void *receiver;
  Class owner;
  struct VSInitializerFrame *previous;
} VSInitializerFrame;
static _Thread_local VSInitializerFrame *currentFrame;
static NSLock *monitorLock;
static Class monitoredClass;
static NSMutableDictionary<NSValue *, NSValue *> *initializers;
static NSHashTable *observedProviders;
static IMP originalAllocator;
static void (^diagnosticHandler)(NSString *);
static BOOL monitoring;
static BOOL ownedCreation;
static NSUInteger ownedProviderCount;

static void diagnose(NSString *message) {
  void (^handler)(NSString *) = diagnosticHandler;
  dispatch_block_t deliver = ^{
    NSLog(@"[VoIPSDK] %@", message);
    if (handler) handler(message);
  };
  if ([NSThread isMainThread]) deliver();
  else dispatch_async(dispatch_get_main_queue(), deliver);
}

static NSValue *key(Class cls) { return [NSValue valueWithPointer:(__bridge const void *)cls]; }

static Method ownMethod(Class cls, SEL selector) {
  unsigned int count = 0;
  Method *methods = class_copyMethodList(cls, &count);
  Method result = NULL;
  for (unsigned int i = 0; i < count; ++i) {
    if (method_getName(methods[i]) == selector) { result = methods[i]; break; }
  }
  free(methods);
  return result;
}

static BOOL signatureMatches(Method method, char argumentType) {
  if (!method) return NO;
  char *result = method_copyReturnType(method);
  char *argument = method_copyArgumentType(method, 2);
  BOOL matches = method_getNumberOfArguments(method) == 3 && result && result[0] == '@' &&
      argument && argument[0] == argumentType;
  free(result);
  free(argument);
  return matches;
}

static void observedProvider(id provider) {
  if (!provider) return;
  [monitorLock lock];
  // Class-cluster initializers may return an object already observed in the
  // same constructor chain. The cooperative runtime source shares this gate.
  BOOL alreadyObserved = [observedProviders containsObject:provider];
  if (!alreadyObserved) [observedProviders addObject:provider];
  BOOL expected = [NSThread isMainThread] && ownedCreation;
  if (expected && !alreadyObserved) ownedProviderCount++;
  BOOL extraOwned = expected && ownedProviderCount > 1;
  [monitorLock unlock];
  if (!alreadyObserved && (!expected || extraOwned))
    diagnose(@"Another CXProvider was created. D13 routes actions to the newest provider; keep one ConversationManager in this process.");
}

__attribute__((ns_returns_retained)) static id observedInitialize(
    id __attribute__((ns_consumed)) receiver, SEL selector, id configuration) {
  void *identity = (__bridge void *)receiver;
  Class owner = object_getClass(receiver);
  BOOL outermost = YES;
  for (VSInitializerFrame *frame = currentFrame; frame; frame = frame->previous) {
    if (frame->receiver == identity) {
      owner = class_getSuperclass(frame->owner);
      outermost = NO;
      break;
    }
  }
  [monitorLock lock];
  NSValue *saved = nil;
  while (owner && !(saved = initializers[key(owner)])) owner = class_getSuperclass(owner);
  IMP original = saved.pointerValue;
  // Install publishes every original before its hook and never clears that map.
  // The fallback only serves an unsupported third-party direct invocation of an IMP.
  if (!original) original = initializers[key(monitoredClass)].pointerValue;
  [monitorLock unlock];
  VSInitializerFrame frame = {identity, owner ?: monitoredClass, currentFrame};
  currentFrame = &frame;
  id result;
  @try { result = ((ProviderInitializer)original)(receiver, selector, configuration); }
  @finally { currentFrame = frame.previous; }
  if (outermost) observedProvider(result);
  return result;
}

// Called with monitorLock held; it never allocates a provider to discover a class.
static NSString *observeConcreteClass(Class cls) {
  Class ancestor = cls;
  while (ancestor && ancestor != monitoredClass) ancestor = class_getSuperclass(ancestor);
  if (!ancestor)
    return @"The provider allocator returned an unrelated class; its methods are unchanged and creation monitoring is unavailable.";
  NSString *reason = nil;
  // An allocation can return a leaf inheriting an intermediate override. Follow
  // the actual superclass chain, rather than assuming no leaf method means the
  // public root hook will run.
  for (Class owner = cls; owner && owner != monitoredClass; owner = class_getSuperclass(owner)) {
    if (initializers[key(owner)]) continue;
    Method method = ownMethod(owner, @selector(initWithConfiguration:));
    if (!method) continue;
    if (!signatureMatches(method, '@')) {
      reason = @"The concrete provider initializer has an unsupported ABI; its creation cannot be fully monitored.";
      continue;
    }
    IMP original = method_getImplementation(method);
    if (original == (IMP)observedInitialize) continue;
    initializers[key(owner)] = [NSValue valueWithPointer:original];
    method_setImplementation(method, (IMP)observedInitialize);
    if (method_getImplementation(method) != (IMP)observedInitialize) {
      // Preserve functional initialization if another tool prevented installation.
      method_setImplementation(method, original);
      reason = @"The concrete provider initializer monitor could not bind; normal initialization is preserved.";
    }
  }
  return reason;
}

__attribute__((ns_returns_retained)) static id observedAllocate(Class receiver, SEL selector, NSZone *zone) {
  id result = ((ProviderAllocator)originalAllocator)(receiver, selector, zone);
  if (result) {
    [monitorLock lock];
    NSString *reason = observeConcreteClass(object_getClass(result));
    [monitorLock unlock];
    if (reason) diagnose(reason);
  }
  return result;
}

BOOL VSProviderMonitorInstall(Class providerClass, void (^diagnostic)(NSString *)) {
  return VSProviderMonitorInstallWithSource(providerClass, diagnostic, nil);
}

BOOL VSProviderMonitorInstallWithSource(Class providerClass, void (^diagnostic)(NSString *),
    BOOL (^registerObserver)(void (^)(id))) {
  if (![NSThread isMainThread]) {
    // Do not mutate runtime methods from a wrongly isolated client setup.
    dispatch_async(dispatch_get_main_queue(), ^{
      NSLog(@"[VoIPSDK] Install the provider creation monitor on main before creating the manager.");
      if (diagnostic) diagnostic(@"Install the provider creation monitor on main before creating the manager.");
    });
    return NO;
  }
  if (monitoring) return monitoredClass == providerClass;
  diagnosticHandler = [diagnostic copy];
  if (registerObserver) {
    monitorLock = [NSLock new];
    observedProviders = [[NSHashTable alloc] initWithOptions:
        NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality capacity:0];
    monitoredClass = providerClass;
    // Do not hold monitorLock across runtime registration. Provider observation
    // also runs outside the runtime install lock, so neither lock nests the other.
    monitoring = registerObserver(^(id provider) { observedProvider(provider); });
    if (!monitoring) diagnose(@"The simulator provider creation source was unavailable; creation monitoring is disabled.");
    return monitoring;
  }
  SEL initializer = @selector(initWithConfiguration:);
  SEL allocator = @selector(allocWithZone:);
  Class metaclass = object_getClass(providerClass);
  Method initMethod = class_getInstanceMethod(providerClass, initializer);
  Method allocMethod = class_getInstanceMethod(metaclass, allocator);
  if (!signatureMatches(initMethod, '@') || !signatureMatches(allocMethod, '^')) {
    diagnose(@"The public provider allocator/initializer ABI is unsupported; creation monitoring is disabled.");
    return NO;
  }
  monitorLock = [NSLock new];
  initializers = [NSMutableDictionary new];
  observedProviders = [[NSHashTable alloc] initWithOptions:
      NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality capacity:0];
  monitoredClass = providerClass;
  originalAllocator = method_getImplementation(allocMethod);
  IMP originalInit = method_getImplementation(initMethod);
  initializers[key(providerClass)] = [NSValue valueWithPointer:originalInit];
  // Add an override on this class/metaclass when inherited. Never mutate NSObject.
  if (!class_addMethod(providerClass, initializer, (IMP)observedInitialize, method_getTypeEncoding(initMethod)))
    method_setImplementation(ownMethod(providerClass, initializer), (IMP)observedInitialize);
  if (!class_addMethod(metaclass, allocator, (IMP)observedAllocate, method_getTypeEncoding(allocMethod)))
    method_setImplementation(ownMethod(metaclass, allocator), (IMP)observedAllocate);
  monitoring = class_getMethodImplementation(providerClass, initializer) == (IMP)observedInitialize &&
      class_getMethodImplementation(metaclass, allocator) == (IMP)observedAllocate;
  if (!monitoring) {
    // An added override is restored to the inherited IMP; no global method changes.
    method_setImplementation(ownMethod(providerClass, initializer), originalInit);
    method_setImplementation(ownMethod(metaclass, allocator), originalAllocator);
    diagnose(@"Provider creation monitoring failed to bind; normal provider behavior is preserved.");
  }
  return monitoring;
}

void VSProviderMonitorBeginOwnedCreation(void) {
  if (!monitoring) return;
  if (![NSThread isMainThread]) {
    diagnose(@"Begin owned manager creation on main.");
    return;
  }
  [monitorLock lock];
  BOOL duplicate = ownedCreation;
  if (!duplicate) { ownedCreation = YES; ownedProviderCount = 0; }
  [monitorLock unlock];
  if (duplicate) diagnose(@"Owned manager creation was already in progress; a second manager is unsupported.");
}

void VSProviderMonitorEndOwnedCreation(void) {
  if (!monitoring) return;
  if (![NSThread isMainThread]) {
    diagnose(@"End owned manager creation on main.");
    return;
  }
  [monitorLock lock];
  BOOL active = ownedCreation;
  NSUInteger observed = ownedProviderCount;
  ownedCreation = NO;
  [monitorLock unlock];
  if (!active) diagnose(@"Owned manager creation was not bracketed.");
  else if (!observed) diagnose(@"No provider initializer was observed for the owned manager; this framework's creation path is outside debug monitor coverage.");
}
#endif
