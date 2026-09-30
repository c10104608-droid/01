#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Passive dyld image-marker inspection only. This module never calls Unity APIs.
NSDictionary *UUIUnityRuntimeStatus(void);

NS_ASSUME_NONNULL_END
