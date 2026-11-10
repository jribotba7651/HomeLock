//
//  HLObjC.h
//  HomeLock
//
//  Catches Objective-C exceptions so Swift can turn them into errors.
//  HomeKit validates trigger predicates by raising NSInvalidArgumentException,
//  which Swift cannot catch and would otherwise crash the app.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const HLObjCExceptionDomain;

@interface HLObjC : NSObject
/// Runs the block; if it raises an NSException, returns NO and fills error
/// (domain HLObjCExceptionDomain, NSLocalizedDescriptionKey = exception reason,
/// userInfo["name"] = exception name).
+ (BOOL)tryBlock:(NS_NOESCAPE void (^)(void))block error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
