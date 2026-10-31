#import "CKRuntimeSeam.h"
#if TARGET_OS_SIMULATOR && TARGET_OS_IOS
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <stdio.h>
#include <errno.h>
#import <CommonCrypto/CommonDigest.h>

NSDictionary *CKSimConsumeLaunchPush(NSString *directory, NSString *runID, NSString *bundleID,
    NSTimeInterval now, uid_t owner, NSString **reason) {
  if (reason) *reason=nil;
  NSString *path=[directory stringByAppendingPathComponent:@"push-launch.json"];
  struct stat folder, source;
  if (lstat(path.fileSystemRepresentation,&source)) {
    if(reason && errno!=ENOENT)*reason=@"cannot inspect launch envelope";
    return nil;
  }
  if (lstat(directory.fileSystemRepresentation,&folder) || !S_ISDIR(folder.st_mode) ||
      folder.st_uid!=owner || (folder.st_mode&07777)!=0700 || !S_ISREG(source.st_mode) ||
      source.st_uid!=owner || (source.st_mode&07777)!=0600 || source.st_nlink!=1 ||
      source.st_size<=0 || source.st_size>8192) {
    if(reason)*reason=@"unsafe launch envelope"; return nil;
  }
  // Exclusive atomic claim prevents two registries/processes from consuming
  // the same staged delivery. Existing claims fail closed, never overwrite.
  NSString *claimed=[directory stringByAppendingPathComponent:@"push-launch.consuming"];
  if (renamex_np(path.fileSystemRepresentation,claimed.fileSystemRepresentation,RENAME_EXCL)) {
    if(reason)*reason=@"cannot claim launch envelope"; return nil;
  }
  int descriptor=open(claimed.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);
  struct stat actual;
  BOOL safe=descriptor>=0 && !fstat(descriptor,&actual) && actual.st_dev==source.st_dev &&
      actual.st_ino==source.st_ino && S_ISREG(actual.st_mode) && actual.st_size==source.st_size && actual.st_uid==owner &&
      (actual.st_mode&07777)==0600 && actual.st_nlink==1;
  NSMutableData *bytes=[NSMutableData dataWithLength:safe?(NSUInteger)source.st_size:0];
  ssize_t count=safe?read(descriptor,bytes.mutableBytes,bytes.length):-1;
  if(descriptor>=0)close(descriptor);
  unlink(claimed.fileSystemRepresentation);
  NSDictionary *value=(safe && count==(ssize_t)bytes.length)?
      [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil]:nil;
  NSSet *keys=[NSSet setWithArray:@[@"schemaVersion",@"id",@"runID",@"bundleID",@"createdAtMS",@"expiresAtMS",@"payload",@"mustReport"]];
  BOOL valid=[value isKindOfClass:NSDictionary.class] && [[NSSet setWithArray:value.allKeys] isEqual:keys];
  if(valid) {
    NSNumber *created=value[@"createdAtMS"],*expires=value[@"expiresAtMS"],*required=value[@"mustReport"];
    NSString *identifier=value[@"id"];
    valid=[value[@"schemaVersion"] isEqual:@1] && [value[@"runID"] isEqual:runID] && [value[@"bundleID"] isEqual:bundleID] &&
      [identifier isKindOfClass:NSString.class] && [[[NSUUID alloc]initWithUUIDString:identifier].UUIDString isEqual:identifier] &&
      [created isKindOfClass:NSNumber.class] && [expires isKindOfClass:NSNumber.class] &&
      isfinite(created.doubleValue) && isfinite(expires.doubleValue) &&
      created.doubleValue<=now*1000+1000 && expires.doubleValue>now*1000 &&
      expires.doubleValue>created.doubleValue && expires.doubleValue-created.doubleValue<=30000 &&
      [required isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)required)==CFBooleanGetTypeID() &&
      [value[@"payload"] isKindOfClass:NSDictionary.class];
    if(valid) valid=[NSJSONSerialization dataWithJSONObject:value[@"payload"] options:0 error:nil].length<=5120;
  }
  if(!valid) { if(reason)*reason=@"invalid or expired launch envelope"; return nil; }
  unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(bytes.bytes,(CC_LONG)bytes.length,digest);
  NSMutableString *hash=[NSMutableString stringWithCapacity:64];
  for(NSUInteger i=0;i<sizeof(digest);i++)[hash appendFormat:@"%02x",digest[i]];
  NSMutableDictionary *result=value.mutableCopy; result[@"envelopeSHA256"]=hash;
  return result;
}
#endif
