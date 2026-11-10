//
//  HLObjC.m
//  HomeLock
//

#import "HLObjC.h"

NSErrorDomain const HLObjCExceptionDomain = @"HLObjCException";

@implementation HLObjC

+ (BOOL)tryBlock:(NS_NOESCAPE void (^)(void))block error:(NSError **)error {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:HLObjCExceptionDomain
                                         code:1
                                     userInfo:@{
                NSLocalizedDescriptionKey: exception.reason ?: exception.name,
                @"name": exception.name,
            }];
        }
        return NO;
    }
}

@end
