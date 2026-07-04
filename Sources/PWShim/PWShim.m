#import "include/PWShim.h"

BOOL PWTryCatch(void (NS_NOESCAPE ^block)(void), NSError **error) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSString *desc = exception.description ?: @"Objective-C exception";
            *error = [NSError errorWithDomain:@"dev.benborgers.pairwise.exception"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: desc}];
        }
        return NO;
    }
}
