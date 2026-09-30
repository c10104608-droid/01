#import "UnityInspection.h"
#import <mach-o/dyld.h>

NSDictionary *UUIUnityRuntimeStatus(void) {
    NSArray<NSString *> *markers = @[@"unityframework", @"unity-iphone", @"libil2cpp", @"unityplayer"];
    NSMutableArray<NSString *> *matches = [NSMutableArray array];
    uint32_t count = _dyld_image_count();
    for (uint32_t index = 0; index < count; index++) {
        const char *raw = _dyld_get_image_name(index);
        if (!raw || !*raw) continue;
        NSString *path = [NSString stringWithUTF8String:raw];
        NSString *lower = path.lowercaseString;
        for (NSString *marker in markers) {
            if ([lower containsString:marker]) { [matches addObject:path]; break; }
        }
    }
    BOOL detected = matches.count > 0;
    return @{
        @"schemaVersion": @"unity-marker-status-1.0",
        @"detected": @(detected),
        @"status": detected ? @"PARTIAL_UNITY_RUNTIME_MARKERS_DETECTED" : @"UNITY_NOT_DETECTED",
        @"runtimeImages": matches,
        @"initializationStatus": detected ? @"UNVERIFIED" : @"NOT_APPLICABLE",
        @"unityHierarchyStatus": @"NOT_AVAILABLE",
        @"reason": detected ? @"Loaded-image markers are evidence only. Runtime initialization and a supported Unity UI bridge are not verified; no Unity internals were called." : @"No Unity runtime image markers were found in the current process. No Unity internals were called."
    };
}
