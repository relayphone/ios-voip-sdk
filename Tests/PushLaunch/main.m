#import "CKPushLaunch.h"
#include <sys/stat.h>
#include <unistd.h>
static int checks;
static void check(BOOL passed, NSString *name) { if(!passed){NSLog(@"FAIL %@",name);exit(1);} checks++; }
int main(void) { @autoreleasepool {
  NSString *root=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
  NSFileManager *fm=NSFileManager.defaultManager;
  [fm createDirectoryAtPath:root withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:nil];
  NSString *path=[root stringByAppendingPathComponent:@"push-launch.json"];
  NSDictionary *base=@{@"schemaVersion":@1,@"id":@"AC163EA0-9825-42B9-91B2-93075FCE8A63",@"runID":@"host-test",
    @"bundleID":@"dev.synthetic",@"createdAtMS":@100000,@"expiresAtMS":@120000,@"mustReport":@YES,@"payload":@{@"incomingCall":@{}}};
  void (^stage)(NSDictionary *)=^(NSDictionary *value){
    [fm removeItemAtPath:path error:nil];
    [fm createFileAtPath:path contents:[NSJSONSerialization dataWithJSONObject:value options:0 error:nil]
      attributes:@{NSFilePosixPermissions:@0600}];
  };
  NSString *reason=nil;
  stage(base); check(CKSimConsumeLaunchPush(root,@"host-test",@"dev.synthetic",110,getuid(),&reason)!=nil,@"consume");
  check(CKSimConsumeLaunchPush(root,@"host-test",@"dev.synthetic",110,getuid(),&reason)==nil && !reason,@"no replay");
  for(NSString *key in @[@"runID",@"bundleID",@"expiresAtMS",@"createdAtMS",@"id",@"mustReport"]) {
    NSMutableDictionary *value=base.mutableCopy;
    value[key]=[key isEqual:@"expiresAtMS"]?@109000:([key isEqual:@"createdAtMS"]?@200000:([key isEqual:@"mustReport"]?@1:@"wrong"));
    stage(value); check(!CKSimConsumeLaunchPush(root,@"host-test",@"dev.synthetic",110,getuid(),&reason) && reason!=nil,key);
    check(![fm fileExistsAtPath:path],@"claimed invalid envelope removed");
  }
  stage(base); chmod(path.fileSystemRepresentation,0644);
  check(!CKSimConsumeLaunchPush(root,@"host-test",@"dev.synthetic",110,getuid(),&reason),@"file mode");
  stage(base); check(!CKSimConsumeLaunchPush(root,@"host-test",@"dev.synthetic",110,getuid()+1,&reason),@"owner mismatch");
  stage(base); chmod(root.fileSystemRepresentation,0755);
  check(!CKSimConsumeLaunchPush(root,@"host-test",@"dev.synthetic",110,getuid(),&reason),@"directory mode");
  chmod(root.fileSystemRepresentation,0700); [fm removeItemAtPath:path error:nil];
  symlink("/etc/hosts",path.fileSystemRepresentation);
  check(!CKSimConsumeLaunchPush(root,@"host-test",@"dev.synthetic",110,getuid(),&reason),@"symlink");
  stage(base); NSString *claim=[root stringByAppendingPathComponent:@"push-launch.consuming"];
  [@"existing claim" writeToFile:claim atomically:NO encoding:NSUTF8StringEncoding error:nil];
  check(!CKSimConsumeLaunchPush(root,@"host-test",@"dev.synthetic",110,getuid(),&reason),@"exclusive claim");
  check([[NSString stringWithContentsOfFile:claim encoding:NSUTF8StringEncoding error:nil] isEqual:@"existing claim"],@"claim preserved");
  [fm removeItemAtPath:root error:nil];
  printf("{\"success\":true,\"fixtureKind\":\"host-filesystem\",\"checks\":%d}\n",checks);
} }
