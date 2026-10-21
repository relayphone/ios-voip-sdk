#import <Foundation/Foundation.h>
#import <CallKit/CallKit.h>
#import <objc/runtime.h>
extern void constructSwiftProvider(void);
__attribute__((ns_returns_retained)) static id denyAllocation(id cls, SEL selector, NSZone *zone) {
  fprintf(stderr,"EXPERIMENT allocation-refused\n");
  return nil;
}
int main(void) {
  @autoreleasepool {
    Method allocator = class_getClassMethod(CXProvider.class, @selector(allocWithZone:));
    class_replaceMethod(object_getClass(CXProvider.class), @selector(allocWithZone:), (IMP)denyAllocation, method_getTypeEncoding(allocator));
    CXProvider *provider = [[CXProvider alloc] initWithConfiguration:[CXProviderConfiguration new]];
    fprintf(stderr,"EXPERIMENT objc-constructor-returned-nil=%d\n",provider == nil);
    constructSwiftProvider();
    fprintf(stderr,"EXPERIMENT done\n");
  }
  return 0;
}
