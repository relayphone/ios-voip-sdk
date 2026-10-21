#import <Foundation/Foundation.h>
#import <objc/runtime.h>
__attribute__((constructor)) static void ck_inject(void) {
  Class provider = NSClassFromString(@"CXProvider");
  fprintf(stderr, "PROBE {\"event\":\"inject.loaded\",\"cxProviderLoaded\":%s,\"pid\":%d}\n", provider ? "true" : "false", getpid());
}
