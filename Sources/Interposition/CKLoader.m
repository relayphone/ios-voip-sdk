#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#import <dlfcn.h>
#if !TARGET_OS_SIMULATOR
#error CallKit Simulator loader is simulator-only.
#endif
__attribute__((constructor)) static void loadSelectedRuntime(void) {
  NSDictionary *env=NSProcessInfo.processInfo.environment;
  NSString *bundle=NSBundle.mainBundle.bundleIdentifier;
  if (![env[@"CKSIM_ENABLED"] isEqual:@"1"] || !bundle) return;
  NSArray *allowed=[env[@"CKSIM_BUNDLE_IDS"] componentsSeparatedByString:@","];
  if (![allowed containsObject:bundle]) return;
  NSString *runtime=env[@"CKSIM_RUNTIME"];
  if (!runtime.isAbsolutePath || !dlopen(runtime.fileSystemRepresentation,RTLD_NOW|RTLD_GLOBAL)) {
    fprintf(stderr,"CKSIM failed to load selected simulator runtime\n");
    abort();
  }
}
