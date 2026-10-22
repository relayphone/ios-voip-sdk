#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Thread-safe settlement; the system completion always runs on main.
@interface VSCompletionOnce : NSObject
- (instancetype)initWithCompletion:(dispatch_block_t)completion retaining:(id)receiver;
- (void)finish;
@end
NS_ASSUME_NONNULL_END
