#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and returns the reason of an Objective-C exception it raised, or nil.
/// Swift can't catch these: one escaping a Swift task corrupts the concurrency runtime's executor tracking,
/// and the app crashes at the next actor check (MainActor.assumeIsolated) far from the cause.
NSString *_Nullable ObjCCatch(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
