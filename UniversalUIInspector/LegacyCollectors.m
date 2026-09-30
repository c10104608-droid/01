#import "LegacyCollectors.h"
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <unistd.h>
#import <fcntl.h>

static NSString *LegacyString(NSString *value) {
    return value.length ? value : @"NOT_AVAILABLE";
}

static NSString *LegacyCString(const char *value) {
    return value && *value ? [NSString stringWithUTF8String:value] : @"NOT_AVAILABLE";
}

static NSString *LegacySanitize(NSString *value) {
    NSString *s = LegacyString(value);
    return [[s stringByReplacingOccurrencesOfString:@"\r" withString:@"\\r"]
            stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
}

static void LegacyWriteLine(FILE *file, NSString *line) {
    if (!file || !line) return;
    if (ftell(file) == 0) { NSDictionary *build = UUIBuildMetadata(); NSString *banner = [NSString stringWithFormat:@"# BUILD version=%@ sourceRevision=%@ buildTimestampUTC=%@\n", build[@"version"], build[@"sourceRevision"], build[@"buildTimestampUTC"]]; NSData *header = [banner dataUsingEncoding:NSUTF8StringEncoding]; if (header.length) fwrite(header.bytes, 1, header.length, file); }
    NSData *data = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length) fwrite(data.bytes, 1, data.length, file);
}

static void LegacyFlush(FILE *file) {
    if (!file) return;
    fflush(file);
    int descriptor = fileno(file);
    if (descriptor >= 0) fsync(descriptor);
}

static BOOL LegacyWriteJSONLine(FILE *file, NSDictionary *object) {
    if (!file || !object) return NO;
    NSMutableDictionary *record = [object mutableCopy]; if (!record[@"build"]) record[@"build"] = UUIBuildMetadata();
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:record options:0 error:&error];
    if (!data || error) return NO;
    size_t written = fwrite(data.bytes, 1, data.length, file);
    int newline = fputc('\n', file);
    return written == data.length && newline != EOF;
}

static void LegacyWriteJSONFile(NSURL *url, NSDictionary *object) {
    if (!url || !object) return;
    NSMutableDictionary *payload = [object mutableCopy]; if (!payload[@"build"]) payload[@"build"] = UUIBuildMetadata();
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:NSJSONWritingPrettyPrinted error:nil];
    if (data) [data writeToURL:url options:NSDataWritingAtomic error:nil];
}

static NSURL *LegacyCheckpointURL(NSURL *summaryURL) {
    return [NSURL fileURLWithPath:[summaryURL.path stringByAppendingString:@".checkpoint.json"]];
}

static NSDictionary *LegacyReadCheckpoint(NSURL *summaryURL) {
    NSData *data = [NSData dataWithContentsOfURL:LegacyCheckpointURL(summaryURL)];
    id object = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [object isKindOfClass:NSDictionary.class] ? object : nil;
}

static void LegacyWriteCheckpoint(NSURL *summaryURL, NSUInteger nextIndex, NSUInteger completed, uint64_t jsonBytes, uint64_t textBytes, int classListCount) {
    LegacyWriteJSONFile(LegacyCheckpointURL(summaryURL), @{ @"schemaVersion": @"legacy-checkpoint-1.0", @"nextIndex": @(nextIndex), @"completedCount": @(completed), @"complete": @NO, @"jsonBytes": @(jsonBytes), @"textBytes": @(textBytes), @"classListCount": @(classListCount), @"updatedAt": [NSDate date].description ?: @"" });
}

static void LegacyRemoveCheckpoint(NSURL *summaryURL) {
    [[NSFileManager defaultManager] removeItemAtURL:LegacyCheckpointURL(summaryURL) error:nil];
}

static void LegacyTruncate(NSURL *url, uint64_t length) {
    int descriptor = open(url.path.fileSystemRepresentation, O_RDWR);
    if (descriptor >= 0) { ftruncate(descriptor, (off_t)length); close(descriptor); }
}

static uint64_t LegacyFileOffset(FILE *file) {
    long offset = file ? ftell(file) : -1;
    return offset >= 0 ? (uint64_t)offset : 0;
}

static Class *LegacyCopyClassList(int *countOut) {
    if (countOut) *countOut = 0;
    int requested = objc_getClassList(NULL, 0);
    if (requested <= 0) return NULL;
    for (NSUInteger attempt = 0; attempt < 4; attempt++) {
        Class *classes = (Class *)calloc((size_t)requested, sizeof(Class));
        if (!classes) return NULL;
        int actual = objc_getClassList(classes, requested);
        if (actual <= requested) {
            if (countOut) *countOut = actual;
            return classes;
        }
        free(classes);
        requested = actual;
    }
    return NULL;
}

static NSString *LegacyClassKind(const char *image, const char *mainImage) {
    if (!image || !*image) return @"unknown";
    NSString *path = [NSString stringWithUTF8String:image] ?: @"";
    if (mainImage && strcmp(image, mainImage) == 0) return @"app";
    if ([path rangeOfString:@"/System/"].location != NSNotFound ||
        [path rangeOfString:@"/usr/lib/"].location != NSNotFound ||
        [path rangeOfString:@"/Developer/"].location != NSNotFound) return @"system";
    if ([path rangeOfString:@"/Frameworks/"].location != NSNotFound) return @"embedded-framework";
    return @"unknown";
}

NSUInteger LegacyWriteRuntimeClassIndex(NSURL *jsonlURL, NSURL *textURL, NSURL *summaryURL) {
    int classCount = 0;
    Class *classes = LegacyCopyClassList(&classCount);
    if (!classes && classCount > 0) {
        LegacyWriteJSONFile(summaryURL, @{ @"schemaVersion": @"legacy-2.1", @"complete": @NO, @"completionReason": @"class list allocation failed", @"classListCount": @(classCount), @"totalClassesEnumerated": @0 });
        return 0;
    }
    NSDictionary *checkpoint = LegacyReadCheckpoint(summaryURL);
    NSUInteger startIndex = 0, total = 0;
    uint64_t jsonOffset = 0, textOffset = 0;
    BOOL resume = checkpoint && ![checkpoint[@"complete"] boolValue] && [checkpoint[@"classListCount"] intValue] == classCount && [[NSFileManager defaultManager] fileExistsAtPath:jsonlURL.path] && [[NSFileManager defaultManager] fileExistsAtPath:textURL.path];
    if (resume) {
        startIndex = [checkpoint[@"nextIndex"] unsignedIntegerValue]; total = [checkpoint[@"completedCount"] unsignedIntegerValue]; jsonOffset = [checkpoint[@"jsonBytes"] unsignedLongLongValue]; textOffset = [checkpoint[@"textBytes"] unsignedLongLongValue];
        LegacyTruncate(jsonlURL, jsonOffset); LegacyTruncate(textURL, textOffset);
    } else {
        LegacyRemoveCheckpoint(summaryURL); [[NSFileManager defaultManager] removeItemAtURL:jsonlURL error:nil]; [[NSFileManager defaultManager] removeItemAtURL:textURL error:nil];
    }
    FILE *jsonFile = fopen(jsonlURL.path.UTF8String, resume ? "ab" : "wb");
    FILE *textFile = fopen(textURL.path.UTF8String, resume ? "ab" : "wb");
    if (!jsonFile || !textFile) { if (jsonFile) fclose(jsonFile); if (textFile) fclose(textFile); free(classes); return total; }
    const char *mainImage = _dyld_get_image_name(0); NSUInteger appClasses = 0, frameworkClasses = 0, systemClasses = 0, unknownClasses = 0, errorCount = 0;
    for (int index = (int)MIN(startIndex, (NSUInteger)classCount); index < classCount; index++) {
        @autoreleasepool {
            Class cls = classes[index]; const char *image = class_getImageName(cls); NSString *kind = LegacyClassKind(image, mainImage); if ([kind isEqualToString:@"app"]) appClasses++; else if ([kind isEqualToString:@"embedded-framework"]) frameworkClasses++; else if ([kind isEqualToString:@"system"]) systemClasses++; else unknownClasses++;
            NSString *name = LegacyString(NSStringFromClass(cls)); NSString *superclass = LegacyString(NSStringFromClass(class_getSuperclass(cls))); NSString *imagePath = LegacyCString(image); BOOL appOwned = [kind isEqualToString:@"app"] || [kind isEqualToString:@"embedded-framework"]; BOOL swiftHeuristic = [name rangeOfString:@"."].location != NSNotFound || [imagePath rangeOfString:@"libswift" options:NSCaseInsensitiveSearch].location != NSNotFound;
            NSDictionary *row = @{ @"schemaVersion": @"legacy-2.1", @"class": name, @"superclass": superclass, @"image": imagePath, @"imageBasename": imagePath.lastPathComponent ?: @"NOT_AVAILABLE", @"classification": kind, @"appOwnedHeuristic": @(appOwned), @"swiftRuntimeHeuristic": @(swiftHeuristic), @"swiftDetection": swiftHeuristic ? @"safe-name-or-runtime-image-heuristic" : @"not-detected", @"detailedMetadata": @NO, @"detailStatus": @"separate-streamed-detail-pass" };
            if (!LegacyWriteJSONLine(jsonFile, row)) errorCount++;
            LegacyWriteLine(textFile, [NSString stringWithFormat:@"%@ : %@ image=%@ classification=%@ appOwned=%@ swiftHeuristic=%@", name, superclass, imagePath, kind, appOwned ? @"YES" : @"NO", swiftHeuristic ? @"YES" : @"NO"]);
            total++;
            if (total % 100 == 0 || index == classCount - 1) { LegacyFlush(jsonFile); LegacyFlush(textFile); LegacyWriteCheckpoint(summaryURL, index + 1, total, LegacyFileOffset(jsonFile), LegacyFileOffset(textFile), classCount); }
        }
    }
    free(classes); LegacyFlush(jsonFile); LegacyFlush(textFile); fclose(jsonFile); fclose(textFile);
    BOOL complete = (total == (NSUInteger)classCount && errorCount == 0);
    LegacyWriteJSONFile(summaryURL, @{ @"schemaVersion": @"legacy-2.1", @"complete": @(complete), @"completionReason": complete ? @"objc_getClassList iteration finished" : @"one or more JSON records failed", @"classListCount": @(classCount), @"totalClassesEnumerated": @(total), @"appClasses": @(appClasses), @"embeddedFrameworkClasses": @(frameworkClasses), @"systemClasses": @(systemClasses), @"unknownClasses": @(unknownClasses), @"detailPassSeparate": @YES, @"errors": @(errorCount), @"truncations": @0, @"limitReached": @NO, @"resumedFromCheckpoint": @(resume) });
    if (complete) LegacyRemoveCheckpoint(summaryURL);
    return total;
}

static NSString *LegacyIMPImage(Method method) {
    Dl_info info = {0};
    if (method) dladdr((void *)method_getImplementation(method), &info);
    return LegacyCString(info.dli_fname);
}

static NSDictionary *LegacyMethodDictionary(Method method, NSString *kind) {
    if (!method) return @{};
    return @{
        @"kind": LegacyString(kind),
        @"selector": LegacyString(NSStringFromSelector(method_getName(method))),
        @"typeEncoding": LegacyCString(method_getTypeEncoding(method)),
        @"imp": [NSString stringWithFormat:@"%p", method_getImplementation(method)],
        @"impImage": LegacyIMPImage(method)
    };
}

static NSArray *LegacyProtocolsForClass(Class cls) {
    unsigned count = 0;
    Protocol *__unsafe_unretained *protocols = class_copyProtocolList(cls, &count);
    NSMutableArray *names = [NSMutableArray arrayWithCapacity:count];
    for (unsigned i = 0; i < count; i++) {
        NSString *name = LegacyCString(protocol_getName(protocols[i]));
        if (name.length) [names addObject:name];
    }
    free(protocols);
    return names;
}

static NSDictionary *LegacyDetailedClassRecord(Class cls) {
    NSString *name = LegacyString(NSStringFromClass(cls));
    const char *image = class_getImageName(cls);
    NSMutableDictionary *record = [@{
        @"schemaVersion": @"legacy-2.0",
        @"class": name,
        @"superclass": LegacyString(NSStringFromClass(class_getSuperclass(cls))),
        @"image": LegacyCString(image),
        @"protocols": LegacyProtocolsForClass(cls)
    } mutableCopy];

    NSMutableArray *instanceMethods = [NSMutableArray array];
    unsigned methodCount = 0;
    Method *methods = class_copyMethodList(cls, &methodCount);
    for (unsigned i = 0; i < methodCount; i++) {
        [instanceMethods addObject:LegacyMethodDictionary(methods[i], @"instance-declared")];
    }
    free(methods);

    NSMutableArray *classMethods = [NSMutableArray array];
    methodCount = 0;
    Method *metaclassMethods = class_copyMethodList(object_getClass(cls), &methodCount);
    for (unsigned i = 0; i < methodCount; i++) {
        [classMethods addObject:LegacyMethodDictionary(metaclassMethods[i], @"class-declared")];
    }
    free(metaclassMethods);
    record[@"instanceMethods"] = instanceMethods;
    record[@"classMethods"] = classMethods;

    NSMutableArray *properties = [NSMutableArray array];
    unsigned propertyCount = 0;
    objc_property_t *propertyList = class_copyPropertyList(cls, &propertyCount);
    for (unsigned i = 0; i < propertyCount; i++) {
        [properties addObject:@{
            @"name": LegacyCString(property_getName(propertyList[i])),
            @"attributes": LegacyCString(property_getAttributes(propertyList[i]))
        }];
    }
    free(propertyList);
    record[@"properties"] = properties;

    NSMutableArray *ivars = [NSMutableArray array];
    unsigned ivarCount = 0;
    Ivar *ivarList = class_copyIvarList(cls, &ivarCount);
    for (unsigned i = 0; i < ivarCount; i++) {
        [ivars addObject:@{
            @"name": LegacyCString(ivar_getName(ivarList[i])),
            @"type": LegacyCString(ivar_getTypeEncoding(ivarList[i])),
            @"offset": @(ivar_getOffset(ivarList[i]))
        }];
    }
    free(ivarList);
    record[@"ivars"] = ivars;
    return record;
}

NSUInteger LegacyWriteRuntimeDetails(NSURL *jsonlURL, NSURL *textURL, NSURL *summaryURL) {
    int classCount = 0; Class *classes = LegacyCopyClassList(&classCount); if (!classes && classCount > 0) { LegacyWriteJSONFile(summaryURL, @{ @"schemaVersion": @"legacy-2.1", @"complete": @NO, @"completionReason": @"class list allocation failed", @"classesEnriched": @0 }); return 0; }
    NSDictionary *checkpoint = LegacyReadCheckpoint(summaryURL); NSUInteger startIndex = 0, total = 0; uint64_t jsonOffset = 0, textOffset = 0; BOOL resume = checkpoint && ![checkpoint[@"complete"] boolValue] && [checkpoint[@"classListCount"] intValue] == classCount && [[NSFileManager defaultManager] fileExistsAtPath:jsonlURL.path] && [[NSFileManager defaultManager] fileExistsAtPath:textURL.path];
    if (resume) { startIndex = [checkpoint[@"nextIndex"] unsignedIntegerValue]; total = [checkpoint[@"completedCount"] unsignedIntegerValue]; jsonOffset = [checkpoint[@"jsonBytes"] unsignedLongLongValue]; textOffset = [checkpoint[@"textBytes"] unsignedLongLongValue]; LegacyTruncate(jsonlURL, jsonOffset); LegacyTruncate(textURL, textOffset); } else { LegacyRemoveCheckpoint(summaryURL); [[NSFileManager defaultManager] removeItemAtURL:jsonlURL error:nil]; [[NSFileManager defaultManager] removeItemAtURL:textURL error:nil]; }
    FILE *jsonFile = fopen(jsonlURL.path.UTF8String, resume ? "ab" : "wb"); FILE *textFile = fopen(textURL.path.UTF8String, resume ? "ab" : "wb"); if (!jsonFile || !textFile) { if (jsonFile) fclose(jsonFile); if (textFile) fclose(textFile); free(classes); return total; }
    NSUInteger errors = 0;
    for (int index = (int)MIN(startIndex, (NSUInteger)classCount); index < classCount; index++) {
        @autoreleasepool {
            NSDictionary *record = LegacyDetailedClassRecord(classes[index]); if (!LegacyWriteJSONLine(jsonFile, record)) errors++;
            LegacyWriteLine(textFile, [NSString stringWithFormat:@"CLASS %@ : %@ image=%@", record[@"class"], record[@"superclass"], record[@"image"]]);
            for (NSDictionary *method in record[@"instanceMethods"]) LegacyWriteLine(textFile, [NSString stringWithFormat:@"  instance %@ types=%@ imp=%@ image=%@", method[@"selector"], method[@"typeEncoding"], method[@"imp"], method[@"impImage"]]);
            for (NSDictionary *method in record[@"classMethods"]) LegacyWriteLine(textFile, [NSString stringWithFormat:@"  class %@ types=%@ imp=%@ image=%@", method[@"selector"], method[@"typeEncoding"], method[@"imp"], method[@"impImage"]]);
            for (NSDictionary *property in record[@"properties"]) LegacyWriteLine(textFile, [NSString stringWithFormat:@"  property %@ %@", property[@"name"], property[@"attributes"]]);
            for (NSDictionary *ivar in record[@"ivars"]) LegacyWriteLine(textFile, [NSString stringWithFormat:@"  ivar %@ %@ offset=%@", ivar[@"name"], ivar[@"type"], ivar[@"offset"]]);
            total++; if (total % 25 == 0 || index == classCount - 1) { LegacyFlush(jsonFile); LegacyFlush(textFile); LegacyWriteCheckpoint(summaryURL, index + 1, total, LegacyFileOffset(jsonFile), LegacyFileOffset(textFile), classCount); }
        }
    }
    free(classes); LegacyFlush(jsonFile); LegacyFlush(textFile); fclose(jsonFile); fclose(textFile); BOOL complete = total == (NSUInteger)classCount && errors == 0; LegacyWriteJSONFile(summaryURL, @{ @"schemaVersion": @"legacy-2.1", @"complete": @(complete), @"classesEnriched": @(total), @"errorCount": @(errors), @"detailScope": @"all classes returned by objc_getClassList; declared methods, class methods, properties, ivars, selectors, encodings, IMPs and IMP images", @"limits": @"none imposed by the collector; one class record is held at a time", @"resumedFromCheckpoint": @(resume) }); if (complete) LegacyRemoveCheckpoint(summaryURL); return total;
}

NSUInteger LegacyWriteProtocols(NSURL *textURL, NSURL *jsonlURL, NSURL *summaryURL) {
    FILE *textFile = fopen(textURL.path.UTF8String, "wb");
    FILE *jsonFile = fopen(jsonlURL.path.UTF8String, "wb");
    if (!textFile || !jsonFile) {
        if (textFile) fclose(textFile);
        if (jsonFile) fclose(jsonFile);
        return 0;
    }
    unsigned count = 0;
    Protocol *__unsafe_unretained *protocols = objc_copyProtocolList(&count);
    NSUInteger written = 0;
    for (unsigned i = 0; i < count; i++) {
        @autoreleasepool {
            Protocol *protocol = protocols[i];
            NSString *name = LegacyCString(protocol_getName(protocol));
            unsigned adoptedCount = 0;
            Protocol *__unsafe_unretained *adoptedProtocols = protocol_copyProtocolList(protocol, &adoptedCount);
            NSMutableArray *adopted = [NSMutableArray arrayWithCapacity:adoptedCount];
            for (unsigned j = 0; j < adoptedCount; j++) {
                [adopted addObject:LegacyCString(protocol_getName(adoptedProtocols[j]))];
            }
            free(adoptedProtocols);
            NSDictionary *row = @{
                @"schemaVersion": @"legacy-2.0",
                @"protocol": name,
                @"adoptedProtocols": adopted
            };
            if (!LegacyWriteJSONLine(jsonFile, row)) continue;
            LegacyWriteLine(textFile, [NSString stringWithFormat:@"%@ adopted=%@", name, adopted.count ? [adopted componentsJoinedByString:@","] : @"NONE"]);
            written++;
            if (written % 250 == 0) {
                LegacyFlush(textFile);
                LegacyFlush(jsonFile);
            }
        }
    }
    free(protocols);
    LegacyFlush(textFile);
    LegacyFlush(jsonFile);
    fclose(textFile);
    fclose(jsonFile);
    LegacyWriteJSONFile(summaryURL, @{
        @"schemaVersion": @"legacy-2.0",
        @"complete": @YES,
        @"protocolListCount": @(count),
        @"protocolsWritten": @(written),
        @"limitReached": @NO
    });
    return written;
}

NSUInteger LegacyWriteLoadedImages(NSURL *textURL, NSURL *jsonlURL, NSURL *summaryURL) {
    FILE *textFile = fopen(textURL.path.UTF8String, "wb"); FILE *jsonFile = fopen(jsonlURL.path.UTF8String, "wb");
    if (!textFile || !jsonFile) { if (textFile) fclose(textFile); if (jsonFile) fclose(jsonFile); return 0; }
    uint32_t expected = _dyld_image_count(); NSUInteger written = 0, errors = 0;
    for (uint32_t i = 0; i < expected; i++) {
        @autoreleasepool {
            const char *name = _dyld_get_image_name(i); const struct mach_header *header = _dyld_get_image_header(i); intptr_t slide = _dyld_get_image_vmaddr_slide(i); NSString *path = LegacyCString(name);
            NSDictionary *row = @{ @"schemaVersion": @"legacy-2.1", @"index": @(i), @"path": path, @"imageName": path.lastPathComponent ?: @"NOT_AVAILABLE", @"baseAddress": [NSString stringWithFormat:@"%p", header], @"loadAddress": [NSString stringWithFormat:@"%p", header], @"aslrSlide": @(slide), @"uuid": @"NOT_AVAILABLE", @"architecture": @"arm64", @"machoMetadata": @"safe dyld metadata only" };
            if (!LegacyWriteJSONLine(jsonFile, row)) { errors++; continue; }
            LegacyWriteLine(textFile, [NSString stringWithFormat:@"%u path=%@ image=%@ base=%@ load=%@ slide=%ld uuid=NOT_AVAILABLE arch=arm64", i, path, row[@"imageName"], row[@"baseAddress"], row[@"loadAddress"], (long)slide]); written++;
            if (written % 100 == 0 || i + 1 == expected) { LegacyFlush(textFile); LegacyFlush(jsonFile); }
        }
    }
    LegacyFlush(textFile); LegacyFlush(jsonFile); fclose(textFile); fclose(jsonFile); BOOL complete = expected == written && errors == 0;
    LegacyWriteJSONFile(summaryURL, @{ @"schemaVersion": @"legacy-2.1", @"complete": @(complete), @"enumeratedImageCount": @(expected), @"writtenImageCount": @(written), @"loadedImageCount": @(written), @"recordErrors": @(errors), @"uuidStatus": @"NOT_AVAILABLE without additional Mach-O parsing", @"architecture": @"arm64" });
    return written;
}

static NSString *LegacyColor(CGColorRef color) {
    if (!color) return @"NOT_AVAILABLE";
    UIColor *uiColor = [UIColor colorWithCGColor:color];
    CGFloat red = 0, green = 0, blue = 0, alpha = 0;
    if ([uiColor getRed:&red green:&green blue:&blue alpha:&alpha]) {
        return [NSString stringWithFormat:@"rgba(%.3f, %.3f, %.3f, %.3f)", red, green, blue, alpha];
    }
    CGFloat white = 0;
    if ([uiColor getWhite:&white alpha:&alpha]) {
        return [NSString stringWithFormat:@"gray(%.3f, %.3f)", white, alpha];
    }
    return LegacySanitize(uiColor.description);
}

static NSString *LegacyViewLine(UIView *view) {
    if (!view) return @"VIEW NOT_AVAILABLE";
    CALayer *layer = nil;
    NSString *accessibilityIdentifier = @"NOT_AVAILABLE";
    NSString *accessibilityLabel = @"NOT_AVAILABLE";
    NSString *accessibilityValue = @"NOT_AVAILABLE";
    @try {
        layer = view.layer;
        accessibilityIdentifier = LegacySanitize(view.accessibilityIdentifier);
        accessibilityLabel = LegacySanitize(view.accessibilityLabel);
        accessibilityValue = LegacySanitize(view.accessibilityValue);
    } @catch (__unused NSException *exception) {
        // Optional UIKit fields remain NOT_AVAILABLE.
    }
    NSString *windowClass = view.window ? LegacyString(NSStringFromClass(view.window.class)) : @"NOT_AVAILABLE";
    NSString *superviewClass = view.superview ? LegacyString(NSStringFromClass(view.superview.class)) : @"NOT_AVAILABLE";
    NSString *layerClass = layer ? LegacyString(NSStringFromClass(layer.class)) : @"NOT_AVAILABLE";
    return [NSString stringWithFormat:
            @"%@ pointer=%p superclass=%@ frame=%@ bounds=%@ center=%@ transform=%@ alpha=%.3f hidden=%@ opaque=%@ clipsToBounds=%@ userInteractionEnabled=%@ contentMode=%ld tag=%ld backgroundColor=%@ tintColor=%@ window=%p/%@ superview=%p/%@ subviewCount=%lu layer=%p/%@ layerFrame=%@ layerBounds=%@ layerOpacity=%.3f layerHidden=%@ layerBackgroundColor=%@ cornerRadius=%.3f masksToBounds=%@ zPosition=%.3f accessibilityIdentifier=%@ accessibilityLabel=%@ accessibilityValue=%@",
            LegacyString(NSStringFromClass(view.class)), view,
            LegacyString(NSStringFromClass(view.superclass)), NSStringFromCGRect(view.frame), NSStringFromCGRect(view.bounds),
            NSStringFromCGPoint(view.center), NSStringFromCGAffineTransform(view.transform), view.alpha,
            view.hidden ? @"YES" : @"NO", view.opaque ? @"YES" : @"NO", view.clipsToBounds ? @"YES" : @"NO",
            view.userInteractionEnabled ? @"YES" : @"NO", (long)view.contentMode, (long)view.tag,
            LegacySanitize(view.backgroundColor.description), LegacySanitize(view.tintColor.description), view.window,
            windowClass, view.superview, superviewClass, (unsigned long)view.subviews.count, layer, layerClass,
            layer ? NSStringFromCGRect(layer.frame) : @"NOT_AVAILABLE", layer ? NSStringFromCGRect(layer.bounds) : @"NOT_AVAILABLE",
            layer ? layer.opacity : 0.0f, layer && layer.hidden ? @"YES" : @"NO", layer ? LegacyColor(layer.backgroundColor) : @"NOT_AVAILABLE",
            layer ? layer.cornerRadius : 0.0f, layer && layer.masksToBounds ? @"YES" : @"NO", layer ? layer.zPosition : 0.0f,
            accessibilityIdentifier, accessibilityLabel, accessibilityValue];
}

static NSValue *LegacyPointerKey(id object) {
    return [NSValue valueWithPointer:(__bridge const void *)(object)];
}

static NSArray<UIView *> *LegacySubviews(UIView *view) {
    @try {
        return [view.subviews copy] ?: @[];
    } @catch (__unused NSException *exception) {
        return @[];
    }
}

static void LegacyWalkView(UIView *view,
                           NSUInteger depth,
                           NSUInteger *nodes,
                           NSUInteger maxDepth,
                           NSUInteger maxNodes,
                           NSMutableSet *seen,
                           FILE *file,
                           BOOL *truncated,
                           NSUInteger *duplicateSkips,
                           NSUInteger *maxDepthObserved) {
    if (!view) return;
    if (maxDepthObserved) *maxDepthObserved = MAX(*maxDepthObserved, depth);
    if (depth > maxDepth) {
        if (truncated) *truncated = YES;
        return;
    }
    if (*nodes >= maxNodes) {
        if (truncated) *truncated = YES;
        return;
    }
    NSValue *key = LegacyPointerKey(view);
    if ([seen containsObject:key]) {
        if (duplicateSkips) (*duplicateSkips)++;
        return;
    }
    [seen addObject:key];
    (*nodes)++;
    NSString *indent = [@"" stringByPaddingToLength:MIN(depth * 2, 1024) withString:@" " startingAtIndex:0];
    LegacyWriteLine(file, [NSString stringWithFormat:@"%@%@", indent, LegacyViewLine(view)]);
    for (UIView *child in LegacySubviews(view)) {
        LegacyWalkView(child, depth + 1, nodes, maxDepth, maxNodes, seen, file, truncated, duplicateSkips, maxDepthObserved);
    }
}

NSUInteger LegacyWriteVisibleHierarchy(UIWindow *host, NSURL *url, NSUInteger maxDepth, NSUInteger maxNodes, BOOL *truncated) {
    if (truncated) *truncated = NO;
    if (!host || !url) return 0;
    FILE *file = fopen(url.path.UTF8String, "wb");
    if (!file) return 0;
    LegacyWriteLine(file, @"VIEW_TREE_LEGACY.txt");
    NSUInteger nodes = 0;
    NSUInteger duplicates = 0;
    NSUInteger maxDepthObserved = 0;
    BOOL didTruncate = NO;
    LegacyWalkView(host, 0, &nodes, maxDepth, maxNodes, [NSMutableSet set], file, &didTruncate, &duplicates, &maxDepthObserved);
    LegacyWriteLine(file, [NSString stringWithFormat:@"SUMMARY nodes=%lu maxDepthObserved=%lu maxDepth=%lu maxNodes=%lu LIMIT_REACHED=%@ duplicateSkips=%lu",
                               (unsigned long)nodes, (unsigned long)maxDepthObserved, (unsigned long)maxDepth,
                               (unsigned long)maxNodes, didTruncate ? @"YES" : @"NO", (unsigned long)duplicates]);
    LegacyFlush(file);
    fclose(file);
    if (truncated) *truncated = didTruncate;
    return nodes;
}

static NSArray<UIWindow *> *LegacyAllWindows(UIWindow *host) {
    UIApplication *application = UIApplication.sharedApplication;
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window && ![windows containsObject:window]) [windows addObject:window];
        }
    }
    if (windows.count == 0) {
        @try {
            for (UIWindow *window in application.windows) {
                if (window && ![windows containsObject:window]) [windows addObject:window];
            }
        } @catch (__unused NSException *exception) {
        }
    }
    if (host && ![windows containsObject:host]) [windows insertObject:host atIndex:0];
    return windows;
}

NSUInteger LegacyWriteWindowHierarchy(NSURL *url,
                                      NSUInteger maxDepth,
                                      NSUInteger maxNodes,
                                      BOOL *truncated,
                                      NSUInteger *windowCount,
                                      NSUInteger *duplicateSkips,
                                      NSUInteger *maxDepthObserved) {
    if (truncated) *truncated = NO;
    if (windowCount) *windowCount = 0;
    if (duplicateSkips) *duplicateSkips = 0;
    if (maxDepthObserved) *maxDepthObserved = 0;
    if (!url) return 0;
    FILE *file = fopen(url.path.UTF8String, "wb");
    if (!file) return 0;
    NSArray<UIWindow *> *windows = LegacyAllWindows(nil);
    NSMutableSet *seen = [NSMutableSet set];
    NSUInteger nodes = 0;
    BOOL didTruncate = NO;
    LegacyWriteLine(file, @"VIEW_TREE_WINDOWS.txt");
    for (UIWindow *window in windows) {
        @autoreleasepool {
            UIWindowScene *scene = window.windowScene;
            LegacyWriteLine(file, [NSString stringWithFormat:@"WINDOW pointer=%p class=%@ frame=%@ bounds=%@ windowLevel=%.3f hidden=%@ alpha=%.3f keyWindow=%@ rootViewController=%@ scene=%p sceneState=%ld",
                               window, LegacyString(NSStringFromClass(window.class)), NSStringFromCGRect(window.frame), NSStringFromCGRect(window.bounds),
                               window.windowLevel, window.hidden ? @"YES" : @"NO", window.alpha, window.isKeyWindow ? @"YES" : @"NO",
                               window.rootViewController ? LegacyString(NSStringFromClass(window.rootViewController.class)) : @"NOT_AVAILABLE",
                               scene, (long)scene.activationState]);
            if (windowCount) (*windowCount)++;
            LegacyWalkView(window, 0, &nodes, maxDepth, maxNodes, seen, file, &didTruncate, duplicateSkips, maxDepthObserved);
        }
    }
    LegacyWriteLine(file, [NSString stringWithFormat:@"SUMMARY windows=%lu nodes=%lu maxDepthObserved=%lu LIMIT_REACHED=%@ duplicateSkips=%lu",
                               (unsigned long)(windowCount ? *windowCount : windows.count), (unsigned long)nodes,
                               (unsigned long)(maxDepthObserved ? *maxDepthObserved : 0), didTruncate ? @"YES" : @"NO",
                               (unsigned long)(duplicateSkips ? *duplicateSkips : 0)]);
    LegacyFlush(file);
    fclose(file);
    if (truncated) *truncated = didTruncate;
    return nodes;
}

static NSArray<UIViewController *> *LegacyControllerChildren(UIViewController *controller) {
    NSMutableArray<UIViewController *> *children = [NSMutableArray array];
    @try {
        [children addObjectsFromArray:controller.childViewControllers ?: @[]];
        if ([controller isKindOfClass:UINavigationController.class]) {
            [children addObjectsFromArray:((UINavigationController *)controller).viewControllers ?: @[]];
        }
        if ([controller isKindOfClass:UITabBarController.class]) {
            [children addObjectsFromArray:((UITabBarController *)controller).viewControllers ?: @[]];
        }
        if ([controller isKindOfClass:UISplitViewController.class]) {
            [children addObjectsFromArray:((UISplitViewController *)controller).viewControllers ?: @[]];
        }
        if (controller.presentedViewController) [children addObject:controller.presentedViewController];
    } @catch (__unused NSException *exception) {
    }
    NSMutableArray<UIViewController *> *unique = [NSMutableArray array];
    for (UIViewController *child in children) {
        if (child && ![unique containsObject:child]) [unique addObject:child];
    }
    return unique;
}

static void LegacyCollectController(UIViewController *controller,
                                     NSUInteger depth,
                                     NSUInteger maxDepth,
                                     NSUInteger maxNodes,
                                     NSMutableSet *seen,
                                     NSMutableArray<UIViewController *> *controllers,
                                     BOOL *truncated,
                                     NSUInteger *duplicateSkips,
                                     NSUInteger *maxDepthObserved) {
    if (!controller) return;
    if (maxDepthObserved) *maxDepthObserved = MAX(*maxDepthObserved, depth);
    if (depth > maxDepth) {
        if (truncated) *truncated = YES;
        return;
    }
    NSValue *key = LegacyPointerKey(controller);
    if ([seen containsObject:key]) {
        if (duplicateSkips) (*duplicateSkips)++;
        return;
    }
    if (controllers.count >= maxNodes) {
        if (truncated) *truncated = YES;
        return;
    }
    [seen addObject:key];
    [controllers addObject:controller];
    for (UIViewController *child in LegacyControllerChildren(controller)) {
        LegacyCollectController(child, depth + 1, maxDepth, maxNodes, seen, controllers, truncated, duplicateSkips, maxDepthObserved);
    }
}

static NSString *LegacyControllerClass(UIViewController *controller) {
    return controller ? LegacyString(NSStringFromClass(controller.class)) : @"NOT_AVAILABLE";
}

static NSString *LegacyControllerList(NSArray<UIViewController *> *controllers) {
    if (!controllers.count) return @"NONE";
    NSMutableArray *names = [NSMutableArray arrayWithCapacity:controllers.count];
    for (UIViewController *controller in controllers) [names addObject:[NSString stringWithFormat:@"%@(%p)", LegacyControllerClass(controller), controller]];
    return [names componentsJoinedByString:@", "];
}

static void LegacyWriteControllerRecord(FILE *controllersFile, FILE *treeFile, FILE *mapFile, UIViewController *controller) {
    if (!controller) return;
    UIView *view = controller.isViewLoaded ? controller.view : nil;
    NSArray *children = controller.childViewControllers ?: @[];
    NSString *navigationStack = @"NONE";
    if ([controller isKindOfClass:UINavigationController.class]) navigationStack = LegacyControllerList(((UINavigationController *)controller).viewControllers);
    NSString *tabControllers = @"NONE";
    if ([controller isKindOfClass:UITabBarController.class]) tabControllers = LegacyControllerList(((UITabBarController *)controller).viewControllers);
    NSString *splitControllers = @"NONE";
    if ([controller isKindOfClass:UISplitViewController.class]) splitControllers = LegacyControllerList(((UISplitViewController *)controller).viewControllers);
    LegacyWriteLine(controllersFile, [NSString stringWithFormat:
                                      @"class=%@ pointer=%p superclass=%@ parent=%p presenting=%p presented=%p childCount=%lu children=%@ navigationStack=%@ tabControllers=%@ splitControllers=%@ viewLoaded=%@ view=%p/%@ viewWindow=%p/%@",
                                      LegacyControllerClass(controller), controller, LegacyString(NSStringFromClass(controller.superclass)), controller.parentViewController,
                                      controller.presentingViewController, controller.presentedViewController, (unsigned long)children.count,
                                      LegacyControllerList(children), navigationStack, tabControllers, splitControllers, controller.isViewLoaded ? @"YES" : @"NO",
                                      view, view ? LegacyString(NSStringFromClass(view.class)) : @"NOT_AVAILABLE", view.window,
                                      view.window ? LegacyString(NSStringFromClass(view.window.class)) : @"NOT_AVAILABLE"]);
    LegacyWriteLine(treeFile, [NSString stringWithFormat:@"%@(%p) parent=%p children=%@ presented=%p presenting=%p",
                               LegacyControllerClass(controller), controller, controller.parentViewController, LegacyControllerList(children),
                               controller.presentedViewController, controller.presentingViewController]);
    LegacyWriteLine(mapFile, [NSString stringWithFormat:@"controller=%@(%p) viewLoaded=%@ view=%p class=%@ window=%p windowClass=%@",
                              LegacyControllerClass(controller), controller, controller.isViewLoaded ? @"YES" : @"NO", view,
                              view ? LegacyString(NSStringFromClass(view.class)) : @"NOT_AVAILABLE", view.window,
                              view.window ? LegacyString(NSStringFromClass(view.window.class)) : @"NOT_AVAILABLE"]);
}

NSUInteger LegacyWriteControllers(UIWindow *host,
                                  NSURL *controllersURL,
                                  NSURL *treeURL,
                                  NSURL *viewMapURL,
                                  NSUInteger maxDepth,
                                  NSUInteger maxNodes,
                                  BOOL *truncated,
                                  NSUInteger *duplicateSkips,
                                  NSUInteger *maxDepthObserved) {
    if (truncated) *truncated = NO;
    if (duplicateSkips) *duplicateSkips = 0;
    if (maxDepthObserved) *maxDepthObserved = 0;
    FILE *controllersFile = fopen(controllersURL.path.UTF8String, "wb");
    FILE *treeFile = fopen(treeURL.path.UTF8String, "wb");
    FILE *mapFile = fopen(viewMapURL.path.UTF8String, "wb");
    if (!controllersFile || !treeFile || !mapFile) {
        if (controllersFile) fclose(controllersFile);
        if (treeFile) fclose(treeFile);
        if (mapFile) fclose(mapFile);
        return 0;
    }
    LegacyWriteLine(controllersFile, @"CONTROLLERS.txt");
    LegacyWriteLine(treeFile, @"CONTROLLER_TREE.txt");
    LegacyWriteLine(mapFile, @"CONTROLLER_VIEW_MAP.txt");
    NSArray<UIWindow *> *windows = LegacyAllWindows(host);
    NSMutableSet *seen = [NSMutableSet set];
    NSMutableArray<UIViewController *> *controllers = [NSMutableArray array];
    BOOL didTruncate = NO;
    for (UIWindow *window in windows) {
        if (window.rootViewController) {
            LegacyCollectController(window.rootViewController, 0, maxDepth, maxNodes, seen, controllers, &didTruncate, duplicateSkips, maxDepthObserved);
        }
    }
    for (UIViewController *controller in controllers) {
        @autoreleasepool {
            LegacyWriteControllerRecord(controllersFile, treeFile, mapFile, controller);
            if (controllers.count % 100 == 0) {
                LegacyFlush(controllersFile);
                LegacyFlush(treeFile);
                LegacyFlush(mapFile);
            }
        }
    }
    LegacyWriteLine(controllersFile, [NSString stringWithFormat:@"SUMMARY controllers=%lu maxDepthObserved=%lu maxDepth=%lu maxNodes=%lu LIMIT_REACHED=%@ duplicateSkips=%lu",
                                      (unsigned long)controllers.count, (unsigned long)(maxDepthObserved ? *maxDepthObserved : 0),
                                      (unsigned long)maxDepth, (unsigned long)maxNodes, didTruncate ? @"YES" : @"NO",
                                      (unsigned long)(duplicateSkips ? *duplicateSkips : 0)]);
    LegacyFlush(controllersFile);
    LegacyFlush(treeFile);
    LegacyFlush(mapFile);
    fclose(controllersFile);
    fclose(treeFile);
    fclose(mapFile);
    if (truncated) *truncated = didTruncate;
    return controllers.count;
}

NSUInteger LegacyWriteControllerViewHierarchy(UIWindow *host,
                                              NSURL *url,
                                              NSUInteger maxDepth,
                                              NSUInteger maxNodes,
                                              BOOL *truncated,
                                              NSUInteger *duplicateSkips,
                                              NSUInteger *maxDepthObserved) {
    if (truncated) *truncated = NO;
    if (duplicateSkips) *duplicateSkips = 0;
    if (maxDepthObserved) *maxDepthObserved = 0;
    if (!url) return 0;
    FILE *file = fopen(url.path.UTF8String, "wb");
    if (!file) return 0;
    LegacyWriteLine(file, @"VIEW_TREE_CONTROLLERS.txt");
    NSArray<UIWindow *> *windows = LegacyAllWindows(host);
    NSMutableSet *controllerSeen = [NSMutableSet set];
    NSMutableArray<UIViewController *> *controllers = [NSMutableArray array];
    BOOL didTruncate = NO;
    for (UIWindow *window in windows) {
        if (window.rootViewController) LegacyCollectController(window.rootViewController, 0, maxDepth, maxNodes, controllerSeen, controllers, &didTruncate, duplicateSkips, maxDepthObserved);
    }
    NSMutableSet *viewSeen = [NSMutableSet set];
    NSUInteger viewNodes = 0;
    for (UIViewController *controller in controllers) {
        @autoreleasepool {
            if (!controller.isViewLoaded || !controller.view) continue;
            LegacyWriteLine(file, [NSString stringWithFormat:@"CONTROLLER_ROOT %@(%p) view=%p", LegacyControllerClass(controller), controller, controller.view]);
            LegacyWalkView(controller.view, 0, &viewNodes, maxDepth, maxNodes, viewSeen, file, &didTruncate, duplicateSkips, maxDepthObserved);
        }
    }
    LegacyWriteLine(file, [NSString stringWithFormat:@"SUMMARY controllers=%lu viewNodes=%lu maxDepthObserved=%lu LIMIT_REACHED=%@ duplicateSkips=%lu",
                               (unsigned long)controllers.count, (unsigned long)viewNodes,
                               (unsigned long)(maxDepthObserved ? *maxDepthObserved : 0), didTruncate ? @"YES" : @"NO",
                               (unsigned long)(duplicateSkips ? *duplicateSkips : 0)]);
    LegacyFlush(file);
    fclose(file);
    if (truncated) *truncated = didTruncate;
    return viewNodes;
}

static UIViewController *LegacyVisibleController(UIViewController *root) {
    UIViewController *current = root;
    for (NSUInteger step = 0; current && step < 256; step++) {
        UIViewController *next = current.presentedViewController;
        if (!next && [current isKindOfClass:UINavigationController.class]) next = ((UINavigationController *)current).visibleViewController;
        if (!next && [current isKindOfClass:UITabBarController.class]) next = ((UITabBarController *)current).selectedViewController;
        if (!next && [current isKindOfClass:UISplitViewController.class]) {
            for (UIViewController *candidate in [((UISplitViewController *)current).viewControllers reverseObjectEnumerator]) {
                if (candidate.viewIfLoaded.window || candidate.isViewLoaded) { next = candidate; break; }
            }
        }
        if (!next || next == current) break;
        current = next;
    }
    return current;
}

NSUInteger LegacyWriteVisibleControllerHierarchy(UIWindow *host,
                                                  NSURL *url,
                                                  NSUInteger maxDepth,
                                                  NSUInteger maxNodes,
                                                  BOOL *truncated,
                                                  NSUInteger *duplicateSkips,
                                                  NSUInteger *maxDepthObserved) {
    if (truncated) *truncated = NO;
    if (duplicateSkips) *duplicateSkips = 0;
    if (maxDepthObserved) *maxDepthObserved = 0;
    if (!url) return 0;
    FILE *file = fopen(url.path.UTF8String, "wb");
    if (!file) return 0;
    LegacyWriteLine(file, @"VIEW_TREE_VISIBLE_CONTROLLER.txt");
    UIWindow *window = host ?: LegacyAllWindows(nil).firstObject;
    UIViewController *controller = LegacyVisibleController(window.rootViewController);
    BOOL didTruncate = NO;
    NSUInteger nodes = 0;
    if (controller) {
        LegacyWriteLine(file, [NSString stringWithFormat:@"VISIBLE_CONTROLLER class=%@ pointer=%p viewLoaded=%@ view=%p",
                               LegacyControllerClass(controller), controller, controller.isViewLoaded ? @"YES" : @"NO", controller.isViewLoaded ? controller.view : nil]);
        if (controller.isViewLoaded && controller.view) {
            LegacyWalkView(controller.view, 0, &nodes, maxDepth, maxNodes, [NSMutableSet set], file, &didTruncate, duplicateSkips, maxDepthObserved);
        } else {
            LegacyWriteLine(file, @"VISIBLE_CONTROLLER_VIEW NOT_AVAILABLE");
        }
    } else {
        LegacyWriteLine(file, @"VISIBLE_CONTROLLER NOT_AVAILABLE");
    }
    LegacyWriteLine(file, [NSString stringWithFormat:@"SUMMARY nodes=%lu maxDepthObserved=%lu LIMIT_REACHED=%@ duplicateSkips=%lu",
                           (unsigned long)nodes, (unsigned long)(maxDepthObserved ? *maxDepthObserved : 0),
                           didTruncate ? @"YES" : @"NO", (unsigned long)(duplicateSkips ? *duplicateSkips : 0)]);
    LegacyFlush(file);
    fclose(file);
    if (truncated) *truncated = didTruncate;
    return nodes;
}
