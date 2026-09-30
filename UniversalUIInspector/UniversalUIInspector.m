// UniversalUIInspector.m — read-only UIKit/runtime diagnostics.
// The manual collectors remain the source of truth; the coordinator only sequences them.
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <zlib.h>
#import <errno.h>
#import <sys/stat.h>
#import <unistd.h>
#import <mach/mach.h>
#import <CommonCrypto/CommonDigest.h>
#include <stdint.h>
#include <limits.h>
#include <math.h>
#import "LegacyCollectors.h"
#import "UnityInspection.h"
#import "VisitedScreenRecorder.h"

#ifndef UUI_BUILD_VERSION
#define UUI_BUILD_VERSION "2.3.0"
#endif
#ifndef UUI_SOURCE_REVISION
#define UUI_SOURCE_REVISION "unversioned"
#endif
#ifndef UUI_BUILD_TIMESTAMP_UTC
#define UUI_BUILD_TIMESTAMP_UTC "unknown"
#endif

NSDictionary *UUIBuildMetadata(void) {
    return @{ @"version": @UUI_BUILD_VERSION, @"sourceRevision": @UUI_SOURCE_REVISION, @"buildTimestampUTC": @UUI_BUILD_TIMESTAMP_UTC };
}
static NSString *UIIBuildLine(void) {
    NSDictionary *build = UUIBuildMetadata();
    return [NSString stringWithFormat:@"# BUILD version=%@ sourceRevision=%@ buildTimestampUTC=%@\n", build[@"version"], build[@"sourceRevision"], build[@"buildTimestampUTC"]];
}

static NSString * const kUIID = @"UniversalUIInspector";
static const BOOL kDiagnosticStabilityBuild = YES;
static const NSTimeInterval kPassiveStartupSeconds = 120.0;
static const NSTimeInterval kLightweightWarmupSeconds = 120.0;
static const NSTimeInterval kLightweightSampleInterval = 5.0;
static const NSUInteger kRequiredLightweightStableChecks = 6;
static const NSUInteger kFullCaptureMaxDepth = 256;
static const NSUInteger kFullCaptureMaxNodes = 500000;
static const NSUInteger kSnapshotMaxDepth = 256;
static const NSUInteger kSnapshotMaxViews = 20000;
static const NSUInteger kSnapshotMaxControllers = 5000;
static const NSUInteger kUnityMaxSnapshots = 12;

static NSString *UIIString(NSString *value) { return value.length ? value : @"NOT_AVAILABLE"; }
static NSString *UIICString(const char *value) { return value && *value ? [NSString stringWithUTF8String:value] : @"NOT_AVAILABLE"; }
static NSString *UIISanitize(NSString *value) {
    NSString *s = UIIString(value);
    return [[s stringByReplacingOccurrencesOfString:@"\r" withString:@"\\r"] stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
}
static NSString *UIIColor(UIColor *color) {
    if (!color) return @"NOT_AVAILABLE";
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if ([color getRed:&r green:&g blue:&b alpha:&a]) return [NSString stringWithFormat:@"rgba(%.3f, %.3f, %.3f, %.3f)", r, g, b, a];
    CGFloat white = 0;
    if ([color getWhite:&white alpha:&a]) return [NSString stringWithFormat:@"gray(%.3f, %.3f)", white, a];
    return UIISanitize(color.description);
}
static NSURL *UIIDocuments(void) {
    return [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] firstObject];
}
static NSURL *ReportsDirectory(void) {
    NSURL *dir = [UIIDocuments() URLByAppendingPathComponent:kUIID isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}
static void WriteTextURL(NSURL *url, NSString *text) {
    if (!url) return;
    NSString *payload = [UIIBuildLine() stringByAppendingString:text ?: @""];
    [[payload dataUsingEncoding:NSUTF8StringEncoding] writeToURL:url options:NSDataWritingAtomic error:nil];
}
static void WriteJSONURL(NSURL *url, NSDictionary *object) {
    if (!url || !object) return;
    NSMutableDictionary *payload = [object mutableCopy];
    if (!payload[@"build"]) payload[@"build"] = UUIBuildMetadata();
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:NSJSONWritingPrettyPrinted error:nil];
    if (data) [data writeToURL:url options:NSDataWritingAtomic error:nil];
}
static void WriteReport(NSString *name, NSString *text) {
    WriteTextURL([ReportsDirectory() URLByAppendingPathComponent:name], text);
}
static NSString *ReportPath(NSString *name) {
    return [[ReportsDirectory() URLByAppendingPathComponent:name] path];
}
static NSString *DateString(NSDate *date) {
    static NSISO8601DateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ formatter = [NSISO8601DateFormatter new]; });
    return [formatter stringFromDate:date ?: [NSDate date]];
}

static NSString *UIIFileSHA256(NSURL *url) {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:url.path]; if (!handle) return @"NOT_AVAILABLE";
    CC_SHA256_CTX ctx; CC_SHA256_Init(&ctx); BOOL ok = YES;
    @try { while (YES) { NSData *chunk = [handle readDataOfLength:1024 * 1024]; if (!chunk.length) break; CC_SHA256_Update(&ctx, chunk.bytes, (CC_LONG)chunk.length); } } @catch (__unused NSException *exception) { ok = NO; }
    [handle closeFile]; if (!ok) return @"NOT_AVAILABLE"; unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(digest, &ctx); NSMutableString *hex = [NSMutableString stringWithCapacity:64]; for (NSUInteger i=0;i<CC_SHA256_DIGEST_LENGTH;i++) [hex appendFormat:@"%02x",digest[i]]; return hex;
}
static BOOL UIIValidateJSONFile(NSURL *url, NSString **reason) {
    NSData *data = [NSData dataWithContentsOfURL:url]; if (!data.length) { if (reason) *reason = @"empty JSON file"; return NO; }
    NSError *error = nil; id value = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:&error]; if (!value || error) { if (reason) *reason = error.localizedDescription ?: @"invalid JSON"; return NO; } return YES;
}
static BOOL UIIValidatePNGFile(NSURL *url, NSString **reason) {
    NSData *data = [NSData dataWithContentsOfURL:url]; if (data.length < 24) { if (reason) *reason = @"PNG shorter than header"; return NO; }
    const uint8_t *b = data.bytes; static const uint8_t sig[8] = {137,80,78,71,13,10,26,10}; if (memcmp(b,sig,8) || memcmp(b+12,"IHDR",4)) { if (reason) *reason = @"invalid PNG signature/IHDR"; return NO; }
    uint32_t w = ((uint32_t)b[16]<<24)|((uint32_t)b[17]<<16)|((uint32_t)b[18]<<8)|b[19]; uint32_t h = ((uint32_t)b[20]<<24)|((uint32_t)b[21]<<16)|((uint32_t)b[22]<<8)|b[23]; if (!w || !h) { if (reason) *reason = @"PNG has zero dimensions"; return NO; } return YES;
}
static NSString *UIIScreenCoverageStatus(NSURL *indexURL) {
    NSData *data = [NSData dataWithContentsOfURL:indexURL]; NSDictionary *root = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil; NSArray *screens = [root[@"screens"] isKindOfClass:NSArray.class] ? root[@"screens"] : @[]; if (!screens.count || [root[@"limit_reached"] boolValue]) return @"PARTIAL";
    for (NSDictionary *screen in screens) { NSArray *states = [screen[@"states"] isKindOfClass:NSArray.class] ? screen[@"states"] : @[]; if (!states.count) return @"PARTIAL"; for (NSDictionary *state in states) if (![state[@"status"] isEqualToString:@"CAPTURED"]) return @"PARTIAL"; }
    return @"CAPTURE_COMPLETE_OBSERVED_SCREENS_ONLY";
}
static NSString *UIIFileChecksum(NSURL *url) {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:url.path]; if (!handle) return @"NOT_AVAILABLE";
    uLong checksum = crc32(0L, Z_NULL, 0);
    @try { while (YES) { NSData *chunk = [handle readDataOfLength:1024 * 1024]; if (!chunk.length) break; checksum = crc32(checksum, chunk.bytes, (uInt)chunk.length); } } @catch (__unused NSException *exception) { [handle closeFile]; return @"NOT_AVAILABLE"; }
    [handle closeFile]; return [NSString stringWithFormat:@"crc32:%08lx", (unsigned long)checksum];
}
static BOOL UIIFileEndsWithNewline(NSURL *url) {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:url.path]; if (!handle) return NO; unsigned long long length = handle.seekToEndOfFile; if (!length) { [handle closeFile]; return YES; } [handle seekToFileOffset:length - 1]; NSData *last = [handle readDataOfLength:1]; [handle closeFile]; return last.length == 1 && ((const uint8_t *)last.bytes)[0] == '\n';
}

static NSUInteger UIIFileLineCount(NSURL *url) {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:url.path]; if (!handle) return 0; NSData *prefix = [handle readDataOfLength:8]; BOOL hasBuildBanner = [[NSString alloc] initWithData:prefix encoding:NSUTF8StringEncoding].length && [[[NSString alloc] initWithData:prefix encoding:NSUTF8StringEncoding] hasPrefix:@"# BUILD "]; [handle seekToFileOffset:0]; NSUInteger count = 0; @try { while (YES) { NSData *chunk = [handle readDataOfLength:1024 * 1024]; if (!chunk.length) break; const uint8_t *bytes = chunk.bytes; for (NSUInteger i = 0; i < chunk.length; i++) if (bytes[i] == '\n') count++; } } @catch (__unused NSException *exception) { } [handle closeFile]; return hasBuildBanner && count ? count - 1 : count;
}

static BOOL UIIValidateJSONL(NSURL *url, NSUInteger *records, NSString **reason) {
    if (records) *records = 0; NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:url.path]; if (!handle) { if (reason) *reason = @"cannot open JSONL"; return NO; }
    NSMutableData *pending = [NSMutableData data]; BOOL valid = YES;
    while (valid) {
        NSData *chunk = [handle readDataOfLength:1024 * 1024]; if (!chunk.length) break; [pending appendData:chunk];
        while (YES) { const uint8_t *bytes = pending.bytes; const uint8_t *newline = memchr(bytes, '\n', pending.length); if (!newline) break; NSUInteger length = (NSUInteger)(newline - bytes); if (length && ((const uint8_t *)bytes)[length - 1] == '\r') length--; NSData *line = [pending subdataWithRange:NSMakeRange(0, length)]; if (line.length && ![NSJSONSerialization JSONObjectWithData:line options:0 error:nil]) { valid = NO; if (reason) *reason = [NSString stringWithFormat:@"invalid JSONL record %lu", (unsigned long)(records ? *records + 1 : 0)]; break; } if (line.length && records) (*records)++; [pending replaceBytesInRange:NSMakeRange(0, (NSUInteger)(newline - bytes) + 1) withBytes:NULL length:0]; }
    }
    [handle closeFile]; if (valid && pending.length) { valid = NO; if (reason) *reason = @"JSONL ends mid-record without newline"; } if (valid && !UIIFileEndsWithNewline(url) && records && *records) { valid = NO; if (reason) *reason = @"JSONL missing final newline"; } return valid;
}

#pragma mark - Small ZIP support for manual/small exports

static void ZipU16(NSMutableData *data, uint16_t value) { [data appendBytes:&value length:sizeof(value)]; }
static void ZipU32(NSMutableData *data, uint32_t value) { [data appendBytes:&value length:sizeof(value)]; }
static NSData *ZipData(NSDictionary<NSString *, NSData *> *files) {
    NSMutableData *zip = [NSMutableData data];
    NSMutableArray<NSData *> *central = [NSMutableArray array];
    for (NSString *name in [files.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSData *fileData = files[name] ?: [NSData data];
        NSData *nameData = [name dataUsingEncoding:NSUTF8StringEncoding];
        uint32_t crc = (uint32_t)crc32(0, fileData.bytes, (uInt)MIN(fileData.length, UINT_MAX));
        uint32_t size = (uint32_t)MIN(fileData.length, UINT32_MAX);
        uint32_t offset = (uint32_t)MIN(zip.length, UINT32_MAX);
        ZipU32(zip, 0x04034b50); ZipU16(zip, 20); ZipU16(zip, 0x0800); ZipU16(zip, 0); ZipU16(zip, 0); ZipU16(zip, 0); ZipU32(zip, crc); ZipU32(zip, size); ZipU32(zip, size); ZipU16(zip, (uint16_t)nameData.length); ZipU16(zip, 0);
        [zip appendData:nameData]; [zip appendData:[fileData subdataWithRange:NSMakeRange(0, size)]];
        NSMutableData *entry = [NSMutableData data];
        ZipU32(entry, 0x02014b50); ZipU16(entry, 20); ZipU16(entry, 20); ZipU16(entry, 0x0800); ZipU16(entry, 0); ZipU16(entry, 0); ZipU16(entry, 0); ZipU32(entry, crc); ZipU32(entry, size); ZipU32(entry, size); ZipU16(entry, (uint16_t)nameData.length); ZipU16(entry, 0); ZipU16(entry, 0); ZipU16(entry, 0); ZipU16(entry, 0); ZipU32(entry, 0); ZipU32(entry, offset); [entry appendData:nameData];
        [central addObject:entry];
    }
    uint32_t centralOffset = (uint32_t)MIN(zip.length, UINT32_MAX);
    for (NSData *entry in central) [zip appendData:entry];
    uint32_t centralSize = (uint32_t)MIN(zip.length - centralOffset, UINT32_MAX);
    ZipU32(zip, 0x06054b50); ZipU16(zip, 0); ZipU16(zip, 0); ZipU16(zip, (uint16_t)MIN(central.count, UINT16_MAX)); ZipU16(zip, (uint16_t)MIN(central.count, UINT16_MAX)); ZipU32(zip, centralSize); ZipU32(zip, centralOffset); ZipU16(zip, 0);
    return zip;
}

static BOOL ValidateZipArchive(NSData *data, NSUInteger *fileCount, NSString **reason) {
    if (fileCount) *fileCount = 0;
    const uint8_t *bytes = data.bytes;
    NSUInteger length = data.length;
    if (!bytes || length < 22) { if (reason) *reason = @"archive shorter than EOCD"; return NO; }
    NSInteger eocd = -1;
    NSInteger start = (NSInteger)length - 22;
    NSInteger end = MAX(-1, (NSInteger)length - 65558);
    for (NSInteger i = start; i > end; i--) {
        uint32_t signature = 0; memcpy(&signature, bytes + i, sizeof(signature));
        if (signature == 0x06054b50) { eocd = i; break; }
    }
    if (eocd < 0) { if (reason) *reason = @"end-of-central-directory signature not found"; return NO; }
    uint16_t expected = 0; uint32_t size = 0, offset = 0;
    memcpy(&expected, bytes + eocd + 10, sizeof(expected)); memcpy(&size, bytes + eocd + 12, sizeof(size)); memcpy(&offset, bytes + eocd + 16, sizeof(offset));
    if ((NSUInteger)offset + (NSUInteger)size > (NSUInteger)eocd) { if (reason) *reason = @"central directory bounds invalid"; return NO; }
    NSUInteger position = offset, seen = 0;
    while (position < (NSUInteger)offset + (NSUInteger)size) {
        if (position + 46 > length) { if (reason) *reason = @"central directory entry truncated"; return NO; }
        uint32_t signature = 0; memcpy(&signature, bytes + position, sizeof(signature));
        if (signature != 0x02014b50) { if (reason) *reason = @"central directory entry invalid"; return NO; }
        uint16_t nameLength = 0, extraLength = 0, commentLength = 0;
        memcpy(&nameLength, bytes + position + 28, sizeof(nameLength)); memcpy(&extraLength, bytes + position + 30, sizeof(extraLength)); memcpy(&commentLength, bytes + position + 32, sizeof(commentLength));
        NSUInteger entryLength = 46 + nameLength + extraLength + commentLength;
        if (position + entryLength > length) { if (reason) *reason = @"central entry length invalid"; return NO; }
        position += entryLength; seen++;
    }
    if (seen != expected) { if (reason) *reason = [NSString stringWithFormat:@"entry count mismatch expected=%u seen=%lu", expected, (unsigned long)seen]; return NO; }
    if (fileCount) *fileCount = seen;
    return YES;
}

#pragma mark - Streaming ZIP for full sessions

static BOOL StreamFile(NSURL *fileURL, NSFileHandle *output, BOOL writeBytes, uint32_t *crcOut, uint64_t *sizeOut, NSString **errorOut) {
    NSFileHandle *input = [NSFileHandle fileHandleForReadingAtPath:fileURL.path];
    if (!input) { if (errorOut) *errorOut = [NSString stringWithFormat:@"cannot open %@", fileURL.path]; return NO; }
    uint32_t crc = 0; uint64_t size = 0; BOOL ok = YES;
    @try {
        while (YES) {
            NSData *chunk = [input readDataOfLength:1024 * 1024];
            if (!chunk.length) break;
            if (chunk.length > UINT_MAX || size > UINT64_MAX - chunk.length) { ok = NO; break; }
            crc = (uint32_t)crc32(crc, chunk.bytes, (uInt)chunk.length);
            size += chunk.length;
            if (writeBytes) [output writeData:chunk];
        }
    } @catch (NSException *exception) {
        ok = NO;
        if (errorOut) *errorOut = exception.reason ?: @"exception while streaming file";
    }
    [input closeFile];
    if (!ok && errorOut && !*errorOut) *errorOut = @"file streaming failed";
    if (crcOut) *crcOut = crc;
    if (sizeOut) *sizeOut = size;
    return ok;
}

static NSData *ZipLocalHeader(NSData *name, uint32_t crc, uint32_t size) {
    NSMutableData *header = [NSMutableData data];
    ZipU32(header, 0x04034b50); ZipU16(header, 20); ZipU16(header, 0x0800); ZipU16(header, 0); ZipU16(header, 0); ZipU16(header, 0); ZipU32(header, crc); ZipU32(header, size); ZipU32(header, size); ZipU16(header, (uint16_t)name.length); ZipU16(header, 0); [header appendData:name];
    return header;
}

static NSData *ZipCentralHeader(NSData *name, uint32_t crc, uint32_t size, uint32_t offset) {
    NSMutableData *header = [NSMutableData data];
    ZipU32(header, 0x02014b50); ZipU16(header, 20); ZipU16(header, 20); ZipU16(header, 0x0800); ZipU16(header, 0); ZipU16(header, 0); ZipU16(header, 0); ZipU32(header, crc); ZipU32(header, size); ZipU32(header, size); ZipU16(header, (uint16_t)name.length); ZipU16(header, 0); ZipU16(header, 0); ZipU16(header, 0); ZipU16(header, 0); ZipU32(header, 0); ZipU32(header, offset); [header appendData:name];
    return header;
}

static BOOL StreamZipDirectory(NSURL *directoryURL, NSURL *zipURL, NSUInteger *fileCount, NSString **errorOut) {
    if (fileCount) *fileCount = 0;
    NSFileManager *manager = [NSFileManager defaultManager];
    NSMutableArray<NSURL *> *files = [NSMutableArray array];
    NSDirectoryEnumerator *enumerator = [manager enumeratorAtURL:directoryURL includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:0 errorHandler:^BOOL(NSURL *url, NSError *error) { return YES; }];
    for (NSURL *fileURL in enumerator) {
        NSNumber *isDirectory = nil;
        [fileURL getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];
        if (!isDirectory.boolValue) [files addObject:fileURL];
    }
    [files sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) { return [a.path compare:b.path]; }];
    if (files.count > UINT16_MAX) { if (errorOut) *errorOut = @"ZIP file-count limit exceeded"; return NO; }
    [[NSFileManager defaultManager] removeItemAtURL:zipURL error:nil];
    if (![[NSFileManager defaultManager] createFileAtPath:zipURL.path contents:nil attributes:nil]) { if (errorOut) *errorOut = @"cannot create ZIP"; return NO; }
    NSFileHandle *output = [NSFileHandle fileHandleForWritingAtPath:zipURL.path];
    if (!output) { if (errorOut) *errorOut = @"cannot open ZIP for writing"; return NO; }
    NSMutableArray<NSData *> *central = [NSMutableArray arrayWithCapacity:files.count];
    BOOL success = YES;
    for (NSURL *fileURL in files) {
        @autoreleasepool {
            NSString *relative = [fileURL.path substringFromIndex:directoryURL.path.length + 1];
            NSData *name = [relative dataUsingEncoding:NSUTF8StringEncoding];
            if (!name.length || name.length > UINT16_MAX) {
                success = NO;
                if (errorOut) *errorOut = @"ZIP entry name too long";
            } else {
                uint32_t crc = 0; uint64_t size64 = 0; NSString *streamError = nil;
                if (!StreamFile(fileURL, nil, NO, &crc, &size64, &streamError) || size64 > UINT32_MAX || output.offsetInFile > UINT32_MAX) {
                    success = NO;
                    if (errorOut) *errorOut = streamError ?: @"ZIP entry exceeds classic ZIP limits";
                } else {
                    uint32_t size = (uint32_t)size64;
                    uint32_t offset = (uint32_t)output.offsetInFile;
                    [output writeData:ZipLocalHeader(name, crc, size)];
                    if (!StreamFile(fileURL, output, YES, NULL, NULL, &streamError)) {
                        success = NO;
                        if (errorOut) *errorOut = streamError ?: @"cannot write ZIP entry";
                    } else {
                        [central addObject:ZipCentralHeader(name, crc, size, offset)];
                        if (fileCount) (*fileCount)++;
                    }
                }
            }
        }
        if (!success) break;
    }
    if (success) {
        uint32_t centralOffset = (uint32_t)output.offsetInFile;
        for (NSData *entry in central) [output writeData:entry];
        uint32_t centralSize = (uint32_t)(output.offsetInFile - centralOffset);
        NSMutableData *end = [NSMutableData data];
        ZipU32(end, 0x06054b50); ZipU16(end, 0); ZipU16(end, 0); ZipU16(end, (uint16_t)central.count); ZipU16(end, (uint16_t)central.count); ZipU32(end, centralSize); ZipU32(end, centralOffset); ZipU16(end, 0);
        [output writeData:end];
    }
    [output closeFile];
    if (!success) [[NSFileManager defaultManager] removeItemAtURL:zipURL error:nil];
    return success;
}

#pragma mark - Session and phase utilities

static void AppendFileURL(NSURL *url, NSString *line) {
    if (!url || !line) return;
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:url.path];
    if (!handle) {
        WriteTextURL(url, line);
        return;
    }
    [handle seekToEndOfFile];
    [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [handle synchronizeFile];
    [handle closeFile];
}

static void UIISetLastOperation(NSString *operation) {
    WriteTextURL([ReportsDirectory() URLByAppendingPathComponent:@"LAST_OPERATION.txt"], [NSString stringWithFormat:@"%@\ntimestamp=%@\n", operation ?: @"UNKNOWN", DateString([NSDate date])]);
}

static void UIIWriteCrashRecoveryState(NSString *phase, NSString *status, NSString *sessionID, NSURL *sessionDirectory) {
    NSDictionary *state = @{ @"schemaVersion": @"stability-1.0", @"phase": phase ?: @"UNKNOWN", @"status": status ?: @"UNKNOWN", @"sessionID": sessionID ?: @"", @"timestamp": DateString([NSDate date]) };
    NSString *suffix = [NSString stringWithFormat:@"CRASH_RECOVERY_STATE_%@.json", [NSUUID UUID].UUIDString];
    WriteJSONURL([ReportsDirectory() URLByAppendingPathComponent:suffix], state);
    if (sessionDirectory) WriteJSONURL([sessionDirectory URLByAppendingPathComponent:@"CRASH_RECOVERY_STATE.json"], state);
}

static void UIIWriteHeartbeat(NSString *phase) {
    WriteTextURL([ReportsDirectory() URLByAppendingPathComponent:@"HEARTBEAT.txt"], [NSString stringWithFormat:@"%@\nphase=%@\n", DateString([NSDate date]), phase ?: @"UNKNOWN"]);
}

static void UIIRecordMemoryTelemetry(NSString *phase) {
    mach_task_basic_info_data_t info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    kern_return_t result = task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count);
    if (result == KERN_SUCCESS) {
        AppendFileURL([ReportsDirectory() URLByAppendingPathComponent:@"MEMORY_LOG.txt"], [NSString stringWithFormat:@"%@ phase=%@ resident_mb=%.2f virtual_mb=%.2f\n", DateString([NSDate date]), phase ?: @"UNKNOWN", info.resident_size / 1048576.0, info.virtual_size / 1048576.0]);
    }
}

static uint64_t UIIResidentMemory(void) {
    mach_task_basic_info_data_t info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    return task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count) == KERN_SUCCESS ? info.resident_size : 0;
}

static NSString *MemoryNote(void) {
    return [NSString stringWithFormat:@"mainThread=%@", NSThread.isMainThread ? @"YES" : @"NO"];
}

#pragma mark - Snapshot session (manual capture remains available)

@interface SessionCapture : NSObject
@property(nonatomic,strong) NSString *sessionID;
@property(nonatomic,strong) NSMutableArray<NSDictionary *> *snapshots;
@property(nonatomic,weak) UIWindow *hostWindow;
@property(nonatomic) BOOL active;
+ (instancetype)shared;
- (void)start:(UIWindow *)host;
- (void)capture:(UIWindow *)host label:(NSString *)label inspectorWindow:(UIWindow *)inspector;
- (void)stop;
- (NSURL *)stageSession:(UIWindow *)host error:(NSError **)error;
@end

static NSValue *SnapshotPointerKey(id object) { return [NSValue valueWithPointer:(__bridge const void *)(object)]; }
static NSArray<UIView *> *SnapshotSubviews(UIView *view) { @try { return [view.subviews copy] ?: @[]; } @catch (__unused NSException *exception) { return @[]; } }
static void SessionViewSnapshot(UIView *view, NSUInteger depth, NSUInteger *nodes, NSMutableArray *out, NSMutableSet *seen, BOOL *truncated) {
    if (!view) return;
    if (depth > kSnapshotMaxDepth || *nodes >= kSnapshotMaxViews) { if (truncated) *truncated = YES; return; }
    NSValue *key = SnapshotPointerKey(view);
    if ([seen containsObject:key]) return;
    [seen addObject:key]; (*nodes)++;
    NSMutableDictionary *record = [@{
        @"class": UIIString(NSStringFromClass(view.class)),
        @"superclass": UIIString(NSStringFromClass(view.superclass)),
        @"address": [NSString stringWithFormat:@"%p", view],
        @"frame": NSStringFromCGRect(view.frame),
        @"bounds": NSStringFromCGRect(view.bounds),
        @"center": NSStringFromCGPoint(view.center),
        @"transform": NSStringFromCGAffineTransform(view.transform),
        @"alpha": @(view.alpha), @"hidden": @(view.hidden), @"opaque": @(view.opaque),
        @"clipsToBounds": @(view.clipsToBounds), @"userInteractionEnabled": @(view.userInteractionEnabled),
        @"contentMode": @(view.contentMode), @"tag": @(view.tag),
        @"backgroundColor": UIIColor(view.backgroundColor), @"tintColor": UIIColor(view.tintColor),
        @"subviewCount": @(view.subviews.count), @"accessibilityIdentifier": UIISanitize(view.accessibilityIdentifier),
        @"accessibilityLabel": UIISanitize(view.accessibilityLabel), @"accessibilityValue": UIISanitize(view.accessibilityValue),
        @"window": view.window ? [NSString stringWithFormat:@"%p/%@", view.window, UIIString(NSStringFromClass(view.window.class))] : @"NOT_AVAILABLE",
        @"superview": view.superview ? [NSString stringWithFormat:@"%p/%@", view.superview, UIIString(NSStringFromClass(view.superview.class))] : @"NOT_AVAILABLE",
        @"layer": view.layer ? [NSString stringWithFormat:@"%p/%@", view.layer, UIIString(NSStringFromClass(view.layer.class))] : @"NOT_AVAILABLE"
    } mutableCopy];
    CALayer *layer = view.layer;
    if (layer) {
        record[@"layerFrame"] = NSStringFromCGRect(layer.frame); record[@"layerBounds"] = NSStringFromCGRect(layer.bounds);
        record[@"layerOpacity"] = @(layer.opacity); record[@"layerHidden"] = @(layer.hidden); record[@"cornerRadius"] = @(layer.cornerRadius);
        record[@"masksToBounds"] = @(layer.masksToBounds); record[@"zPosition"] = @(layer.zPosition); record[@"layerBackgroundColor"] = layer.backgroundColor ? UIIColor([UIColor colorWithCGColor:layer.backgroundColor]) : @"NOT_AVAILABLE";
    }
    if ([view isKindOfClass:UIScrollView.class]) {
        UIScrollView *scroll = (UIScrollView *)view; record[@"contentOffset"] = NSStringFromCGPoint(scroll.contentOffset); record[@"contentSize"] = NSStringFromCGSize(scroll.contentSize);
    }
    [out addObject:record];
    for (UIView *child in SnapshotSubviews(view)) SessionViewSnapshot(child, depth + 1, nodes, out, seen, truncated);
}
static void SessionControllerSnapshot(UIViewController *controller, NSUInteger depth, NSUInteger *nodes, NSMutableArray *out, NSMutableSet *seen, BOOL *truncated) {
    if (!controller) return;
    if (depth > kSnapshotMaxDepth || *nodes >= kSnapshotMaxControllers) { if (truncated) *truncated = YES; return; }
    NSValue *key = SnapshotPointerKey(controller);
    if ([seen containsObject:key]) return;
    [seen addObject:key]; (*nodes)++;
    NSMutableDictionary *record = [@{
        @"class": UIIString(NSStringFromClass(controller.class)), @"superclass": UIIString(NSStringFromClass(controller.superclass)),
        @"address": [NSString stringWithFormat:@"%p", controller], @"childCount": @(controller.childViewControllers.count),
        @"presented": controller.presentedViewController ? UIIString(NSStringFromClass(controller.presentedViewController.class)) : @"NOT_AVAILABLE",
        @"presenting": controller.presentingViewController ? UIIString(NSStringFromClass(controller.presentingViewController.class)) : @"NOT_AVAILABLE",
        @"viewLoaded": @(controller.isViewLoaded), @"view": controller.isViewLoaded ? [NSString stringWithFormat:@"%p/%@", controller.view, UIIString(NSStringFromClass(controller.view.class))] : @"NOT_AVAILABLE"
    } mutableCopy];
    if ([controller isKindOfClass:UINavigationController.class]) record[@"navigationStack"] = [[(UINavigationController *)controller viewControllers] valueForKeyPath:@"class.description"] ?: @[];
    if ([controller isKindOfClass:UITabBarController.class]) record[@"selectedTab"] = UIIString(NSStringFromClass(((UITabBarController *)controller).selectedViewController.class));
    if ([controller isKindOfClass:UISplitViewController.class]) record[@"splitControllers"] = [[(UISplitViewController *)controller viewControllers] valueForKeyPath:@"class.description"] ?: @[];
    [out addObject:record];
    for (UIViewController *child in controller.childViewControllers) SessionControllerSnapshot(child, depth + 1, nodes, out, seen, truncated);
    SessionControllerSnapshot(controller.presentedViewController, depth + 1, nodes, out, seen, truncated);
}

@implementation SessionCapture
+ (instancetype)shared { static SessionCapture *instance; static dispatch_once_t once; dispatch_once(&once, ^{ instance = [self new]; }); return instance; }
- (instancetype)init { if ((self = [super init])) _snapshots = [NSMutableArray array]; return self; }
- (void)start:(UIWindow *)host {
    self.hostWindow = host; self.sessionID = [NSUUID UUID].UUIDString; self.snapshots = [NSMutableArray array]; self.active = YES;
}
- (void)capture:(UIWindow *)host label:(NSString *)label inspectorWindow:(UIWindow *)inspector {
    if (!NSThread.isMainThread || !host || !self.active) return;
    NSUInteger viewCount = 0, controllerCount = 0; BOOL truncated = NO;
    NSMutableArray *views = [NSMutableArray array], *controllers = [NSMutableArray array];
    SessionViewSnapshot(host, 0, &viewCount, views, [NSMutableSet set], &truncated);
    SessionControllerSnapshot(host.rootViewController, 0, &controllerCount, controllers, [NSMutableSet set], &truncated);
    NSMutableDictionary *snapshot = [@{ @"sessionID": self.sessionID ?: @"", @"captureID": [NSUUID UUID].UUIDString, @"timestamp": DateString([NSDate date]), @"build": UUIBuildMetadata(), @"label": label ?: @"", @"scene": host.windowScene.session.persistentIdentifier ?: @"", @"hostWindow": [NSString stringWithFormat:@"%p", host], @"views": views, @"controllers": controllers, @"truncated": @(truncated), @"viewCount": @(viewCount), @"controllerCount": @(controllerCount) } mutableCopy];
    @try {
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:host.bounds.size];
        UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) { [host drawViewHierarchyInRect:host.bounds afterScreenUpdates:NO]; }];
        snapshot[@"screenshotData"] = UIImagePNGRepresentation(image) ?: [NSData data];
    } @catch (__unused NSException *exception) {
        snapshot[@"screenshotData"] = [NSData data]; snapshot[@"screenshotError"] = @"NOT_AVAILABLE";
    }
    NSDictionary *last = self.snapshots.lastObject;
    if (last && [last[@"views"] isEqual:views] && [last[@"controllers"] isEqual:controllers] && [last[@"label"] isEqual:label]) return;
    [self.snapshots addObject:snapshot];
}
- (void)stop { self.active = NO; }
- (NSURL *)stageSession:(UIWindow *)host error:(NSError **)error {
    if (NSThread.isMainThread && self.active) [self capture:host label:@"export" inspectorWindow:nil];
    NSURL *base = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:self.sessionID ?: [NSUUID UUID].UUIDString] isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:base withIntermediateDirectories:YES attributes:nil error:error];
    if (error && *error) return nil;
    NSURL *screens = [base URLByAppendingPathComponent:@"Screens" isDirectory:YES]; [[NSFileManager defaultManager] createDirectoryAtURL:screens withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableArray *index = [NSMutableArray array];
    for (NSDictionary *snapshot in self.snapshots) {
        NSString *captureID = snapshot[@"captureID"]; NSURL *dir = [screens URLByAppendingPathComponent:captureID isDirectory:YES]; [[NSFileManager defaultManager] createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSMutableDictionary *copy = [snapshot mutableCopy]; NSData *png = copy[@"screenshotData"]; [copy removeObjectForKey:@"screenshotData"]; [copy removeObjectForKey:@"views"]; [copy removeObjectForKey:@"controllers"]; [index addObject:copy];
        NSData *viewData = [NSJSONSerialization dataWithJSONObject:snapshot[@"views"] ?: @[] options:NSJSONWritingPrettyPrinted error:nil]; if (viewData) [viewData writeToURL:[dir URLByAppendingPathComponent:@"views.json"] options:NSDataWritingAtomic error:nil];
        NSData *controllerData = [NSJSONSerialization dataWithJSONObject:snapshot[@"controllers"] ?: @[] options:NSJSONWritingPrettyPrinted error:nil]; if (controllerData) [controllerData writeToURL:[dir URLByAppendingPathComponent:@"controllers.json"] options:NSDataWritingAtomic error:nil];
        [png writeToURL:[dir URLByAppendingPathComponent:@"screenshot.png"] options:NSDataWritingAtomic error:nil];
    }
    NSData *indexData = [NSJSONSerialization dataWithJSONObject:@{ @"sessionID": self.sessionID ?: @"", @"snapshotCount": @(index.count), @"snapshots": index, @"coverage": @"Observed screens only; not 100% app coverage.", @"build": UUIBuildMetadata() } options:NSJSONWritingPrettyPrinted error:error];
    [indexData writeToURL:[base URLByAppendingPathComponent:@"SESSION_INDEX.json"] options:NSDataWritingAtomic error:error];
    WriteTextURL([base URLByAppendingPathComponent:@"COVERAGE_REPORT.txt"], @"This session records screens actually observed and captured. It does not claim full app coverage.\n");
    return base;
}
@end

#pragma mark - Inspector UI and coordinator

@class InspectorCore;
@interface InspectorWindow : UIWindow @end
@interface InspectorRootController : UIViewController
@property(nonatomic,weak) InspectorCore *core;
@end
@interface InspectorButton : UIButton
@property(nonatomic,weak) InspectorCore *core;
@end

@interface InspectorCore : NSObject <UIDocumentPickerDelegate>
@property(nonatomic,strong) InspectorWindow *window;
@property(nonatomic,strong) InspectorRootController *root;
@property(nonatomic,strong) InspectorButton *button;
@property(nonatomic,weak) UIWindow *hostWindow;
@property(nonatomic,weak) UIWindowScene *scene;
@property(nonatomic,strong) NSMutableString *startup;
@property(nonatomic) BOOL started;
@property(nonatomic,strong) NSURL *selectedFolder;
@property(nonatomic) BOOL collectionCancelled;
@property(nonatomic,strong) UIAlertController *collectionAlert;
@property(nonatomic) BOOL collectionRunning;
@property(nonatomic,strong) UIAlertController *inspectorPanel;
@property(nonatomic,strong) NSString *selectedClassName;
@property(nonatomic) BOOL sharePresented;
@property(nonatomic) BOOL capturePrepared;
@property(nonatomic) BOOL preparing;
@property(nonatomic) BOOL pendingExport;
@property(nonatomic) NSTimeInterval preparationStarted;
@property(nonatomic,strong) NSTimer *preparationTimer;
@property(nonatomic) NSTimeInterval passiveStarted;
@property(nonatomic) NSTimeInterval lightweightWarmupStarted;
@property(nonatomic) BOOL passiveTestComplete;
@property(nonatomic) BOOL lightweightWarmupActive;
@property(nonatomic) BOOL lightweightWarmupStable;
@property(nonatomic) BOOL lightweightMinimumReached;
@property(nonatomic) NSUInteger lightweightStableChecks;
@property(nonatomic) int lightweightPreviousClassCount;
@property(nonatomic) uint32_t lightweightPreviousImageCount;
@property(nonatomic) BOOL lightweightHasPreviousSample;
@property(nonatomic,strong) NSTimer *stabilityTimer;
@property(nonatomic,strong) NSTimer *lightweightWarmupTimer;
@property(nonatomic,strong) NSString *lastPhase;
@property(nonatomic,strong) NSURL *sessionDirectory;
@property(nonatomic,strong) NSString *sessionID;
@property(nonatomic,strong) NSDate *sessionStartDate;
@property(nonatomic,strong) NSDate *sessionEndDate;
@property(nonatomic,strong) NSString *cachedBundleIdentifier;
@property(nonatomic,strong) NSString *cachedAppVersion;
@property(nonatomic,strong) NSString *cachedDeviceModel;
@property(nonatomic,strong) NSString *cachedOSVersion;
@property(nonatomic,strong) NSMutableDictionary *collectorStatus;
@property(nonatomic) BOOL collectorRunning;
@property(nonatomic,strong) NSString *currentCollectorKey;
@property(nonatomic,strong) NSString *currentCollectorOutput;
@property(nonatomic) NSTimeInterval collectorStarted;
@property(nonatomic) uint64_t collectorMemoryBefore;
@property(nonatomic,strong) NSMutableDictionary *phaseStatuses;
@property(nonatomic,strong) NSMutableArray *phasesCompleted;
@property(nonatomic,strong) NSMutableArray *phasesFailed;
@property(nonatomic,strong) NSMutableArray *phasesSkipped;
@property(nonatomic,strong) NSMutableArray *filesFailed;
@property(nonatomic,strong) NSMutableArray *warnings;
@property(nonatomic,strong) NSMutableArray *limitsReached;
@property(nonatomic,strong) NSMutableArray *caughtErrors;
@property(nonatomic,strong) NSString *zipStatus;
@property(nonatomic,strong) NSURL *zipURL;
@property(nonatomic) BOOL finalLogsAlreadyWritten;
@property(nonatomic) NSUInteger runtimeClassCount;
@property(nonatomic) NSUInteger protocolCount;
@property(nonatomic) NSUInteger loadedImageCount;
@property(nonatomic) NSUInteger windowCount;
@property(nonatomic) NSUInteger controllerCount;
@property(nonatomic) NSUInteger legacyViewCount;
@property(nonatomic) NSUInteger windowViewCount;
@property(nonatomic) NSUInteger controllerViewCount;
@property(nonatomic) NSUInteger visibleControllerViewCount;
@property(nonatomic) NSUInteger uniqueViewCount;
@property(nonatomic) NSUInteger maximumDepthObserved;
@property(nonatomic) NSUInteger objectSkips;
@property(nonatomic) NSUInteger duplicateSkips;
@property(nonatomic,strong) UUIVisitedScreenRecorder *screenRecorder;
@property(nonatomic) BOOL screenCaptureStarted;
@property(nonatomic) BOOL forcePartialExport;

+ (instancetype)shared;
- (void)start;
- (void)showInspectorPanel;
- (void)showMenu;
- (void)exportReports;
- (void)exportSession;
- (void)runOneButtonCollection;
- (void)captureSnapshot;
- (void)startScreenCapture;
- (void)stopScreenCapture;
- (void)analyzeAndExport;
- (NSURL *)latestRecoverableSessionDirectory;
- (void)resumePreviousSession;
- (void)prepareFullCapture:(BOOL)exportAfter;
- (void)showCaptureStatus;
- (void)showDiagnosticStatus;
- (void)startLightweightWarmup;
- (void)stabilityTick;
- (void)lightweightWarmupTick;
- (void)manualDumpHierarchy;
- (void)manualDumpControllers;
- (void)manualDumpRuntimeDetails;
- (void)manualDumpImages;
- (BOOL)allCoreCollectorsPassed;
- (void)cancelCurrentPhase;
- (void)hideOverlayForSystemUI;
- (void)restoreOverlayAfterSystemUI;
- (void)searchClass:(NSString *)query;
- (void)exportSelectedClass;
- (NSString *)hierarchy;
- (NSString *)controllers;
- (NSString *)classes;
- (NSData *)detailedRuntimeJSON;
- (NSString *)images;
- (NSString *)diagnostics;
- (void)runLegacyLoadedImages;
- (void)runLegacyRuntimeClasses;
- (void)runLegacyControllers;
- (void)runLegacyViewHierarchy;
- (void)runLegacyDiagnostics;
- (void)exportPartialSession;
- (void)exportLastSession;
- (void)showUnityStatus;
- (void)captureUnityScreen;
- (void)viewUnitySnapshots;
- (void)exportUnitySession;
@end

@implementation InspectorWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { UIView *hit = [super hitTest:point withEvent:event]; if (hit == self || hit == self.rootViewController.view) return nil; return hit; }
@end
@implementation InspectorButton
- (instancetype)initWithCore:(InspectorCore *)core {
    if ((self = [super initWithFrame:CGRectMake(0, 0, 56, 56)])) {
        _core = core; self.accessibilityLabel = @"Universal UI Inspector"; self.backgroundColor = [UIColor colorWithRed:.05 green:.25 blue:.85 alpha:.96]; self.layer.cornerRadius = 28; self.layer.borderWidth = 2; self.layer.borderColor = UIColor.whiteColor.CGColor; self.layer.shadowColor = UIColor.blackColor.CGColor; self.layer.shadowOpacity = .45; self.layer.shadowRadius = 5; [self setTitle:@"UI" forState:UIControlStateNormal]; [self setTitleColor:UIColor.whiteColor forState:UIControlStateNormal]; self.titleLabel.font = [UIFont boldSystemFontOfSize:15]; [self addTarget:self action:@selector(open:) forControlEvents:UIControlEventTouchUpInside]; [self addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)]];
    }
    return self;
}
- (void)open:(id)sender { [self.core showMenu]; }
- (void)drag:(UIPanGestureRecognizer *)gesture { CGPoint translation = [gesture translationInView:self.superview]; if (gesture.state == UIGestureRecognizerStateChanged) { CGPoint center = self.center; center.x += translation.x; center.y += translation.y; UIEdgeInsets insets = self.superview.safeAreaInsets; center.x = MAX(insets.left + 28, MIN(self.superview.bounds.size.width - insets.right - 28, center.x)); center.y = MAX(insets.top + 28, MIN(self.superview.bounds.size.height - insets.bottom - 28, center.y)); self.center = center; [gesture setTranslation:CGPointZero inView:self.superview]; } }
@end
@implementation InspectorRootController
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews]; if (!self.core.button.superview) return; UIEdgeInsets insets = self.view.safeAreaInsets; if (CGRectIsEmpty(self.core.button.frame) || self.core.button.center.x < 1) self.core.button.frame = CGRectMake(self.view.bounds.size.width - insets.right - 70, insets.top + 24, 56, 56); else { CGPoint center = self.core.button.center; center.x = MAX(insets.left + 28, MIN(self.view.bounds.size.width - insets.right - 28, center.x)); center.y = MAX(insets.top + 28, MIN(self.view.bounds.size.height - insets.bottom - 28, center.y)); self.core.button.center = center; } }
@end

static UIWindow *FindHostWindow(UIWindowScene **sceneOut, NSString **evidenceOut) {
    UIApplication *application = UIApplication.sharedApplication; NSMutableString *evidence = [NSMutableString string]; UIWindow *best = nil; UIWindowScene *bestScene = nil;
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        [evidence appendFormat:@"scene=%p state=%ld windows=%lu\n", windowScene, (long)windowScene.activationState, (unsigned long)windowScene.windows.count];
        if (windowScene.activationState != UISceneActivationStateForegroundActive && windowScene.activationState != UISceneActivationStateForegroundInactive) continue;
        for (UIWindow *window in windowScene.windows) {
            [evidence appendFormat:@"  window=%p hidden=%@ level=%.1f root=%@\n", window, window.hidden ? @"YES" : @"NO", window.windowLevel, window.rootViewController ? UIIString(NSStringFromClass(window.rootViewController.class)) : @"NOT_AVAILABLE"];
            if (!window.hidden && window.rootViewController && window.windowLevel == UIWindowLevelNormal && window.bounds.size.width > 0 && window.bounds.size.height > 0) { best = window; bestScene = windowScene; break; }
        }
        if (best) break;
    }
    if (sceneOut) *sceneOut = bestScene; if (evidenceOut) *evidenceOut = evidence; return best;
}

@implementation InspectorCore
+ (instancetype)shared { static InspectorCore *instance; static dispatch_once_t once; dispatch_once(&once, ^{ instance = [self new]; }); return instance; }
- (instancetype)init { if ((self = [super init])) _startup = [NSMutableString stringWithFormat:@"UniversalUIInspector startup %@\n", DateString([NSDate date])]; return self; }
- (UIViewController *)presenter { UIViewController *controller = self.hostWindow.rootViewController; while (controller.presentedViewController) controller = controller.presentedViewController; return controller; }
- (NSURL *)sessionFile:(NSString *)name folder:(NSString *)folder { if (!self.sessionDirectory) return [ReportsDirectory() URLByAppendingPathComponent:name]; NSURL *directory = [self.sessionDirectory URLByAppendingPathComponent:folder isDirectory:YES]; [[NSFileManager defaultManager] createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil]; return [directory URLByAppendingPathComponent:name]; }
- (NSURL *)sessionRootFile:(NSString *)name { return self.sessionDirectory ? [self.sessionDirectory URLByAppendingPathComponent:name] : [ReportsDirectory() URLByAppendingPathComponent:name]; }
- (void)updateSessionState {
    if (!self.sessionDirectory) return;
    NSMutableDictionary *state = [@{ @"schemaVersion": @"2.0", @"sessionID": self.sessionID ?: @"", @"startTime": DateString(self.sessionStartDate), @"status": self.collectionRunning ? @"running" : ([self.zipStatus isEqualToString:@"complete"] ? @"complete" : ([self.screenRecorder isRecording] ? @"recording" : @"paused")), @"updatedAt": DateString([NSDate date]), @"screenCapture": [self.screenRecorder statusDictionary] ?: @{}, @"metadata": self.phaseStatuses[@"metadata"] ?: @"pending", @"loaded_images": self.phaseStatuses[@"loaded_images"] ?: @"pending", @"runtime_classes": self.phaseStatuses[@"runtime_classes"] ?: @"pending", @"protocols": self.phaseStatuses[@"protocols"] ?: @"pending", @"runtime_details": self.phaseStatuses[@"runtime_details"] ?: @"pending", @"controllers": self.phaseStatuses[@"controllers"] ?: @"pending", @"windows": self.phaseStatuses[@"windows"] ?: @"pending", @"view_legacy": self.phaseStatuses[@"view_legacy"] ?: @"pending", @"view_controller_roots": self.phaseStatuses[@"view_controller_roots"] ?: @"pending", @"diagnostics": self.phaseStatuses[@"diagnostics"] ?: @"pending", @"summary": self.phaseStatuses[@"summary"] ?: @"pending", @"zip": self.phaseStatuses[@"zip"] ?: @"pending", @"phases": self.phaseStatuses ?: @{}, @"warnings": self.warnings ?: @[], @"errors": self.caughtErrors ?: @[] } mutableCopy];
    WriteJSONURL([self sessionRootFile:@"SESSION_STATE.json"], state);
}
- (void)createSession {
    [[SessionCapture shared] start:self.hostWindow];
    self.sessionID = [SessionCapture shared].sessionID ?: [NSUUID UUID].UUIDString;
    self.sessionStartDate = [NSDate date];
    NSURL *sessions = [ReportsDirectory() URLByAppendingPathComponent:@"Sessions" isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:sessions withIntermediateDirectories:YES attributes:nil error:nil];
    self.sessionDirectory = [sessions URLByAppendingPathComponent:self.sessionID isDirectory:YES];
    for (NSString *folder in @[@"00_METADATA", @"01_SCREENS", @"01_RUNTIME", @"02_IMAGES", @"03_CONTROLLERS", @"04_VIEWS", @"05_SNAPSHOTS", @"06_DIAGNOSTICS", @"07_LOGS"]) [[NSFileManager defaultManager] createDirectoryAtURL:[self.sessionDirectory URLByAppendingPathComponent:folder isDirectory:YES] withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSString *log in @[@"CAPTURE_EVENTS.jsonl", @"PHASE_EVENTS.jsonl"]) [[NSData data] writeToURL:[self.sessionDirectory URLByAppendingPathComponent:[@"07_LOGS" stringByAppendingPathComponent:log]] options:NSDataWritingAtomic error:nil];
    self.screenRecorder = [[UUIVisitedScreenRecorder alloc] initWithSessionDirectory:self.sessionDirectory sessionID:self.sessionID buildMetadata:UUIBuildMetadata()];
    self.phaseStatuses = [NSMutableDictionary dictionary]; self.phasesCompleted = [NSMutableArray array]; self.phasesFailed = [NSMutableArray array]; self.phasesSkipped = [NSMutableArray array]; self.filesFailed = [NSMutableArray array]; self.warnings = [NSMutableArray array]; self.limitsReached = [NSMutableArray array]; self.caughtErrors = [NSMutableArray array]; self.zipStatus = @"pending";
    self.cachedBundleIdentifier = UIIString(NSBundle.mainBundle.bundleIdentifier); self.cachedAppVersion = UIIString([NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]); self.cachedDeviceModel = UIIString(UIDevice.currentDevice.model); self.cachedOSVersion = UIIString(UIDevice.currentDevice.systemVersion);
    WriteTextURL([self sessionFile:@"SESSION_INFO.txt" folder:@"00_METADATA"], [NSString stringWithFormat:@"UniversalUIInspector runtime session\nsession_id=%@\ncreated=%@\nminimum_warmup_seconds=60\nlegacy_collectors=YES\nstatus=preparing\n", self.sessionID, DateString(self.sessionStartDate)]);
    WriteJSONURL([self sessionFile:@"SESSION_INFO.json" folder:@"00_METADATA"], @{ @"schemaVersion": @"2.0", @"sessionID": self.sessionID, @"createdAt": DateString(self.sessionStartDate), @"minimumWarmupSeconds": @60, @"legacyCollectors": @YES, @"status": @"preparing" });
    WriteTextURL([self sessionFile:@"APP_INFO.txt" folder:@"00_METADATA"], [NSString stringWithFormat:@"bundleIdentifier=%@\nversion=%@\nbuild=%@\nmainImage=%@\n", UIIString(NSBundle.mainBundle.bundleIdentifier), UIIString([NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]), UIIString([NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"]), UIICString(_dyld_get_image_name(0))]);
    WriteTextURL([self sessionFile:@"DEVICE_INFO.txt" folder:@"00_METADATA"], [NSString stringWithFormat:@"model=%@\nos=%@\nscreen=%@\n", UIIString(UIDevice.currentDevice.model), UIIString(UIDevice.currentDevice.systemVersion), NSStringFromCGRect(UIScreen.mainScreen.bounds)]);
    WriteJSONURL([self sessionFile:@"APP_INFO.json" folder:@"00_METADATA"], @{ @"schemaVersion": @"uui-app-info-1.0", @"bundleIdentifier": NSBundle.mainBundle.bundleIdentifier ?: @"NOT_AVAILABLE", @"version": [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"NOT_AVAILABLE", @"build": [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"NOT_AVAILABLE", @"mainImage": UIICString(_dyld_get_image_name(0)), @"buildIdentity": UUIBuildMetadata() });
    WriteJSONURL([self sessionFile:@"DEVICE_INFO.json" folder:@"00_METADATA"], @{ @"schemaVersion": @"uui-device-info-1.0", @"model": UIIString(UIDevice.currentDevice.model), @"osVersion": UIIString(UIDevice.currentDevice.systemVersion), @"screenBounds": NSStringFromCGRect(UIScreen.mainScreen.bounds), @"screenScale": @(UIScreen.mainScreen.scale) });
    WriteJSONURL([self sessionFile:@"BUILD_INFO.json" folder:@"00_METADATA"], UUIBuildMetadata());
    [self updateSessionState];
}
- (void)appendPhaseLog:(NSString *)phase line:(NSString *)line {
    AppendFileURL([self sessionFile:[phase stringByAppendingString:@".log"] folder:@"07_LOGS"], [line stringByAppendingString:@"\n"]);
    NSData *eventData = [NSJSONSerialization dataWithJSONObject:@{@"schema_version":@"uui-phase-event-1.0",@"timestamp":DateString([NSDate date]),@"phase":phase ?: @"unknown",@"message":line ?: @""} options:0 error:nil]; if (eventData) { NSMutableData *record = [eventData mutableCopy]; [record appendBytes:"\n" length:1]; NSFileHandle *events = [NSFileHandle fileHandleForWritingAtPath:[[self sessionFile:@"PHASE_EVENTS.jsonl" folder:@"07_LOGS"] path]]; if (events) { [events seekToEndOfFile]; [events writeData:record]; [events closeFile]; } }
    AppendFileURL([ReportsDirectory() URLByAppendingPathComponent:@"SESSION_PHASE_LOG.txt"], [line stringByAppendingString:@"\n"]);
}
- (void)beginPhase:(NSString *)phase message:(NSString *)message {
    self.lastPhase = phase; self.phaseStatuses[phase] = @"running"; self.collectionAlert.message = message; UIISetLastOperation([[phase uppercaseString] stringByAppendingString:@"_BEGIN"]); UIIWriteCrashRecoveryState(phase, @"running", self.sessionID, self.sessionDirectory); UIIRecordMemoryTelemetry([phase stringByAppendingString:@"_BEGIN"]);
    NSString *line = [NSString stringWithFormat:@"START timestamp=%@ phase=%@ progress=%@ %@", DateString([NSDate date]), phase, message ?: @"", MemoryNote()];
    [self appendPhaseLog:phase line:line]; [self updateSessionState];
}
- (void)endPhase:(NSString *)phase state:(NSString *)state count:(NSUInteger)count bytes:(NSUInteger)bytes warning:(NSString *)warning error:(NSString *)error {
    NSString *finalState = error.length ? @"failed" : state ?: @"complete"; self.phaseStatuses[phase] = finalState;
    if (error.length) { if (![self.phasesFailed containsObject:phase]) [self.phasesFailed addObject:phase]; [self.caughtErrors addObject:[NSString stringWithFormat:@"%@:%@", phase, error]]; [self.filesFailed addObject:phase]; }
    else if ([finalState isEqualToString:@"skipped"]) { if (![self.phasesSkipped containsObject:phase]) [self.phasesSkipped addObject:phase]; }
    else if (![self.phasesCompleted containsObject:phase]) [self.phasesCompleted addObject:phase];
    if (warning.length && ![self.warnings containsObject:warning]) [self.warnings addObject:warning];
    NSString *line = [NSString stringWithFormat:@"END timestamp=%@ phase=%@ state=%@ count=%lu bytes=%lu warning=%@ error=%@ %@", DateString([NSDate date]), phase, finalState, (unsigned long)count, (unsigned long)bytes, warning ?: @"-", error ?: @"-", MemoryNote()];
    [self appendPhaseLog:phase line:line]; UIISetLastOperation([[phase uppercaseString] stringByAppendingString:(error.length ? @"_FAILED" : @"_END")]); UIIRecordMemoryTelemetry([phase stringByAppendingString:(error.length ? @"_FAILED" : @"_END")]); UIIWriteCrashRecoveryState(phase, finalState, self.sessionID, self.sessionDirectory); [self updateSessionState];
}
- (void)mirrorReport:(NSString *)name from:(NSURL *)url {
    NSData *data = [NSData dataWithContentsOfURL:url]; if (data) [data writeToURL:[ReportsDirectory() URLByAppendingPathComponent:name] options:NSDataWritingAtomic error:nil];
}

- (void)start {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self start]; }); return; }
    if (self.started && self.window.superview) return;
    UIWindowScene *scene = nil; NSString *evidence = nil; UIWindow *host = FindHostWindow(&scene, &evidence); [self.startup appendFormat:@"Discovery:\n%@\n", evidence ?: @"(none)" ];
    if (!host || !scene) { [self.startup appendString:@"ERROR: no foreground usable host window\n"]; [self writeStartupReports]; return; }
    UIISetLastOperation(@"OVERLAY_CREATE_BEGIN");
    self.hostWindow = host; self.scene = scene; self.started = YES; self.root = [InspectorRootController new]; self.root.core = self; self.window = [[InspectorWindow alloc] initWithWindowScene:scene]; self.window.frame = scene.coordinateSpace.bounds; self.window.windowLevel = UIWindowLevelAlert + 1; self.window.backgroundColor = UIColor.clearColor; self.window.opaque = NO; self.window.rootViewController = self.root; self.button = [[InspectorButton alloc] initWithCore:self]; [self.root.view addSubview:self.button]; self.window.hidden = NO; [self.root viewDidLayoutSubviews];
    [self loadCollectorStatus]; UIISetLastOperation(@"OVERLAY_CREATE_END"); UIIWriteCrashRecoveryState(@"OVERLAY_CREATE", @"running", nil, nil);
    [self.startup appendFormat:@"Host window: %p %@\nScene: %p state=%ld\nOverlay created: %p visible=%@ button=%@\nPASSIVE STARTUP TEST\nElapsed: 0\nNo polling, runtime enumeration, hooks, or dumps are active.\n", host, UIIString(NSStringFromClass(host.class)), scene, (long)scene.activationState, self.window, self.window.hidden ? @"NO" : @"YES", self.button]; [self writeStartupReports];
    self.passiveStarted = CACurrentMediaTime(); self.passiveTestComplete = NO; self.stabilityTimer = [NSTimer scheduledTimerWithTimeInterval:5.0 target:self selector:@selector(stabilityTick) userInfo:nil repeats:YES]; [self stabilityTick];
}
- (void)writeStartupReports {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self writeStartupReports]; }); return; }
    WriteReport(@"STARTUP_VIEW_TREE.txt", @"PASSIVE STARTUP TEST\nNo UIKit hierarchy traversal was performed during startup.\nRuntime counters begin only after the user starts lightweight warm-up.\n");
    WriteReport(@"BOOT_DIAGNOSTICS.txt", self.startup.copy);
    WriteReport(@"RUNTIME_STARTUP_REPORT.txt", [NSString stringWithFormat:@"PASSIVE STARTUP TEST\ntimestamp=%@\ninspector window=%p\nhost window=%p\nclass/image counters=NOT_STARTED\n", DateString([NSDate date]), self.window, self.hostWindow]);
}

- (void)showDiagnosticStatus {
    NSTimeInterval passiveElapsed = self.passiveStarted > 0 ? CACurrentMediaTime() - self.passiveStarted : 0;
    NSTimeInterval warmupElapsed = self.lightweightWarmupStarted > 0 ? CACurrentMediaTime() - self.lightweightWarmupStarted : 0;
    NSString *lastOperation = [NSString stringWithContentsOfURL:[ReportsDirectory() URLByAppendingPathComponent:@"LAST_OPERATION.txt"] encoding:NSUTF8StringEncoding error:nil] ?: @"NOT_AVAILABLE";
    NSString *message = [NSString stringWithFormat:@"PASSIVE STARTUP STATUS\nPassive Startup: %@\nOverlay: %@\nDylib Loaded: YES\nBuild ID: %@\nCurrent Process: %d\nBundle: %@\nCurrent phase: %@\nElapsed: %.1fs\nMemory: %llu bytes\nLast Operation: %@\n\nLIGHTWEIGHT WARM-UP\nElapsed: %.1fs / %.0fs\nMinimum reached: %@\nActive: %@\nClass count: %d\nImage count: %u\nStable: %@\nStable checks: %lu / %lu\n\nNo automatic full capture is enabled in this staged build.", self.passiveTestComplete ? @"PASS" : @"RUNNING", (self.started && self.window && !self.window.hidden) ? @"PASS" : @"FAIL", UIIString([NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"]), getpid(), UIIString(NSBundle.mainBundle.bundleIdentifier), self.lastPhase ?: @"PASSIVE_STARTUP", passiveElapsed, UIIResidentMemory(), lastOperation, warmupElapsed, kLightweightWarmupSeconds, self.lightweightMinimumReached ? @"YES" : @"NO", self.lightweightWarmupActive ? @"YES" : @"NO", self.lightweightPreviousClassCount, self.lightweightPreviousImageCount, self.lightweightWarmupStable ? @"YES" : @"NO", (unsigned long)self.lightweightStableChecks, (unsigned long)kRequiredLightweightStableChecks];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Stability Diagnostic" message:message preferredStyle:UIAlertControllerStyleAlert]; [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]]; [[self presenter] presentViewController:alert animated:YES completion:nil];
}

- (void)stabilityTick {
    if (!self.started || self.passiveTestComplete) return;
    NSTimeInterval elapsed = CACurrentMediaTime() - self.passiveStarted;
    self.button.accessibilityValue = [NSString stringWithFormat:@"PASSIVE STARTUP TEST; elapsed %.0f seconds; no polling or dump", elapsed];
    UIISetLastOperation(@"PASSIVE_WAIT"); UIIWriteHeartbeat(@"PASSIVE_WAIT");
    if (elapsed >= kPassiveStartupSeconds) {
        self.passiveTestComplete = YES; [self.stabilityTimer invalidate]; self.stabilityTimer = nil; UIISetLastOperation(@"PASSIVE_WAIT"); UIIWriteCrashRecoveryState(@"PASSIVE_WAIT", @"stable", nil, nil); WriteReport(@"PASSIVE_STARTUP_TEST.txt", [NSString stringWithFormat:@"PASSIVE_STARTUP_TEST=STABLE\nelapsed_seconds=%.1f\nno_runtime_polling=YES\nno_automatic_dump=YES\n", elapsed]);
        self.button.accessibilityValue = @"PASSIVE STARTUP TEST complete; start lightweight warm-up from the inspector menu";
        if (self.screenCaptureStarted) [self startLightweightWarmup];
    }
}

- (void)startLightweightWarmup {
    if (!self.passiveTestComplete) { [self showDiagnosticStatus]; return; }
    if (self.lightweightWarmupActive || self.lightweightWarmupStable) return;
    self.lightweightWarmupActive = YES; self.lightweightWarmupStarted = CACurrentMediaTime(); self.lightweightMinimumReached = NO; self.lightweightStableChecks = 0; self.lightweightHasPreviousSample = NO; self.collectorStatus[@"warmup"] = @{ @"status": @"RUNNING", @"startedAt": DateString([NSDate date]) }; [self writeCollectorStatus]; UIISetLastOperation(@"WARMUP_SAMPLE_BEGIN"); UIIWriteCrashRecoveryState(@"LIGHTWEIGHT_WARMUP", @"running", nil, nil); WriteTextURL([ReportsDirectory() URLByAppendingPathComponent:@"WARMUP_SAMPLES.txt"], @"LIGHTWEIGHT WARM-UP SAMPLES\nOnly objc_getClassList(NULL, 0) and _dyld_image_count() are collected.\nMinimum warm-up: 120 seconds.\nStable gate: 6 consecutive post-minimum checks with unchanged class/image counts.\n"); self.lightweightWarmupTimer = [NSTimer scheduledTimerWithTimeInterval:kLightweightSampleInterval target:self selector:@selector(lightweightWarmupTick) userInfo:nil repeats:YES]; [self lightweightWarmupTick];
}

- (void)lightweightWarmupTick {
    if (!self.lightweightWarmupActive) return;
    UIISetLastOperation(@"WARMUP_SAMPLE_BEGIN");
    int classCount = objc_getClassList(NULL, 0);
    UIISetLastOperation(@"WARMUP_CLASS_COUNT_END");
    uint32_t imageCount = _dyld_image_count();
    UIISetLastOperation(@"WARMUP_IMAGE_COUNT_END");
    NSTimeInterval elapsed = CACurrentMediaTime() - self.lightweightWarmupStarted;
    if (!self.lightweightMinimumReached && elapsed >= kLightweightWarmupSeconds) { self.lightweightMinimumReached = YES; self.lightweightStableChecks = 0; self.lightweightHasPreviousSample = NO; }
    BOOL countsStable = self.lightweightMinimumReached && self.lightweightHasPreviousSample && classCount == self.lightweightPreviousClassCount && imageCount == self.lightweightPreviousImageCount;
    if (self.lightweightMinimumReached) self.lightweightStableChecks = countsStable ? self.lightweightStableChecks + 1 : 0;
    self.lightweightPreviousClassCount = classCount; self.lightweightPreviousImageCount = imageCount; self.lightweightHasPreviousSample = YES;
    AppendFileURL([ReportsDirectory() URLByAppendingPathComponent:@"WARMUP_SAMPLES.txt"], [NSString stringWithFormat:@"timestamp=%@ elapsed=%.1f classCount=%d imageCount=%u minimumReached=%@ countsStable=%@ stableChecks=%lu/%lu\n", DateString([NSDate date]), elapsed, classCount, imageCount, self.lightweightMinimumReached ? @"YES" : @"NO", countsStable ? @"YES" : @"NO", (unsigned long)self.lightweightStableChecks, (unsigned long)kRequiredLightweightStableChecks]);
    UIIRecordMemoryTelemetry(@"LIGHTWEIGHT_WARMUP"); UIIWriteHeartbeat(@"LIGHTWEIGHT_WARMUP");
    self.button.accessibilityValue = [NSString stringWithFormat:@"LIGHTWEIGHT WARM-UP; %.0f seconds; class count %d; image count %u; stable checks %lu/%lu", elapsed, classCount, imageCount, (unsigned long)self.lightweightStableChecks, (unsigned long)kRequiredLightweightStableChecks];
    if (self.lightweightMinimumReached && self.lightweightStableChecks >= kRequiredLightweightStableChecks) {
        self.lightweightWarmupActive = NO; self.lightweightWarmupStable = YES; self.collectorStatus[@"warmup"] = @{ @"status": @"PASS", @"stableChecks": @(self.lightweightStableChecks), @"endedAt": DateString([NSDate date]) }; [self writeCollectorStatus]; [self.lightweightWarmupTimer invalidate]; self.lightweightWarmupTimer = nil; UIISetLastOperation(@"LIGHTWEIGHT_WARMUP_STABLE"); UIIWriteCrashRecoveryState(@"LIGHTWEIGHT_WARMUP", @"stable", nil, nil); AppendFileURL([ReportsDirectory() URLByAppendingPathComponent:@"WARMUP_SAMPLES.txt"], @"LIGHTWEIGHT_WARMUP_STABLE=YES\n"); self.button.accessibilityValue = @"LIGHTWEIGHT WARM-UP stable; individual legacy collectors enabled";
    }
}

#pragma mark - Manual actions, backed by the same legacy collectors

- (NSString *)hierarchy {
    UIISetLastOperation(@"VIEWS_BEGIN"); NSURL *url = [ReportsDirectory() URLByAppendingPathComponent:@"CURRENT_VIEW_HIERARCHY.txt"]; BOOL truncated = NO; LegacyWriteVisibleHierarchy(self.hostWindow, url, kFullCaptureMaxDepth, kFullCaptureMaxNodes, &truncated); return [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil] ?: @"CURRENT_VIEW_HIERARCHY.txt\n";
}
- (NSString *)controllers {
    UIISetLastOperation(@"CONTROLLERS_BEGIN"); NSURL *controllersURL = [ReportsDirectory() URLByAppendingPathComponent:@"CURRENT_CONTROLLERS.txt"]; NSURL *treeURL = [ReportsDirectory() URLByAppendingPathComponent:@"CONTROLLER_TREE.txt"]; NSURL *mapURL = [ReportsDirectory() URLByAppendingPathComponent:@"CONTROLLER_VIEW_MAP.txt"]; BOOL truncated = NO; NSUInteger duplicates = 0, depth = 0; LegacyWriteControllers(self.hostWindow, controllersURL, treeURL, mapURL, kFullCaptureMaxDepth, kFullCaptureMaxNodes, &truncated, &duplicates, &depth); return [NSString stringWithContentsOfURL:controllersURL encoding:NSUTF8StringEncoding error:nil] ?: @"CURRENT_CONTROLLERS.txt\n";
}
- (NSString *)classes {
    UIISetLastOperation(@"LEGACY_CLASSES_BEGIN"); NSURL *jsonl = [ReportsDirectory() URLByAppendingPathComponent:@"RUNTIME_CLASSES.jsonl"]; NSURL *text = [ReportsDirectory() URLByAppendingPathComponent:@"RUNTIME_CLASSES.txt"]; NSURL *summary = [ReportsDirectory() URLByAppendingPathComponent:@"RUNTIME_CLASSES_SUMMARY.json"]; NSUInteger count = LegacyWriteRuntimeClassIndex(jsonl, text, summary); return [NSString stringWithFormat:@"RUNTIME_CLASSES.txt\ncomplete_index_count=%lu\njsonl=%@\n", (unsigned long)count, text.path];
}
- (NSData *)detailedRuntimeJSON {
    UIISetLastOperation(@"LEGACY_CLASSES_DETAIL_BEGIN"); NSURL *jsonl = [ReportsDirectory() URLByAppendingPathComponent:@"RUNTIME_CLASSES_DETAILED.jsonl"]; NSURL *text = [ReportsDirectory() URLByAppendingPathComponent:@"RUNTIME_CLASSES_DETAILED.txt"]; NSURL *summary = [ReportsDirectory() URLByAppendingPathComponent:@"RUNTIME_CLASSES_DETAILED_SUMMARY.json"]; LegacyWriteRuntimeDetails(jsonl, text, summary); return [NSData dataWithContentsOfURL:summary] ?: [NSData data];
}
- (NSString *)images {
    UIISetLastOperation(@"LEGACY_IMAGES_BEGIN"); NSURL *text = [ReportsDirectory() URLByAppendingPathComponent:@"LOADED_IMAGES.txt"]; NSURL *jsonl = [ReportsDirectory() URLByAppendingPathComponent:@"LOADED_IMAGES.jsonl"]; NSURL *summary = [ReportsDirectory() URLByAppendingPathComponent:@"LOADED_IMAGES_SUMMARY.json"]; LegacyWriteLoadedImages(text, jsonl, summary); return [NSString stringWithContentsOfURL:text encoding:NSUTF8StringEncoding error:nil] ?: @"LOADED_IMAGES.txt\n";
}
- (NSString *)diagnostics {
    return [NSString stringWithFormat:@"DIAGNOSTICS.txt\nmain thread=%@\nstarted=%@\nhost=%p\noverlay=%p hidden=%@\nreports=%@\nsession=%@\nlast phase=%@\n", NSThread.isMainThread ? @"YES" : @"NO", self.started ? @"YES" : @"NO", self.hostWindow, self.window, self.window.hidden ? @"YES" : @"NO", ReportsDirectory().path, self.sessionID ?: @"NOT_AVAILABLE", self.lastPhase ?: @"NOT_AVAILABLE"];
}
- (void)manualDumpHierarchy { UIISetLastOperation(@"VIEWS_BEGIN"); NSURL *url = [ReportsDirectory() URLByAppendingPathComponent:@"CURRENT_VIEW_HIERARCHY.txt"]; BOOL truncated = NO; NSUInteger count = LegacyWriteVisibleHierarchy(self.hostWindow, url, kFullCaptureMaxDepth, kFullCaptureMaxNodes, &truncated); if (self.sessionDirectory) { NSData *data = [NSData dataWithContentsOfURL:url]; [data writeToURL:[self sessionFile:@"VIEW_TREE_LEGACY.txt" folder:@"04_VIEWS"] options:NSDataWritingAtomic error:nil]; } WriteReport(@"CURRENT_VIEW_HIERARCHY_STATUS.txt", [NSString stringWithFormat:@"nodes=%lu LIMIT_REACHED=%@\n", (unsigned long)count, truncated ? @"YES" : @"NO"]); }
- (void)manualDumpControllers { UIISetLastOperation(@"CONTROLLERS_BEGIN"); NSURL *c = [ReportsDirectory() URLByAppendingPathComponent:@"CURRENT_CONTROLLERS.txt"]; NSURL *t = [ReportsDirectory() URLByAppendingPathComponent:@"CONTROLLER_TREE.txt"]; NSURL *m = [ReportsDirectory() URLByAppendingPathComponent:@"CONTROLLER_VIEW_MAP.txt"]; BOOL truncated = NO; NSUInteger duplicate = 0, depth = 0; LegacyWriteControllers(self.hostWindow, c, t, m, kFullCaptureMaxDepth, kFullCaptureMaxNodes, &truncated, &duplicate, &depth); }
- (void)manualDumpRuntimeDetails { UIISetLastOperation(@"LEGACY_CLASSES_BEGIN"); NSURL *jsonl = [ReportsDirectory() URLByAppendingPathComponent:@"RUNTIME_CLASSES_DETAILED.jsonl"]; NSURL *text = [ReportsDirectory() URLByAppendingPathComponent:@"RUNTIME_CLASSES_DETAILED.txt"]; NSURL *summary = [ReportsDirectory() URLByAppendingPathComponent:@"RUNTIME_CLASSES_DETAILED_SUMMARY.json"]; LegacyWriteRuntimeDetails(jsonl, text, summary); }
- (void)manualDumpImages { UIISetLastOperation(@"LEGACY_IMAGES_BEGIN"); NSURL *text = [ReportsDirectory() URLByAppendingPathComponent:@"LOADED_IMAGES.txt"]; NSURL *jsonl = [ReportsDirectory() URLByAppendingPathComponent:@"LOADED_IMAGES.jsonl"]; NSURL *summary = [ReportsDirectory() URLByAppendingPathComponent:@"LOADED_IMAGES_SUMMARY.json"]; LegacyWriteLoadedImages(text, jsonl, summary); }

- (void)writeCollectorStatus {
    NSMutableDictionary *payload = [@{ @"schemaVersion": @"collector-status-1.0", @"updatedAt": DateString([NSDate date]), @"collectors": self.collectorStatus ?: @{} } mutableCopy];
    if (self.currentCollectorKey) payload[@"currentCollector"] = self.currentCollectorKey;
    WriteJSONURL([ReportsDirectory() URLByAppendingPathComponent:@"COLLECTOR_STATUS.json"], payload);
    if (self.sessionDirectory) WriteJSONURL([self.sessionDirectory URLByAppendingPathComponent:@"COLLECTOR_STATUS.json"], payload);
}

- (void)loadCollectorStatus {
    self.collectorStatus = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"warmup", @"loaded_images", @"runtime_classes", @"controllers", @"view_hierarchy", @"diagnostics"]) self.collectorStatus[key] = @{ @"status": @"NOT_TESTED" };
    NSData *data = [NSData dataWithContentsOfURL:[ReportsDirectory() URLByAppendingPathComponent:@"COLLECTOR_STATUS.json"]];
    NSDictionary *saved = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSDictionary *savedCollectors = [saved isKindOfClass:NSDictionary.class] ? saved[@"collectors"] : nil;
    if ([savedCollectors isKindOfClass:NSDictionary.class]) [self.collectorStatus addEntriesFromDictionary:savedCollectors];
    for (NSString *key in self.collectorStatus.allKeys) {
        id value = self.collectorStatus[key];
        NSString *status = [value isKindOfClass:NSDictionary.class] ? value[@"status"] : value;
        if ([status isEqualToString:@"RUNNING"]) self.collectorStatus[key] = @{ @"status": @"CRASH_SUSPECTED", @"reason": @"previous process ended before collector END breadcrumb" };
    }
    [self writeCollectorStatus];
}

- (NSString *)collectorState:(NSString *)key {
    id value = self.collectorStatus[key];
    if ([value isKindOfClass:NSDictionary.class]) return value[@"status"] ?: @"NOT_TESTED";
    return [value isKindOfClass:NSString.class] ? value : @"NOT_TESTED";
}
- (BOOL)allCoreCollectorsPassed { return self.lightweightWarmupStable && [[self collectorState:@"loaded_images"] isEqualToString:@"PASS"] && [[self collectorState:@"runtime_classes"] isEqualToString:@"PASS"] && [[self collectorState:@"controllers"] isEqualToString:@"PASS"] && [[self collectorState:@"view_hierarchy"] isEqualToString:@"PASS"]; }

- (void)showCollectorLocked:(NSString *)name {
    NSString *message = [name containsString:@"remains disabled"] ? @"All staged collector tests have passed. Automatic full capture remains disabled until a separately reviewed build enables it." : (self.lightweightWarmupStable ? @"Another collector is already running." : @"Complete the 120-second minimum warm-up and 6 consecutive stable post-minimum checks first.");
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"%@ LOCKED", name] message:message preferredStyle:UIAlertControllerStyleAlert]; [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]]; [[self presenter] presentViewController:alert animated:YES completion:nil];
}

- (BOOL)beginStagedCollector:(NSString *)key output:(NSString *)output operation:(NSString *)operation {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self beginStagedCollector:key output:output operation:operation]; }); return NO; }
    if (self.collectorRunning) { [self showCollectorLocked:self.currentCollectorKey ?: @"COLLECTOR"]; return NO; }
    if (!self.lightweightWarmupStable) { [self showCollectorLocked:key]; return NO; }
    if (!self.sessionDirectory) [self createSession];
    self.collectorRunning = YES; self.currentCollectorKey = key; self.currentCollectorOutput = output; self.collectorStarted = CACurrentMediaTime(); self.collectorMemoryBefore = UIIResidentMemory(); self.collectorStatus[key] = @{ @"status": @"RUNNING", @"outputFile": output ?: @"", @"startedAt": DateString([NSDate date]), @"memoryBefore": @(self.collectorMemoryBefore) }; [self writeCollectorStatus]; UIISetLastOperation(operation); UIIWriteCrashRecoveryState(operation, @"running", self.sessionID, self.sessionDirectory); UIIRecordMemoryTelemetry(operation); return YES;
}

- (void)finishStagedCollector:(NSString *)key status:(NSString *)status output:(NSString *)output count:(NSUInteger)count error:(NSString *)error {
    uint64_t after = UIIResidentMemory(); NSTimeInterval duration = CACurrentMediaTime() - self.collectorStarted; NSString *finalStatus = error.length ? @"FAIL" : status ?: @"PASS"; self.collectorStatus[key] = @{ @"status": finalStatus, @"outputFile": output ?: self.currentCollectorOutput ?: @"", @"durationSeconds": @(duration), @"objectCount": @(count), @"memoryBefore": @(self.collectorMemoryBefore), @"memoryAfter": @(after), @"error": error ?: @"", @"endedAt": DateString([NSDate date]) }; self.collectorRunning = NO; self.currentCollectorKey = nil; self.currentCollectorOutput = nil; [self writeCollectorStatus]; UIISetLastOperation([[key uppercaseString] stringByAppendingString:(error.length ? @"_FAIL" : @"_END")]); UIIWriteCrashRecoveryState(key, finalStatus, self.sessionID, self.sessionDirectory); UIIRecordMemoryTelemetry([key stringByAppendingString:@"_END"]); NSString *message = [NSString stringWithFormat:@"Status: %@\nDuration: %.2fs\nOutput: %@\nObjects: %lu\nMemory: %llu -> %llu bytes\n%@", finalStatus, duration, output ?: @"NOT_AVAILABLE", (unsigned long)count, self.collectorMemoryBefore, after, error.length ? error : @"Last completed step: END"]; UIAlertController *alert = [UIAlertController alertControllerWithTitle:key message:message preferredStyle:UIAlertControllerStyleAlert]; [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]]; [[self presenter] presentViewController:alert animated:YES completion:nil];
}

- (void)runLegacyLoadedImages {
    NSURL *text = [ReportsDirectory() URLByAppendingPathComponent:@"LOADED_IMAGES.txt"]; NSURL *jsonl = [ReportsDirectory() URLByAppendingPathComponent:@"LOADED_IMAGES.jsonl"]; NSURL *summary = [ReportsDirectory() URLByAppendingPathComponent:@"LOADED_IMAGES_SUMMARY.json"]; if (![self beginStagedCollector:@"loaded_images" output:text.path operation:@"LEGACY_IMAGES_BEGIN"]) return; NSString *error = nil; @try { LegacyWriteLoadedImages(text, jsonl, summary); } @catch (NSException *exception) { error = exception.reason ?: exception.name; } NSDictionary *meta = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:summary] options:0 error:nil]; NSUInteger count = [meta[@"count"] unsignedIntegerValue]; [self finishStagedCollector:@"loaded_images" status:error ? @"FAIL" : @"PASS" output:text.path count:count error:error];
}

- (void)runLegacyRuntimeClasses {
    NSURL *jsonl = [ReportsDirectory() URLByAppendingPathComponent:@"RUNTIME_CLASSES.jsonl"]; NSURL *text = [ReportsDirectory() URLByAppendingPathComponent:@"RUNTIME_CLASSES.txt"]; NSURL *summary = [ReportsDirectory() URLByAppendingPathComponent:@"RUNTIME_CLASSES_SUMMARY.json"]; if (![self beginStagedCollector:@"runtime_classes" output:text.path operation:@"LEGACY_CLASSES_BEGIN"]) return; NSString *error = nil; NSUInteger count = 0; @try { count = LegacyWriteRuntimeClassIndex(jsonl, text, summary); } @catch (NSException *exception) { error = exception.reason ?: exception.name; } [self finishStagedCollector:@"runtime_classes" status:error ? @"FAIL" : @"PASS" output:text.path count:count error:error];
}

- (void)runLegacyControllers {
    NSURL *controllers = [ReportsDirectory() URLByAppendingPathComponent:@"CURRENT_CONTROLLERS.txt"]; NSURL *tree = [ReportsDirectory() URLByAppendingPathComponent:@"CONTROLLER_TREE.txt"]; NSURL *map = [ReportsDirectory() URLByAppendingPathComponent:@"CONTROLLER_VIEW_MAP.txt"]; if (![self beginStagedCollector:@"controllers" output:controllers.path operation:@"LEGACY_CONTROLLERS_BEGIN"]) return; NSString *error = nil; BOOL truncated = NO; NSUInteger duplicates = 0, depth = 0; @try { LegacyWriteControllers(self.hostWindow, controllers, tree, map, kFullCaptureMaxDepth, kFullCaptureMaxNodes, &truncated, &duplicates, &depth); } @catch (NSException *exception) { error = exception.reason ?: exception.name; } NSUInteger count = [[NSString stringWithContentsOfURL:controllers encoding:NSUTF8StringEncoding error:nil] componentsSeparatedByString:@"\n"].count; [self finishStagedCollector:@"controllers" status:error ? @"FAIL" : @"PASS" output:controllers.path count:count error:error];
}

- (void)runLegacyViewHierarchy {
    NSURL *views = [ReportsDirectory() URLByAppendingPathComponent:@"CURRENT_VIEW_HIERARCHY.txt"]; if (![self beginStagedCollector:@"view_hierarchy" output:views.path operation:@"LEGACY_VIEWS_BEGIN"]) return; NSString *error = nil; BOOL truncated = NO; NSUInteger count = 0; @try { count = LegacyWriteVisibleHierarchy(self.hostWindow, views, kFullCaptureMaxDepth, kFullCaptureMaxNodes, &truncated); } @catch (NSException *exception) { error = exception.reason ?: exception.name; } [self finishStagedCollector:@"view_hierarchy" status:error ? @"FAIL" : @"PASS" output:views.path count:count error:error];
}

- (void)runLegacyDiagnostics {
    NSURL *output = [ReportsDirectory() URLByAppendingPathComponent:@"DIAGNOSTICS.txt"]; if (![self beginStagedCollector:@"diagnostics" output:output.path operation:@"LEGACY_DIAGNOSTICS_BEGIN"]) return; NSString *error = nil; @try { WriteReport(@"DIAGNOSTICS.txt", [self diagnostics]); } @catch (NSException *exception) { error = exception.reason ?: exception.name; } [self finishStagedCollector:@"diagnostics" status:error ? @"FAIL" : @"PASS" output:output.path count:1 error:error];
}

- (void)exportSessionDirectory:(NSURL *)directory title:(NSString *)title {
    if (!directory) { [self showCollectorLocked:@"NO SESSION"]; return; }
    NSURL *zip = [ReportsDirectory() URLByAppendingPathComponent:[NSString stringWithFormat:@"%@-%@.zip", title, [NSUUID UUID].UUIDString]]; NSUInteger count = 0; NSString *why = nil; if (!StreamZipDirectory(directory, zip, &count, &why)) { WriteReport(@"SESSION_EXPORT_ERROR.txt", why ?: @"ZIP creation failed"); [self showCollectorLocked:@"EXPORT FAILED"]; return; }
    [self hideOverlayForSystemUI]; UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[zip] applicationActivities:nil]; share.completionWithItemsHandler = ^(__unused UIActivityType activity, __unused BOOL completed, __unused NSArray *items, __unused NSError *error) { [self restoreOverlayAfterSystemUI]; }; [[self presenter] presentViewController:share animated:YES completion:nil];
}

- (void)exportPartialSession { [self exportSessionDirectory:self.sessionDirectory title:@"UniversalUIInspector-Partial-Session"]; }
- (void)exportLastSession { NSURL *sessions = [ReportsDirectory() URLByAppendingPathComponent:@"Sessions" isDirectory:YES]; NSArray *dirs = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:sessions includingPropertiesForKeys:@[NSURLIsDirectoryKey, NSURLContentModificationDateKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:nil]; NSURL *latest = [dirs sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) { NSDate *ad = nil; NSDate *bd = nil; [a getResourceValue:&ad forKey:NSURLContentModificationDateKey error:nil]; [b getResourceValue:&bd forKey:NSURLContentModificationDateKey error:nil]; return [bd compare:ad]; }].firstObject; [self exportSessionDirectory:latest title:@"UniversalUIInspector-Last-Session"]; }
- (void)showUnityStatus {
    NSDictionary *status = UUIUnityRuntimeStatus();
    NSString *message = [NSString stringWithFormat:@"%@\n\nLoaded runtime markers: %@\nInitialization: %@\nUnity hierarchy: %@\n\n%@", status[@"status"], [status[@"runtimeImages"] componentsJoinedByString:@"\n"].length ? [status[@"runtimeImages"] componentsJoinedByString:@"\n"] : @"NONE", status[@"initializationStatus"], status[@"unityHierarchyStatus"], status[@"reason"]];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Unity runtime status" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]]; [[self presenter] presentViewController:alert animated:YES completion:nil];
}
- (void)captureUnityScreen {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self captureUnityScreen]; }); return; }
    NSDictionary *runtime = UUIUnityRuntimeStatus(); NSString *captureID = [NSUUID UUID].UUIDString;
    NSMutableDictionary *record = [@{ @"schemaVersion": @"unity-capture-1.0", @"captureID": captureID, @"capturedAt": DateString([NSDate date]), @"build": UUIBuildMetadata(), @"runtime": runtime, @"unityHierarchy": @[], @"unityHierarchyStatus": @"NOT_AVAILABLE", @"coverage": @"No Unity Canvas/UI hierarchy is claimed; only loaded-image markers and the existing UIKit screen snapshot are available." } mutableCopy];
    if ([runtime[@"detected"] boolValue]) {
        SessionCapture *capture = [SessionCapture shared]; NSUInteger unityCount = 0; for (NSDictionary *item in capture.snapshots) if ([item[@"label"] hasPrefix:@"unity-screen-"]) unityCount++;
        if (unityCount >= kUnityMaxSnapshots) { record[@"uikitSnapshotStatus"] = @"NOT_CAPTURED_SNAPSHOT_LIMIT"; record[@"note"] = [NSString stringWithFormat:@"Manual Unity screen snapshot limit (%lu) reached.", (unsigned long)kUnityMaxSnapshots]; }
        else { if (!capture.active) [capture start:self.hostWindow]; [capture capture:self.hostWindow label:[NSString stringWithFormat:@"unity-screen-%@", captureID] inspectorWindow:self.window]; record[@"uikitSnapshotStatus"] = @"CAPTURED_IF_SUPPORTED"; record[@"uikitSnapshotCount"] = @(unityCount + 1); record[@"note"] = @"The screenshot/view data is a UIKit host-window snapshot. Unity Metal content may not be present; no Unity internals were called."; }
    } else { record[@"uikitSnapshotStatus"] = @"NOT_CAPTURED_UNITY_NOT_DETECTED"; record[@"note"] = runtime[@"reason"]; }
    NSURL *directory = [ReportsDirectory() URLByAppendingPathComponent:@"UnitySnapshots" isDirectory:YES]; [[NSFileManager defaultManager] createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
    WriteJSONURL([directory URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.json", captureID]], record);
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Unity capture recorded" message:[NSString stringWithFormat:@"%@\nUnity hierarchy: NOT_AVAILABLE\nSaved: %@", runtime[@"status"], directory.path] preferredStyle:UIAlertControllerStyleAlert]; [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]]; [[self presenter] presentViewController:alert animated:YES completion:nil];
}
- (void)viewUnitySnapshots {
    NSURL *directory = [ReportsDirectory() URLByAppendingPathComponent:@"UnitySnapshots" isDirectory:YES]; NSArray<NSURL *> *urls = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:directory includingPropertiesForKeys:@[NSURLContentModificationDateKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
    NSArray<NSURL *> *jsonURLs = [[urls filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSURL *url, NSDictionary *bindings) { return [url.pathExtension.lowercaseString isEqualToString:@"json"]; }]] sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) { return [b.lastPathComponent compare:a.lastPathComponent]; }];
    NSMutableArray *lines = [NSMutableArray array]; for (NSURL *url in [jsonURLs subarrayWithRange:NSMakeRange(0, MIN(jsonURLs.count, 12))]) { NSDictionary *record = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:url] options:0 error:nil]; NSDictionary *runtime = record[@"runtime"]; [lines addObject:[NSString stringWithFormat:@"%@ — %@ — Unity hierarchy %@", url.lastPathComponent, runtime[@"status"] ?: @"UNKNOWN", record[@"unityHierarchyStatus"] ?: @"NOT_AVAILABLE"]]; }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Unity snapshots" message:lines.count ? [lines componentsJoinedByString:@"\n"] : @"No Unity snapshots recorded. Use CAPTURE UNITY SCREEN to record one explicitly." preferredStyle:UIAlertControllerStyleAlert]; [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]]; [[self presenter] presentViewController:alert animated:YES completion:nil];
}
- (void)exportUnitySession {
    NSURL *reports = ReportsDirectory(); NSURL *snapshots = [reports URLByAppendingPathComponent:@"UnitySnapshots" isDirectory:YES]; NSURL *root = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"UUI-Unity-%@", [NSUUID UUID].UUIDString]] isDirectory:YES];
    NSError *error = nil; [[NSFileManager defaultManager] createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:&error]; if (error) { WriteReport(@"UNITY_EXPORT_ERROR.txt", error.localizedDescription); return; }
    NSDictionary *runtime = UUIUnityRuntimeStatus(); WriteJSONURL([root URLByAppendingPathComponent:@"UNITY_RUNTIME_STATUS.json"], runtime);
    NSURL *snapshotCopy = [root URLByAppendingPathComponent:@"UnitySnapshots" isDirectory:YES]; [[NSFileManager defaultManager] createDirectoryAtURL:snapshotCopy withIntermediateDirectories:YES attributes:nil error:nil];
    NSArray<NSURL *> *statusFiles = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:snapshots includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil]; for (NSURL *file in statusFiles) if ([file.pathExtension.lowercaseString isEqualToString:@"json"]) [[NSFileManager defaultManager] copyItemAtURL:file toURL:[snapshotCopy URLByAppendingPathComponent:file.lastPathComponent] error:nil];
    SessionCapture *capture = [SessionCapture shared]; NSArray *allSnapshots = [capture.snapshots copy]; BOOL wasActive = capture.active; NSMutableArray *unitySnapshots = [NSMutableArray array]; for (NSDictionary *snapshot in allSnapshots) if ([snapshot[@"label"] hasPrefix:@"unity-screen-"]) [unitySnapshots addObject:snapshot]; if (unitySnapshots.count) { capture.snapshots = unitySnapshots; [capture stop]; NSURL *stage = [capture stageSession:self.hostWindow error:&error]; if (stage && !error) [[NSFileManager defaultManager] copyItemAtURL:stage toURL:[root URLByAppendingPathComponent:@"UIKitHostSnapshots" isDirectory:YES] error:&error]; capture.snapshots = [allSnapshots mutableCopy]; capture.active = wasActive; if (error) { WriteReport(@"UNITY_EXPORT_ERROR.txt", error.localizedDescription ?: @"Could not stage Unity-labeled UIKit snapshots."); return; } }
    WriteTextURL([root URLByAppendingPathComponent:@"UNITY_SCOPE.txt"], @"This export contains user-triggered Unity marker status and, when available, UIKit host-window snapshots. It does not contain or claim a Unity Canvas/UI hierarchy. Unity runtime initialization is unverified. Metal content may not appear in UIKit screenshots.\n");
    NSMutableArray *entries = [NSMutableArray array]; NSDirectoryEnumerator *enumerator = [[NSFileManager defaultManager] enumeratorAtURL:root includingPropertiesForKeys:@[NSURLIsDirectoryKey, NSURLFileSizeKey] options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:^BOOL(NSURL *url, NSError *enumerationError) { return NO; }]; for (NSURL *url in enumerator) { NSNumber *isDirectory = nil; [url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil]; if (isDirectory.boolValue || [url.lastPathComponent isEqualToString:@"UNITY_EXPORT_MANIFEST.json"]) continue; NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:url.path error:nil]; [entries addObject:@{ @"path": [url.path substringFromIndex:root.path.length + 1], @"sizeBytes": attributes[NSFileSize] ?: @0, @"checksum": UIIFileChecksum(url) }]; }
    WriteJSONURL([root URLByAppendingPathComponent:@"UNITY_EXPORT_MANIFEST.json"], @{ @"schemaVersion": @"unity-export-1.0", @"overallStatus": @"PARTIAL", @"runtimeStatus": runtime[@"status"] ?: @"UNKNOWN", @"hierarchyStatus": @"NOT_AVAILABLE", @"reason": @"No supported/verified Unity UI bridge is present; export preserves actual status and UIKit-only captures without fabricating Unity nodes.", @"build": UUIBuildMetadata(), @"files": entries, @"generatedAt": DateString([NSDate date]) });
    NSURL *zip = [reports URLByAppendingPathComponent:[NSString stringWithFormat:@"UniversalUIInspector-Unity-Session-%@.zip", [NSUUID UUID].UUIDString]]; NSUInteger count = 0; NSString *why = nil; if (!StreamZipDirectory(root, zip, &count, &why) || count < 3) { WriteReport(@"UNITY_EXPORT_ERROR.txt", why ?: @"Unity export failed file-count validation."); return; }
    [self hideOverlayForSystemUI]; UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[zip] applicationActivities:nil]; share.completionWithItemsHandler = ^(__unused UIActivityType activity, __unused BOOL completed, __unused NSArray *items, __unused NSError *shareError) { [self restoreOverlayAfterSystemUI]; }; [[self presenter] presentViewController:share animated:YES completion:nil];
}


#pragma mark - UI actions

- (void)hideOverlayForSystemUI { self.sharePresented = YES; self.window.hidden = YES; }
- (void)restoreOverlayAfterSystemUI { self.sharePresented = NO; if (self.started) self.window.hidden = NO; }
- (void)showInspectorPanel {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self showInspectorPanel]; }); return; }
    if (self.inspectorPanel.presentingViewController || self.collectionRunning || self.collectorRunning) return;
    BOOL autoReady = [self allCoreCollectorsPassed]; NSDictionary *build = UUIBuildMetadata(); NSString *message = [NSString stringWithFormat:@"UniversalUIInspector %@\nSource revision: %@\nBuild time (UTC): %@\n\nRuntime Dumper — Staged Validation\n\nPASSIVE STARTUP: %@\nLIGHTWEIGHT WARM-UP: %@\nLOADED IMAGES: %@\nRUNTIME CLASSES: %@\nCONTROLLERS: %@\nVIEW HIERARCHY: %@\nAUTO FULL CAPTURE: %@\n\nWarm-up gate: 120s minimum + 6 stable checks.", build[@"version"], build[@"sourceRevision"], build[@"buildTimestampUTC"], self.passiveTestComplete ? @"PASS" : @"RUNNING", self.lightweightWarmupStable ? @"PASS" : (self.lightweightWarmupActive ? @"RUNNING" : @"NOT_STARTED"), [self collectorState:@"loaded_images"], [self collectorState:@"runtime_classes"], [self collectorState:@"controllers"], [self collectorState:@"view_hierarchy"], autoReady ? @"READY (NEXT BUILD)" : @"LOCKED"];
    self.inspectorPanel = [UIAlertController alertControllerWithTitle:@"Universal UI Inspector" message:message preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [self.inspectorPanel addAction:[UIAlertAction actionWithTitle:@"PASSIVE STARTUP STATUS" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [weakSelf showDiagnosticStatus]; }]];
    [self.inspectorPanel addAction:[UIAlertAction actionWithTitle:self.lightweightWarmupActive ? @"LIGHTWEIGHT WARM-UP — RUNNING" : (self.lightweightWarmupStable ? @"LIGHTWEIGHT WARM-UP — PASS" : @"START LIGHTWEIGHT WARM-UP") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { if (!weakSelf.lightweightWarmupStable) [weakSelf startLightweightWarmup]; else [weakSelf showDiagnosticStatus]; }]];
    [self.inspectorPanel addAction:[UIAlertAction actionWithTitle:@"LEGACY COLLECTOR TESTS" style:UIAlertActionStyleDefault handler:nil]];
    [self.inspectorPanel addAction:[UIAlertAction actionWithTitle:@"RUN LEGACY LOADED IMAGES" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { if (weakSelf.lightweightWarmupStable) [weakSelf runLegacyLoadedImages]; else [weakSelf showCollectorLocked:@"LOADED IMAGES"]; }]];
    [self.inspectorPanel addAction:[UIAlertAction actionWithTitle:@"RUN LEGACY RUNTIME CLASSES" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { if (weakSelf.lightweightWarmupStable) [weakSelf runLegacyRuntimeClasses]; else [weakSelf showCollectorLocked:@"RUNTIME CLASSES"]; }]];
    [self.inspectorPanel addAction:[UIAlertAction actionWithTitle:@"RUN LEGACY CONTROLLERS" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { if (weakSelf.lightweightWarmupStable) [weakSelf runLegacyControllers]; else [weakSelf showCollectorLocked:@"CONTROLLERS"]; }]];
    [self.inspectorPanel addAction:[UIAlertAction actionWithTitle:@"RUN LEGACY VIEW HIERARCHY" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { if (weakSelf.lightweightWarmupStable) [weakSelf runLegacyViewHierarchy]; else [weakSelf showCollectorLocked:@"VIEW HIERARCHY"]; }]];
    [self.inspectorPanel addAction:[UIAlertAction actionWithTitle:@"RUN LEGACY DIAGNOSTICS" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { if (weakSelf.lightweightWarmupStable) [weakSelf runLegacyDiagnostics]; else [weakSelf showCollectorLocked:@"DIAGNOSTICS"]; }]];
    [self.inspectorPanel addAction:[UIAlertAction actionWithTitle:autoReady ? @"AUTO FULL CAPTURE — READY (NEXT BUILD)" : @"AUTO FULL CAPTURE — LOCKED" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) { [weakSelf showCollectorLocked:autoReady ? @"AUTO FULL CAPTURE remains disabled in this build" : @"AUTO FULL CAPTURE"]; }]];
    [self.inspectorPanel addAction:[UIAlertAction actionWithTitle:@"STATUS / DIAGNOSTICS" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [weakSelf showDiagnosticStatus]; }]];
    [self.inspectorPanel addAction:[UIAlertAction actionWithTitle:@"EXPORT PARTIAL SESSION" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [weakSelf exportPartialSession]; }]];
    [self.inspectorPanel addAction:[UIAlertAction actionWithTitle:@"EXPORT LAST SESSION" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [weakSelf exportLastSession]; }]];
    [self.inspectorPanel addAction:[UIAlertAction actionWithTitle:@"CAPTURE CURRENT SCREEN" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [weakSelf captureSnapshot]; }]];
    [self.inspectorPanel addAction:[UIAlertAction actionWithTitle:@"DETECT UNITY" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [weakSelf showUnityStatus]; }]];
    [self.inspectorPanel addAction:[UIAlertAction actionWithTitle:@"CAPTURE UNITY SCREEN" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [weakSelf captureUnityScreen]; }]];
    [self.inspectorPanel addAction:[UIAlertAction actionWithTitle:@"VIEW UNITY SNAPSHOTS" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [weakSelf viewUnitySnapshots]; }]];
    [self.inspectorPanel addAction:[UIAlertAction actionWithTitle:@"EXPORT UNITY SESSION" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [weakSelf exportUnitySession]; }]];
    [self.inspectorPanel addAction:[UIAlertAction actionWithTitle:@"RUNTIME CLASSES (DETAILED)" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { if (weakSelf.lightweightWarmupStable) [weakSelf manualDumpRuntimeDetails]; else [weakSelf showCollectorLocked:@"RUNTIME DETAILS"]; }]];
    [self.inspectorPanel addAction:[UIAlertAction actionWithTitle:@"STOP CURRENT COLLECTOR" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) { [weakSelf cancelCurrentPhase]; }]];
    [self.inspectorPanel addAction:[UIAlertAction actionWithTitle:@"CLOSE" style:UIAlertActionStyleCancel handler:nil]];
    UIPopoverPresentationController *popover = self.inspectorPanel.popoverPresentationController; popover.sourceView = self.button; popover.sourceRect = self.button.bounds; popover.permittedArrowDirections = UIPopoverArrowDirectionAny; [[self presenter] presentViewController:self.inspectorPanel animated:YES completion:nil];
}
- (void)showMenu {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self showMenu]; }); return; }
    if (self.collectionRunning || self.preparing || self.sharePresented || self.inspectorPanel.presentingViewController) return;
    NSString *state = self.screenRecorder.isRecording ? [NSString stringWithFormat:@"RECORDING — %lu screens", (unsigned long)self.screenRecorder.screenCount] : @"Capture is paused";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Universal UI Inspector" message:[NSString stringWithFormat:@"%@\nBuild %@ / %@", state, UUIBuildMetadata()[@"version"], UUIBuildMetadata()[@"sourceRevision"]] preferredStyle:UIAlertControllerStyleActionSheet];
    self.inspectorPanel = alert;
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:self.screenRecorder.isRecording ? @"SCREEN CAPTURE — RECORDING" : @"START SCREEN CAPTURE" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [weakSelf startScreenCapture]; }); }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"CAPTURE CURRENT SCREEN" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [weakSelf captureSnapshot]; }); }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"ANALYZE AND EXPORT" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [weakSelf analyzeAndExport]; }); }]];
    NSURL *recoverable = [self latestRecoverableSessionDirectory];
    if (recoverable) [alert addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"RESUME LAST SESSION — %@", recoverable.lastPathComponent] style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [weakSelf resumePreviousSession]; }); }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"STOP / PAUSE CAPTURE" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) { [weakSelf stopScreenCapture]; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"STATUS / LOG" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [weakSelf showCaptureStatus]; }); }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"ADVANCED / DIAGNOSTICS" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [weakSelf showInspectorPanel]; }); }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"CLOSE" style:UIAlertActionStyleCancel handler:nil]];
    UIPopoverPresentationController *popover = alert.popoverPresentationController; popover.sourceView = self.button; popover.sourceRect = self.button.bounds; popover.permittedArrowDirections = UIPopoverArrowDirectionAny;
    [[self presenter] presentViewController:alert animated:YES completion:nil];
}
- (void)searchClass:(NSString *)query {
    if (!query.length) return;
    int count = objc_getClassList(NULL, 0); Class *classes = count > 0 ? (Class *)calloc((size_t)count, sizeof(Class)) : NULL; count = classes ? objc_getClassList(classes, count) : 0; NSMutableArray *matches = [NSMutableArray array]; NSString *needle = query.lowercaseString;
    for (int i = 0; i < count && matches.count < 200; i++) { NSString *name = UIIString(NSStringFromClass(classes[i])); if ([name.lowercaseString rangeOfString:needle].location != NSNotFound) [matches addObject:@{ @"name": name, @"superclass": UIIString(NSStringFromClass(class_getSuperclass(classes[i]))) }]; } free(classes);
    UIAlertController *result = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Matches: %lu", (unsigned long)matches.count] message:@"Runtime class names are process-wide; no unknown selectors are invoked." preferredStyle:UIAlertControllerStyleActionSheet]; __weak typeof(self) weakSelf = self;
    for (NSDictionary *match in matches) [result addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@ : %@", match[@"name"], match[@"superclass"]] style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { weakSelf.selectedClassName = match[@"name"]; }]];
    [result addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel handler:nil]]; [[self presenter] presentViewController:result animated:YES completion:nil];
}
- (NSURL *)latestRecoverableSessionDirectory {
    NSURL *sessions = [ReportsDirectory() URLByAppendingPathComponent:@"Sessions" isDirectory:YES]; NSArray<NSURL *> *directories = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:sessions includingPropertiesForKeys:@[NSURLIsDirectoryKey,NSURLContentModificationDateKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
    NSArray *sorted = [directories sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) { NSDate *da=nil,*db=nil; [a getResourceValue:&da forKey:NSURLContentModificationDateKey error:nil]; [b getResourceValue:&db forKey:NSURLContentModificationDateKey error:nil]; return [db compare:da]; }];
    for (NSURL *directory in sorted) { NSNumber *isDir=nil; [directory getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil]; if (!isDir.boolValue || [directory.lastPathComponent isEqualToString:self.sessionID]) continue; NSURL *index=[directory URLByAppendingPathComponent:@"01_SCREENS/SCREEN_INDEX.json"]; NSURL *stateURL=[directory URLByAppendingPathComponent:@"SESSION_STATE.json"]; NSData *stateData=[NSData dataWithContentsOfURL:stateURL]; NSDictionary *state=stateData.length ? [NSJSONSerialization JSONObjectWithData:stateData options:0 error:nil] : nil; NSData *indexData=[NSData dataWithContentsOfURL:index]; NSDictionary *screenIndex=indexData.length ? [NSJSONSerialization JSONObjectWithData:indexData options:0 error:nil] : nil; if ([screenIndex[@"screens"] count] && ![state[@"status"] isEqualToString:@"complete"]) return directory; }
    return nil;
}
- (void)resumePreviousSession {
    NSURL *directory = [self latestRecoverableSessionDirectory]; if (!directory) { [self startScreenCapture]; return; }
    self.sessionDirectory = directory; self.sessionID = directory.lastPathComponent; self.sessionStartDate = [NSDate date];
    NSData *stateData=[NSData dataWithContentsOfURL:[directory URLByAppendingPathComponent:@"SESSION_STATE.json"]]; NSDictionary *state=stateData.length ? [NSJSONSerialization JSONObjectWithData:stateData options:0 error:nil] : nil;
    self.phaseStatuses=[(state[@"phases"] ?: @{}) mutableCopy]; self.phasesCompleted=[NSMutableArray array]; self.phasesFailed=[NSMutableArray array]; self.phasesSkipped=[NSMutableArray array]; self.filesFailed=[NSMutableArray array]; self.warnings=[NSMutableArray array]; self.limitsReached=[NSMutableArray array]; self.caughtErrors=[NSMutableArray array]; self.zipStatus=@"pending";
    self.screenRecorder=[[UUIVisitedScreenRecorder alloc] initWithSessionDirectory:directory sessionID:self.sessionID buildMetadata:UUIBuildMetadata()];
    UIWindowScene *scene=self.scene; UIWindow *host=FindHostWindow(&scene,NULL); if (scene) self.scene=scene; if (host) self.hostWindow=host;
    if (self.scene) { self.screenCaptureStarted=YES; [self.screenRecorder startWithScene:self.scene inspectorWindow:self.window]; }
    self.lastPhase=@"recovered-screen-session"; UIISetLastOperation(@"SCREEN_SESSION_RECOVERED"); [self appendPhaseLog:@"recovery" line:[NSString stringWithFormat:@"RECOVERED timestamp=%@ session=%@ screens=%lu captures=%lu prior_status=%@",DateString([NSDate date]),self.sessionID,(unsigned long)self.screenRecorder.screenCount,(unsigned long)self.screenRecorder.captureCount,state[@"status"] ?: @"NOT_AVAILABLE"]]; [self updateSessionState];
}
- (void)startScreenCapture {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self startScreenCapture]; }); return; }
    if (self.collectionRunning) return;
    if (!self.sessionDirectory || [self.zipStatus isEqualToString:@"complete"]) [self createSession];
    if (!self.screenRecorder) self.screenRecorder = [[UUIVisitedScreenRecorder alloc] initWithSessionDirectory:self.sessionDirectory sessionID:self.sessionID buildMetadata:UUIBuildMetadata()];
    UIWindowScene *scene = self.scene; UIWindow *host = FindHostWindow(&scene, NULL); if (scene) self.scene = scene; if (host) self.hostWindow = host;
    if (!self.scene) { WriteReport(@"SCREEN_CAPTURE_ERROR.txt", @"No foreground UIWindowScene is available.\n"); return; }
    self.screenCaptureStarted = YES;
    [self.screenRecorder startWithScene:self.scene inspectorWindow:self.window];
    self.lastPhase = @"visited-screen-recording";
    if (self.passiveTestComplete && !self.lightweightWarmupActive && !self.lightweightWarmupStable) [self startLightweightWarmup];
    UIISetLastOperation(@"VISITED_SCREEN_CAPTURE_STARTED"); UIIWriteCrashRecoveryState(@"VISITED_SCREEN_CAPTURE", @"running", self.sessionID, self.sessionDirectory); [self updateSessionState];
}
- (void)stopScreenCapture {
    self.screenCaptureStarted = NO;
    [self.screenRecorder stop];
    self.lastPhase = @"visited-screen-recording-paused";
    UIISetLastOperation(@"VISITED_SCREEN_CAPTURE_PAUSED"); UIIWriteCrashRecoveryState(@"VISITED_SCREEN_CAPTURE", @"paused", self.sessionID, self.sessionDirectory); [self updateSessionState];
}
- (void)captureSnapshot {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self captureSnapshot]; }); return; }
    if (self.collectionRunning) return;
    if (!self.sessionDirectory) [self createSession];
    UIWindowScene *scene = self.scene; UIWindow *host = FindHostWindow(&scene, NULL); if (scene) self.scene = scene; if (host) self.hostWindow = host;
    if (!scene || !self.screenRecorder) { WriteReport(@"SCREEN_CAPTURE_ERROR.txt", @"No foreground window/recorder is available.\n"); return; }
    NSError *error = nil;
    if (![self.screenRecorder captureManualWithScene:scene inspectorWindow:self.window error:&error]) {
        WriteReport(@"SCREEN_CAPTURE_ERROR.txt", [NSString stringWithFormat:@"%@\n", error.localizedDescription ?: @"manual capture failed"]);
    }
    self.lastPhase = @"manual-screen-capture";
    [self appendPhaseLog:@"screens" line:[NSString stringWithFormat:@"CAPTURE timestamp=%@ trigger=manual screens=%lu captures=%lu error=%@", DateString([NSDate date]), (unsigned long)self.screenRecorder.screenCount, (unsigned long)self.screenRecorder.captureCount, error.localizedDescription ?: @"NONE"]];
    if (self.screenRecorder.screenCount) [self updateSessionState];
}
- (void)analyzeAndExport {
    if (self.collectionRunning || self.preparing) return;
    if (!self.sessionDirectory) [self createSession];
    [self stopScreenCapture];
    UIWindowScene *scene = self.scene; UIWindow *host = FindHostWindow(&scene, NULL); if (scene) self.scene = scene; if (host) self.hostWindow = host;
    if (scene && self.screenRecorder) { NSError *finalCaptureError = nil; [self.screenRecorder captureManualWithScene:scene inspectorWindow:self.window error:&finalCaptureError]; if (finalCaptureError) [self.caughtErrors addObject:[NSString stringWithFormat:@"final_screen_capture:%@", finalCaptureError.localizedDescription ?: @"failed"]]; }
    self.forcePartialExport = !self.lightweightWarmupStable;
    [self runOneButtonCollection];
}
- (void)prepareFullCapture:(BOOL)exportAfter {
    if (kDiagnosticStabilityBuild) { [self showDiagnosticStatus]; return; }
    if (self.preparing || self.collectionRunning) return;
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self prepareFullCapture:exportAfter]; }); return; }
    self.preparing = YES; self.pendingExport = exportAfter; self.capturePrepared = NO; self.preparationStarted = CACurrentMediaTime(); self.lastPhase = @"warm-up"; [[SessionCapture shared] stop]; [self createSession];
    WriteJSONURL([self sessionRootFile:@"SESSION_STATE.json"], @{ @"sessionID": self.sessionID, @"status": @"preparing", @"minimumWarmupSeconds": @60, @"warmupStarted": DateString(self.sessionStartDate) });
    self.collectionAlert = [UIAlertController alertControllerWithTitle:@"Preparing runtime" message:@"00:00 / 01:00 — safe observation only\nNavigate through the app to load more modules." preferredStyle:UIAlertControllerStyleAlert]; [self.collectionAlert addAction:[UIAlertAction actionWithTitle:@"CANCEL CURRENT PHASE" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *action) { [self cancelCurrentPhase]; }]]; [[self presenter] presentViewController:self.collectionAlert animated:YES completion:nil]; self.preparationTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(preparationTick) userInfo:nil repeats:YES]; [self preparationTick];
}
- (void)preparationTick {
    if (!self.preparing) return;
    NSTimeInterval elapsed = CACurrentMediaTime() - self.preparationStarted; BOOL hostReady = self.hostWindow && self.hostWindow.rootViewController;
    self.collectionAlert.message = [NSString stringWithFormat:@"%02.0f:%02.0f / 01:00 — %@\nHost window/root: %@\nNavigate normally; no application navigation is forced.", floor(elapsed / 60.0), fmod(elapsed, 60.0), elapsed < 60.0 ? @"warming up" : @"warm-up complete", hostReady ? @"available" : @"waiting"];
    if (elapsed >= 60.0 && hostReady) {
        [self.preparationTimer invalidate]; self.preparationTimer = nil; self.preparing = NO; self.capturePrepared = YES; self.phaseStatuses[@"warmup"] = @"complete"; WriteJSONURL([self sessionRootFile:@"SESSION_INFO.json"], @{ @"schemaVersion": @"2.0", @"sessionID": self.sessionID, @"createdAt": DateString(self.sessionStartDate), @"warmupElapsedSeconds": @(elapsed), @"minimumWarmupSeconds": @60, @"status": @"prepared", @"baselineSnapshot": @NO }); [self updateSessionState]; if (self.collectionAlert.presentingViewController) [self.collectionAlert dismissViewControllerAnimated:YES completion:nil]; self.pendingExport = NO;
    }
}
- (void)showCaptureStatus {
    NSDictionary *capture = [self.screenRecorder statusDictionary] ?: @{};
    NSString *message = [NSString stringWithFormat:@"Build: %@ / %@\nSession: %@\nRecording: %@\nVisited screens: %@\nSaved states/captures: %@\nAutomatic detector: stable after 3 one-second samples\nLightweight runtime gate: %@ (%lu/%lu stable checks)\nLast phase: %@\nLast capture error: %@\nSession directory: %@\n\nThis report covers observed screens only; unvisited app screens cannot be inferred.", UUIBuildMetadata()[@"version"], UUIBuildMetadata()[@"sourceRevision"], self.sessionID ?: @"NOT_AVAILABLE", [capture[@"recording"] boolValue] ? @"YES" : @"NO", capture[@"screen_count"] ?: @0, capture[@"capture_count"] ?: @0, self.lightweightWarmupStable ? @"PASS" : (self.lightweightWarmupActive ? @"RUNNING" : @"NOT_STARTED"), (unsigned long)self.lightweightStableChecks, (unsigned long)kRequiredLightweightStableChecks, self.lastPhase ?: @"NOT_AVAILABLE", capture[@"last_error"] ?: @"NONE", self.sessionDirectory.path ?: @"NOT_AVAILABLE"];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Capture Status / Log" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"VIEW STATUS LOG" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) { WriteReport(@"CAPTURE_STATUS.txt", [message stringByAppendingString:@"\n"]); }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [[self presenter] presentViewController:alert animated:YES completion:nil];
}
- (void)cancelCurrentPhase {
    self.collectionCancelled = YES; self.pendingExport = NO; [self.preparationTimer invalidate]; self.preparationTimer = nil; [self.stabilityTimer invalidate]; self.stabilityTimer = nil; [self.lightweightWarmupTimer invalidate]; self.lightweightWarmupTimer = nil; self.lightweightWarmupActive = NO; self.preparing = NO; self.lastPhase = @"cancelled"; UIISetLastOperation(@"CANCELLED"); UIIWriteCrashRecoveryState(@"CANCELLED", @"cancelled", self.sessionID, self.sessionDirectory); [self appendPhaseLog:@"job" line:[NSString stringWithFormat:@"CANCEL timestamp=%@ phase=%@", DateString([NSDate date]), self.lastPhase]]; [self updateSessionState]; if (self.collectionAlert.presentingViewController) [self.collectionAlert dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Selected class/manual session export

- (void)exportSelectedClass {
    NSString *name = self.selectedClassName; if (!name.length) return; Class cls = NSClassFromString(name); if (!cls) return;
    NSMutableString *text = [NSMutableString stringWithFormat:@"SELECTED_CLASS.txt\nclass=%@\nsuperclass=%@\nimage=%s\n", name, UIIString(NSStringFromClass(class_getSuperclass(cls))), class_getImageName(cls) ?: "NOT_AVAILABLE"];
    unsigned methodCount = 0; Method *methods = class_copyMethodList(cls, &methodCount); for (unsigned i = 0; i < methodCount; i++) [text appendFormat:@"declared instance %@ %s %p\n", UIIString(NSStringFromSelector(method_getName(methods[i]))), method_getTypeEncoding(methods[i]) ?: "NOT_AVAILABLE", method_getImplementation(methods[i])]; free(methods);
    NSURL *stage = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString] isDirectory:YES]; [[NSFileManager defaultManager] createDirectoryAtURL:stage withIntermediateDirectories:YES attributes:nil error:nil]; WriteTextURL([stage URLByAppendingPathComponent:@"SELECTED_CLASS.txt"], text); WriteJSONURL([stage URLByAppendingPathComponent:@"SELECTED_CLASS.json"], @{ @"class": name, @"superclass": UIIString(NSStringFromClass(class_getSuperclass(cls))), @"metadataScope": @"declared Objective-C runtime metadata" }); WriteTextURL([stage URLByAppendingPathComponent:@"SURFACE_ANALYSIS.txt"], @"Analysis only; no application changes were made.\n");
    NSMutableDictionary *files = [NSMutableDictionary dictionary]; for (NSURL *url in [[NSFileManager defaultManager] contentsOfDirectoryAtURL:stage includingPropertiesForKeys:nil options:0 error:nil]) { NSData *data = [NSData dataWithContentsOfURL:url]; if (data) files[url.lastPathComponent] = data; } NSData *zip = ZipData(files); NSURL *url = [stage URLByAppendingPathComponent:@"SelectedClass.zip"]; [zip writeToURL:url options:NSDataWritingAtomic error:nil]; [self hideOverlayForSystemUI]; UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil]; share.completionWithItemsHandler = ^(__unused UIActivityType activity, __unused BOOL completed, __unused NSArray *items, __unused NSError *error) { [self restoreOverlayAfterSystemUI]; }; [[self presenter] presentViewController:share animated:YES completion:nil];
}
- (void)exportSession {
    dispatch_async(dispatch_get_main_queue(), ^{ NSError *error = nil; NSURL *stage = [[SessionCapture shared] stageSession:self.hostWindow error:&error]; if (!stage) { WriteReport(@"SESSION_EXPORT_ERROR.txt", error.localizedDescription ?: @"Unknown error"); return; } NSURL *zipURL = [stage URLByAppendingPathComponent:@"UniversalUIInspector-Session.zip"]; NSUInteger count = 0; NSString *why = nil; if (!StreamZipDirectory(stage, zipURL, &count, &why)) { WriteReport(@"SESSION_EXPORT_ERROR.txt", why ?: @"ZIP creation failed"); return; } [self hideOverlayForSystemUI]; UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[zipURL] applicationActivities:nil]; share.completionWithItemsHandler = ^(__unused UIActivityType activity, __unused BOOL completed, __unused NSArray *items, __unused NSError *error) { [self restoreOverlayAfterSystemUI]; }; [[self presenter] presentViewController:share animated:YES completion:nil]; });
}
- (void)chooseExportFolder { UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.folder"] inMode:UIDocumentPickerModeOpen]; picker.delegate = self; [self hideOverlayForSystemUI]; [[self presenter] presentViewController:picker animated:YES completion:nil]; }
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller { [self restoreOverlayAfterSystemUI]; }
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls { NSURL *url = urls.firstObject; if (url && [url startAccessingSecurityScopedResource]) { self.selectedFolder = url; [self.startup appendFormat:@"Selected export folder: %@\n", url.path]; } [self restoreOverlayAfterSystemUI]; }
- (void)exportReports {
    NSArray *names = @[@"BOOT_DIAGNOSTICS.txt", @"RUNTIME_STARTUP_REPORT.txt", @"STARTUP_VIEW_TREE.txt", @"CURRENT_VIEW_HIERARCHY.txt", @"CURRENT_CONTROLLERS.txt", @"RUNTIME_CLASSES.txt", @"LOADED_IMAGES.txt", @"DIAGNOSTICS.txt"]; NSMutableDictionary *files = [NSMutableDictionary dictionary]; for (NSString *name in names) { NSData *data = [NSData dataWithContentsOfFile:ReportPath(name)]; if (data) files[name] = data; } NSData *zip = ZipData(files); NSURL *url = [ReportsDirectory() URLByAppendingPathComponent:@"UniversalUIInspector-Reports.zip"]; [zip writeToURL:url options:NSDataWritingAtomic error:nil]; [self hideOverlayForSystemUI]; UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil]; share.completionWithItemsHandler = ^(__unused UIActivityType activity, __unused BOOL completed, __unused NSArray *items, __unused NSError *error) { [self restoreOverlayAfterSystemUI]; }; [[self presenter] presentViewController:share animated:YES completion:nil];
}

#pragma mark - FINAL_LOG and sequential coordinator

- (NSArray *)generatedFiles {
    if (!self.sessionDirectory) return @[]; NSMutableArray *files = [NSMutableArray array]; NSDirectoryEnumerator *enumerator = [[NSFileManager defaultManager] enumeratorAtURL:self.sessionDirectory includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:0 errorHandler:^BOOL(NSURL *url, NSError *error) { return YES; }]; for (NSURL *url in enumerator) { NSNumber *isDirectory = nil; [url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil]; if (!isDirectory.boolValue) [files addObject:[url.path substringFromIndex:self.sessionDirectory.path.length + 1]]; } return [files sortedArrayUsingSelector:@selector(compare:)];
}
- (NSDictionary *)writeSessionManifestForStatus:(NSString *)requestedStatus {
    NSDictionary *expectedByPhase = @{
        @"metadata": @[ @"00_METADATA/SESSION_INFO.txt", @"00_METADATA/SESSION_INFO.json", @"00_METADATA/APP_INFO.txt", @"00_METADATA/APP_INFO.json", @"00_METADATA/DEVICE_INFO.txt", @"00_METADATA/DEVICE_INFO.json", @"00_METADATA/BUILD_INFO.json" ],
        @"loaded_images": @[ @"02_IMAGES/LOADED_IMAGES.txt", @"02_IMAGES/LOADED_IMAGES.jsonl", @"02_IMAGES/LOADED_IMAGES_SUMMARY.json" ],
        @"runtime_classes": @[ @"01_RUNTIME/ALL_CLASSES.txt", @"01_RUNTIME/ALL_CLASSES.jsonl", @"01_RUNTIME/CLASS_INDEX_SUMMARY.json" ],
        @"protocols": @[ @"01_RUNTIME/PROTOCOLS.txt", @"01_RUNTIME/PROTOCOLS.jsonl", @"01_RUNTIME/PROTOCOLS_SUMMARY.json" ],
        @"runtime_details": @[ @"01_RUNTIME/DETAILED_CLASSES.txt", @"01_RUNTIME/DETAILED_CLASSES.jsonl", @"01_RUNTIME/DETAILED_CLASSES_SUMMARY.json" ],
        @"controllers": @[ @"03_CONTROLLERS/CONTROLLERS.txt", @"03_CONTROLLERS/CONTROLLER_TREE.txt", @"03_CONTROLLERS/CONTROLLER_VIEW_MAP.txt" ],
        @"windows": @[ @"04_VIEWS/VIEW_TREE_WINDOWS.txt" ],
        @"view_legacy": @[ @"04_VIEWS/VIEW_TREE_LEGACY.txt" ],
        @"view_controller_roots": @[ @"04_VIEWS/VIEW_TREE_CONTROLLERS.txt", @"04_VIEWS/VIEW_TREE_VISIBLE_CONTROLLER.txt" ],
        @"diagnostics": @[ @"06_DIAGNOSTICS/WARNINGS.txt", @"06_DIAGNOSTICS/BOOT_DIAGNOSTICS.txt", @"06_DIAGNOSTICS/RUNTIME_STARTUP_REPORT.txt", @"06_DIAGNOSTICS/STARTUP_VIEW_TREE.txt", @"06_DIAGNOSTICS/DIAGNOSTICS.txt" ],
        @"logs": @[ @"SESSION_STATE.json" ]
    };
    NSMutableArray *expected = [NSMutableArray array]; NSMutableDictionary *fileToPhase = [NSMutableDictionary dictionary];
    for (NSString *phase in expectedByPhase) { NSString *state = self.phaseStatuses[phase] ?: @"pending"; if ([state isEqualToString:@"pending"]) continue; for (NSString *path in expectedByPhase[phase]) { [expected addObject:path]; fileToPhase[path] = phase; } }
    for (NSString *relative in [self generatedFiles]) if ([relative hasPrefix:@"01_SCREENS/"]) { [expected addObject:relative]; fileToPhase[relative] = @"screen_capture"; }
    NSData *screenIndexBytes = [NSData dataWithContentsOfURL:[self.sessionDirectory URLByAppendingPathComponent:@"01_SCREENS/SCREEN_INDEX.json"]]; NSDictionary *screenIndexObject = screenIndexBytes.length ? [NSJSONSerialization JSONObjectWithData:screenIndexBytes options:0 error:nil] : nil;
    for (NSDictionary *screen in screenIndexObject[@"screens"] ?: @[]) for (NSDictionary *state in screen[@"states"] ?: @[]) {
        NSString *folder = [NSString stringWithFormat:@"01_SCREENS/%@", state[@"directory"] ?: @""];
        for (NSString *asset in @[@"CAPTURE_STATUS.json",@"view_tree.json",@"view_tree.txt",@"controller_tree.json",@"controller_tree.txt",@"windows.json",@"visible_elements.json",@"screen_summary.json",@"screen_summary.txt",@"metadata.json"]) { NSString *path = [folder stringByAppendingPathComponent:asset]; if (![expected containsObject:path]) [expected addObject:path]; fileToPhase[path] = @"screen_capture"; }
        NSString *shot = [folder stringByAppendingPathComponent:@"screenshot.png"]; NSString *shotError = [folder stringByAppendingPathComponent:@"screenshot_error.json"]; NSString *shotExpected = [[NSFileManager defaultManager] fileExistsAtPath:[self.sessionDirectory URLByAppendingPathComponent:shot].path] ? shot : ([[NSFileManager defaultManager] fileExistsAtPath:[self.sessionDirectory URLByAppendingPathComponent:shotError].path] ? shotError : shot); if (![expected containsObject:shotExpected]) [expected addObject:shotExpected]; fileToPhase[shotExpected] = @"screen_capture";
    }
    for (NSString *logPath in @[@"07_LOGS/CAPTURE_EVENTS.jsonl",@"07_LOGS/PHASE_EVENTS.jsonl",@"07_LOGS/ERRORS.txt",@"07_LOGS/FINAL_LOG.txt",@"07_LOGS/FINAL_LOG.json"]) { [expected addObject:logPath]; fileToPhase[logPath] = @"logs"; }
    for (NSString *finalPath in @[@"FINAL_LOG.txt",@"FINAL_LOG.json"]) if ([[NSFileManager defaultManager] fileExistsAtPath:[[self.sessionDirectory URLByAppendingPathComponent:finalPath] path]]) [expected addObject:finalPath];
    NSMutableArray *entries = [NSMutableArray array], *missing = [NSMutableArray array], *invalid = [NSMutableArray array]; NSMutableDictionary *jsonRecordCounts = [NSMutableDictionary dictionary];
    for (NSString *relative in [expected sortedArrayUsingSelector:@selector(compare:)]) {
        NSURL *url = [self.sessionDirectory URLByAppendingPathComponent:relative]; BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:url.path]; NSMutableDictionary *entry = [@{ @"path": relative, @"phase": fileToPhase[relative] ?: @"finalization", @"status": exists ? @"PASS" : @"MISSING" } mutableCopy];
        if (!exists) { entry[@"reason"] = @"expected artifact was missing at validation time"; [missing addObject:relative]; [entries addObject:entry]; continue; }
        NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:url.path error:nil]; entry[@"sizeBytes"] = attributes[NSFileSize] ?: @0; entry[@"hash"] = [NSString stringWithFormat:@"sha256:%@", UIIFileSHA256(url)]; entry[@"checksum"] = UIIFileChecksum(url);
        NSString *reason = nil; NSUInteger records = 0; BOOL valid = YES; if ([relative.pathExtension.lowercaseString isEqualToString:@"jsonl"]) { valid = UIIValidateJSONL(url, &records, &reason); jsonRecordCounts[relative] = @(records); } else if ([relative.pathExtension.lowercaseString isEqualToString:@"json"]) { valid = UIIValidateJSONFile(url, &reason); } else if ([relative.pathExtension.lowercaseString isEqualToString:@"png"]) { valid = UIIValidatePNGFile(url, &reason); } else if ([relative.pathExtension.lowercaseString isEqualToString:@"txt"] && !UIIFileEndsWithNewline(url)) { valid = NO; reason = @"text output missing final newline"; }
        if (!valid) { entry[@"status"] = @"PARTIAL"; entry[@"validationError"] = reason ?: @"validation failed"; [invalid addObject:[NSString stringWithFormat:@"%@:%@", relative, reason ?: @"validation failed"]]; }
        if ([relative.pathExtension.lowercaseString isEqualToString:@"jsonl"]) entry[@"recordCount"] = @(records); [entries addObject:entry];
    }
    NSURL *imageSummaryURL = [self.sessionDirectory URLByAppendingPathComponent:@"02_IMAGES/LOADED_IMAGES_SUMMARY.json"]; NSDictionary *imageSummary = [NSDictionary dictionaryWithContentsOfURL:imageSummaryURL]; if (!imageSummary) { NSData *data = [NSData dataWithContentsOfURL:imageSummaryURL]; imageSummary = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil; }
    NSUInteger imageJSONCount = [jsonRecordCounts[@"02_IMAGES/LOADED_IMAGES.jsonl"] unsignedIntegerValue]; NSUInteger imageTextCount = UIIFileLineCount([self.sessionDirectory URLByAppendingPathComponent:@"02_IMAGES/LOADED_IMAGES.txt"]); NSUInteger imageExpected = [imageSummary[@"enumeratedImageCount"] unsignedIntegerValue]; NSUInteger imageWritten = [imageSummary[@"writtenImageCount"] unsignedIntegerValue];
    if (imageSummary && (imageExpected != imageWritten || imageWritten != imageJSONCount || imageWritten != imageTextCount)) [invalid addObject:[NSString stringWithFormat:@"02_IMAGES/loaded-image-count-mismatch expected=%lu written=%lu jsonl=%lu txt=%lu", (unsigned long)imageExpected, (unsigned long)imageWritten, (unsigned long)imageJSONCount, (unsigned long)imageTextCount]];
    BOOL phasesComplete = YES; for (NSString *phase in self.phaseStatuses) { NSString *state = self.phaseStatuses[phase]; if (![state isEqualToString:@"complete"] && ![state isEqualToString:@"skipped"]) { phasesComplete = NO; break; } }
    BOOL captureComplete = [UIIScreenCoverageStatus([self.sessionDirectory URLByAppendingPathComponent:@"01_SCREENS/SCREEN_INDEX.json"]) isEqualToString:@"CAPTURE_COMPLETE_OBSERVED_SCREENS_ONLY"];
    NSString *finalStatus = ([requestedStatus isEqualToString:@"COMPLETE"] && phasesComplete && captureComplete && !missing.count && !invalid.count) ? @"COMPLETE" : @"PARTIAL";
    NSDictionary *manifest = @{ @"schemaVersion": @"2.0", @"sessionID": self.sessionID ?: @"", @"captureStatus": UIIScreenCoverageStatus([self.sessionDirectory URLByAppendingPathComponent:@"01_SCREENS/SCREEN_INDEX.json"]), @"runtimeStatus": (self.forcePartialExport || self.phasesFailed.count) ? @"PARTIAL" : @"COMPLETE", @"exportStatus": self.zipStatus ?: @"pending", @"manifestSelfHash": @"omitted to avoid recursive self-reference", @"coverageScope": @"Observed foreground screens only; this is not full IPA or source-code coverage.", @"overallStatus": finalStatus, @"requestedStatus": requestedStatus ?: @"PARTIAL", @"phaseStatuses": self.phaseStatuses ?: @{}, @"expectedFiles": [expected sortedArrayUsingSelector:@selector(compare:)], @"missingFiles": missing, @"invalidFiles": invalid, @"files": entries, @"loadedImageValidation": @{ @"summaryExpected": @(imageExpected), @"summaryWritten": @(imageWritten), @"jsonlRecords": @(imageJSONCount), @"textLines": @(imageTextCount), @"consistent": @(imageSummary && imageExpected == imageWritten && imageWritten == imageJSONCount && imageWritten == imageTextCount) }, @"generatedAt": DateString([NSDate date]), @"build": UUIBuildMetadata() };
    WriteJSONURL([self sessionRootFile:@"SESSION_MANIFEST.json"], manifest); WriteJSONURL([self sessionRootFile:@"MANIFEST.json"], manifest); WriteJSONURL([ReportsDirectory() URLByAppendingPathComponent:@"SESSION_MANIFEST.json"], manifest); return manifest;
}

- (void)writeFinalLogs:(NSString *)overallStatus {
    self.sessionEndDate = [NSDate date];
    NSData *screenIndexData = [NSData dataWithContentsOfURL:[self.sessionDirectory URLByAppendingPathComponent:@"01_SCREENS/SCREEN_INDEX.json"]]; NSDictionary *screenIndex = screenIndexData.length ? [NSJSONSerialization JSONObjectWithData:screenIndexData options:0 error:nil] : nil;
    NSMutableString *coverage = [NSMutableString stringWithString:@"Coverage report — observed screens only. Unvisited screens cannot be inferred from a running UI.\n"]; NSArray *observed = [screenIndex[@"screens"] isKindOfClass:NSArray.class] ? screenIndex[@"screens"] : @[]; for (NSDictionary *screen in observed) [coverage appendFormat:@"%@ controller=%@ states=%lu first_seen=%@ last_seen=%@ status=%@\n", screen[@"screen_id"] ?: @"NOT_AVAILABLE", screen[@"route_description"] ?: @"NOT_AVAILABLE", (unsigned long)[screen[@"states"] count], screen[@"first_seen"] ?: @"NOT_AVAILABLE", screen[@"last_seen"] ?: @"NOT_AVAILABLE", screen[@"status"] ?: @"NOT_AVAILABLE"];
    WriteTextURL([self.sessionDirectory URLByAppendingPathComponent:@"01_SCREENS/coverage_report.txt"], coverage);
    NSMutableString *errorsText = [NSMutableString string]; for (NSString *error in self.caughtErrors) [errorsText appendFormat:@"%@\n", error]; if (!errorsText.length) [errorsText appendString:@"NONE\n"]; WriteTextURL([self.sessionDirectory URLByAppendingPathComponent:@"07_LOGS/ERRORS.txt"], errorsText);
    NSDictionary *preManifest = [self writeSessionManifestForStatus:overallStatus]; NSString *validatedStatus = preManifest[@"overallStatus"] ?: @"PARTIAL"; NSArray *files = [self generatedFiles]; NSTimeInterval duration = self.sessionStartDate ? [self.sessionEndDate timeIntervalSinceDate:self.sessionStartDate] : 0;
    NSDictionary *json = @{ @"schemaVersion": @"2.1", @"sessionID": self.sessionID ?: @"", @"startTime": DateString(self.sessionStartDate), @"endTime": DateString(self.sessionEndDate), @"durationSeconds": @(duration), @"appBundleIdentifier": self.cachedBundleIdentifier ?: @"NOT_AVAILABLE", @"appVersion": self.cachedAppVersion ?: @"NOT_AVAILABLE", @"build": UUIBuildMetadata(), @"device": self.cachedDeviceModel ?: @"NOT_AVAILABLE", @"os": self.cachedOSVersion ?: @"NOT_AVAILABLE", @"runtimeClassCount": @(self.runtimeClassCount), @"protocolCount": @(self.protocolCount), @"loadedImageCount": @(self.loadedImageCount), @"windowCount": @(self.windowCount), @"controllerCount": @(self.controllerCount), @"viewCounts": @{ @"legacy": @(self.legacyViewCount), @"windows": @(self.windowViewCount), @"controllers": @(self.controllerViewCount), @"visibleController": @(self.visibleControllerViewCount) }, @"uniqueViewCount": @(self.uniqueViewCount), @"maximumDepthObserved": @(self.maximumDepthObserved), @"snapshotCount": @(self.screenRecorder.captureCount), @"filesGenerated": files ?: @[], @"filesFailed": self.filesFailed ?: @[], @"phasesCompleted": self.phasesCompleted ?: @[], @"phasesFailed": self.phasesFailed ?: @[], @"phasesSkipped": self.phasesSkipped ?: @[], @"limitsReached": self.limitsReached ?: @[], @"objectsSkipped": @(self.objectSkips), @"cycleDuplicateSkips": @(self.duplicateSkips), @"caughtErrorsExceptions": self.caughtErrors ?: @[], @"warnings": self.warnings ?: @[], @"timeouts": @[], @"zipStatus": self.zipStatus ?: @"pending", @"manifestStatus": validatedStatus, @"captureStatus": UIIScreenCoverageStatus([self.sessionDirectory URLByAppendingPathComponent:@"01_SCREENS/SCREEN_INDEX.json"]), @"runtimeStatus": (self.forcePartialExport || self.phasesFailed.count) ? @"PARTIAL" : @"COMPLETE", @"exportStatus": self.zipStatus ?: @"pending", @"missingFiles": preManifest[@"missingFiles"] ?: @[], @"invalidFiles": preManifest[@"invalidFiles"] ?: @[], @"overallStatus": validatedStatus };
    NSMutableString *text = [NSMutableString stringWithFormat:@"FINAL_LOG.txt\noverall_status=%@\ncapture_status=%@\nruntime_status=%@\nexport_status=%@\nsession_id=%@\nstart_time=%@\nend_time=%@\nduration_seconds=%.3f\nruntime_class_count=%lu\nloaded_image_count=%lu\nprotocol_count=%lu\nwindow_count=%lu\ncontroller_count=%lu\nmaximum_depth_observed=%lu\nzip_status=%@\nmanifest_status=%@\nmissing_files=%@\ninvalid_files=%@\n", validatedStatus, UIIScreenCoverageStatus([self.sessionDirectory URLByAppendingPathComponent:@"01_SCREENS/SCREEN_INDEX.json"]), ((self.forcePartialExport || self.phasesFailed.count) ? @"PARTIAL" : @"COMPLETE"), self.zipStatus ?: @"pending", self.sessionID ?: @"", DateString(self.sessionStartDate), DateString(self.sessionEndDate), duration, (unsigned long)self.runtimeClassCount, (unsigned long)self.loadedImageCount, (unsigned long)self.protocolCount, (unsigned long)self.windowCount, (unsigned long)self.controllerCount, (unsigned long)self.maximumDepthObserved, self.zipStatus ?: @"pending", validatedStatus, [preManifest[@"missingFiles"] componentsJoinedByString:@" | "] ?: @"NONE", [preManifest[@"invalidFiles"] componentsJoinedByString:@" | "] ?: @"NONE"];
    [text appendFormat:@"files_generated=%@\nphases_completed=%@\nphases_failed=%@\nwarnings=%@\n", [files componentsJoinedByString:@" | "] ?: @"NONE", [self.phasesCompleted componentsJoinedByString:@" | "] ?: @"NONE", [self.phasesFailed componentsJoinedByString:@" | "] ?: @"NONE", [self.warnings componentsJoinedByString:@" | "] ?: @"NONE"];
    WriteTextURL([self sessionRootFile:@"FINAL_LOG.txt"], text); WriteJSONURL([self sessionRootFile:@"FINAL_LOG.json"], json); WriteTextURL([self sessionFile:@"FINAL_LOG.txt" folder:@"07_LOGS"], text); WriteJSONURL([self sessionFile:@"FINAL_LOG.json" folder:@"07_LOGS"], json); WriteReport(@"FINAL_LOG.txt", text); WriteJSONURL([ReportsDirectory() URLByAppendingPathComponent:@"FINAL_LOG.json"], json); [self writeSessionManifestForStatus:validatedStatus];
}
- (void)sanityCheck {
    if (self.runtimeClassCount > 0 && self.runtimeClassCount < 1000) { NSString *warning = [NSString stringWithFormat:@"WARNING_RUNTIME_CLASS_REGRESSION: captured only %lu classes; historical complex targets were on the order of 100k entries.", (unsigned long)self.runtimeClassCount]; if (![self.warnings containsObject:warning]) [self.warnings addObject:warning]; }
    NSUInteger totalViews = self.legacyViewCount + self.windowViewCount + self.controllerViewCount; if (totalViews > 0 && totalViews < 50) { NSString *warning = [NSString stringWithFormat:@"WARNING_VIEW_DUMP_SUSPICIOUSLY_SMALL: combined raw view collector count is %lu; inspect independent reports and LIMIT_REACHED.", (unsigned long)totalViews]; if (![self.warnings containsObject:warning]) [self.warnings addObject:warning]; }
    if (self.limitsReached.count) [self.warnings addObject:@"One or more high configurable safety limits were reached; output is marked partial/suspicious."];
}
- (void)runOneButtonCollection {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self runOneButtonCollection]; }); return; }
    if (self.collectionRunning || self.preparing) return;
    if (!self.sessionDirectory) [self createSession];
    self.collectionRunning = YES; self.collectionCancelled = NO; self.zipStatus = @"pending"; self.finalLogsAlreadyWritten = NO;
    self.collectionAlert = [UIAlertController alertControllerWithTitle:@"ANALYZE AND EXPORT" message:self.lightweightWarmupStable ? @"Running staged collectors sequentially…" : @"Validating saved screens. Heavy collectors are gated until lightweight warm-up passes." preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [self.collectionAlert addAction:[UIAlertAction actionWithTitle:@"CANCEL CURRENT PHASE" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *a) { weakSelf.collectionCancelled = YES; }]];
    [[self presenter] presentViewController:self.collectionAlert animated:YES completion:nil];
    if (self.lightweightWarmupStable) {
        self.forcePartialExport = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self phaseMetadata]; });
        return;
    }
    self.forcePartialExport = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self beginPhase:@"metadata" message:@"Phase 1/3 — metadata and saved-screen validation"];
        WriteJSONURL([self sessionFile:@"APP_INFO.json" folder:@"00_METADATA"], @{ @"schemaVersion":@"uui-app-info-1.0", @"bundleIdentifier":NSBundle.mainBundle.bundleIdentifier ?: @"NOT_AVAILABLE", @"version":[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"NOT_AVAILABLE", @"build":[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"NOT_AVAILABLE", @"buildIdentity":UUIBuildMetadata() });
        WriteJSONURL([self sessionFile:@"DEVICE_INFO.json" folder:@"00_METADATA"], @{ @"schemaVersion":@"uui-device-info-1.0", @"model":UIDevice.currentDevice.model ?: @"NOT_AVAILABLE", @"osVersion":UIDevice.currentDevice.systemVersion ?: @"NOT_AVAILABLE", @"screenBounds":NSStringFromCGRect(UIScreen.mainScreen.bounds), @"screenScale":@(UIScreen.mainScreen.scale) });
        WriteJSONURL([self sessionFile:@"BUILD_INFO.json" folder:@"00_METADATA"], UUIBuildMetadata());
        [self endPhase:@"metadata" state:@"complete" count:3 bytes:0 warning:nil error:nil];
        self.phaseStatuses[@"screen_capture"] = [UIIScreenCoverageStatus([self.sessionDirectory URLByAppendingPathComponent:@"01_SCREENS/SCREEN_INDEX.json"]) isEqualToString:@"CAPTURE_COMPLETE_OBSERVED_SCREENS_ONLY"] ? @"complete" : @"partial";
        if (![self.phaseStatuses[@"screen_capture"] isEqualToString:@"complete"]) { [self.phasesFailed addObject:@"screen_capture"]; [self.caughtErrors addObject:@"No screen captures were saved before export."]; }
        NSArray *gated = @[@"loaded_images",@"runtime_classes",@"protocols",@"runtime_details",@"controllers",@"windows",@"view_legacy",@"view_controller_roots",@"diagnostics"];
        for (NSString *phase in gated) { self.phaseStatuses[phase] = @"skipped"; if (![self.phasesSkipped containsObject:phase]) [self.phasesSkipped addObject:phase]; }
        NSString *reason = @"Runtime collectors skipped: passive-startup plus 120-second lightweight warm-up and six stable samples had not passed. Screen capture remains independent. Run the lightweight gate and analyze again to enable staged collectors.";
        if (![self.warnings containsObject:reason]) [self.warnings addObject:reason];
        [self appendPhaseLog:@"runtime_collectors" line:[NSString stringWithFormat:@"SKIPPED timestamp=%@ reason=%@", DateString([NSDate date]), reason]];
        [self phaseSummary];
    });
}
- (BOOL)phaseCancelled { return self.collectionCancelled; }
- (void)phaseMetadata {
    if ([self phaseCancelled]) { [self finishCollectionWithError:@"cancelled before metadata"]; return; }
    [self beginPhase:@"metadata" message:@"Phase 1/12 — Session/app/device metadata"]; NSDate *now = [NSDate date]; WriteJSONURL([self sessionFile:@"SESSION_INFO.json" folder:@"00_METADATA"], @{ @"schemaVersion": @"2.0", @"sessionID": self.sessionID, @"startTime": DateString(self.sessionStartDate), @"metadataTime": DateString(now), @"warmupSeconds": @60, @"legacyCollectors": @YES }); self.phaseStatuses[@"metadata"] = @"complete"; [self endPhase:@"metadata" state:@"complete" count:1 bytes:0 warning:nil error:nil]; [self phaseLoadedImages];
}
- (void)phaseLoadedImages {
    if ([self phaseCancelled]) { [self finishCollectionWithError:@"cancelled before loaded images"]; return; }
    [self beginPhase:@"loaded_images" message:@"Phase 2/12 — Loaded Images / dyld"]; NSURL *text = [self sessionFile:@"LOADED_IMAGES.txt" folder:@"02_IMAGES"]; NSURL *jsonl = [self sessionFile:@"LOADED_IMAGES.jsonl" folder:@"02_IMAGES"]; NSURL *summary = [self sessionFile:@"LOADED_IMAGES_SUMMARY.json" folder:@"02_IMAGES"]; __weak typeof(self) weakSelf = self; dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ @autoreleasepool { @try { NSUInteger count = LegacyWriteLoadedImages(text, jsonl, summary); dispatch_async(dispatch_get_main_queue(), ^{ weakSelf.loadedImageCount = count; [weakSelf mirrorReport:@"LOADED_IMAGES.txt" from:text]; [weakSelf endPhase:@"loaded_images" state:@"complete" count:count bytes:(NSUInteger)[[[NSFileManager defaultManager] attributesOfItemAtPath:text.path error:nil][NSFileSize] unsignedLongLongValue] warning:nil error:nil]; [weakSelf phaseRuntimeIndex]; }); } @catch (NSException *exception) { dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf endPhase:@"loaded_images" state:@"failed" count:0 bytes:0 warning:nil error:exception.reason ?: @"exception"]; [weakSelf phaseRuntimeIndex]; }); } } });
}
- (void)phaseRuntimeIndex {
    if ([self phaseCancelled]) { [self finishCollectionWithError:@"cancelled before runtime class index"]; return; }
    [self beginPhase:@"runtime_classes" message:@"Phase 3/12 — Runtime Classes (complete index)"]; NSURL *jsonl = [self sessionFile:@"ALL_CLASSES.jsonl" folder:@"01_RUNTIME"]; NSURL *text = [self sessionFile:@"ALL_CLASSES.txt" folder:@"01_RUNTIME"]; NSURL *summary = [self sessionFile:@"CLASS_INDEX_SUMMARY.json" folder:@"01_RUNTIME"]; __weak typeof(self) weakSelf = self; dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ @autoreleasepool { @try { NSUInteger count = LegacyWriteRuntimeClassIndex(jsonl, text, summary); dispatch_async(dispatch_get_main_queue(), ^{ weakSelf.runtimeClassCount = count; [weakSelf mirrorReport:@"ALL_CLASSES.txt" from:text]; [weakSelf endPhase:@"runtime_classes" state:@"complete" count:count bytes:(NSUInteger)[[[NSFileManager defaultManager] attributesOfItemAtPath:text.path error:nil][NSFileSize] unsignedLongLongValue] warning:nil error:nil]; [weakSelf phaseProtocols]; }); } @catch (NSException *exception) { dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf endPhase:@"runtime_classes" state:@"failed" count:0 bytes:0 warning:@"WARNING_RUNTIME_CLASS_REGRESSION" error:exception.reason ?: @"exception"]; [weakSelf phaseProtocols]; }); } } });
}
- (void)phaseProtocols {
    if ([self phaseCancelled]) { [self finishCollectionWithError:@"cancelled before protocols"]; return; }
    [self beginPhase:@"protocols" message:@"Phase 4/12 — Protocol enumeration"]; NSURL *text = [self sessionFile:@"PROTOCOLS.txt" folder:@"01_RUNTIME"]; NSURL *jsonl = [self sessionFile:@"PROTOCOLS.jsonl" folder:@"01_RUNTIME"]; NSURL *summary = [self sessionFile:@"PROTOCOLS_SUMMARY.json" folder:@"01_RUNTIME"]; __weak typeof(self) weakSelf = self; dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ @autoreleasepool { @try { NSUInteger count = LegacyWriteProtocols(text, jsonl, summary); dispatch_async(dispatch_get_main_queue(), ^{ weakSelf.protocolCount = count; [weakSelf endPhase:@"protocols" state:@"complete" count:count bytes:0 warning:nil error:nil]; [weakSelf phaseRuntimeDetails]; }); } @catch (NSException *exception) { dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf endPhase:@"protocols" state:@"failed" count:0 bytes:0 warning:nil error:exception.reason ?: @"exception"]; [weakSelf phaseRuntimeDetails]; }); } } });
}
- (void)phaseRuntimeDetails {
    if ([self phaseCancelled]) { [self finishCollectionWithError:@"cancelled before runtime detail pass"]; return; }
    [self beginPhase:@"runtime_details" message:@"Phase 5/12 — Detailed Runtime Metadata (streamed)"]; NSURL *jsonl = [self sessionFile:@"DETAILED_CLASSES.jsonl" folder:@"01_RUNTIME"]; NSURL *text = [self sessionFile:@"DETAILED_CLASSES.txt" folder:@"01_RUNTIME"]; NSURL *summary = [self sessionFile:@"DETAILED_CLASSES_SUMMARY.json" folder:@"01_RUNTIME"]; __weak typeof(self) weakSelf = self; dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ @autoreleasepool { @try { NSUInteger count = LegacyWriteRuntimeDetails(jsonl, text, summary); dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf endPhase:@"runtime_details" state:@"complete" count:count bytes:0 warning:nil error:nil]; [weakSelf phaseControllers]; }); } @catch (NSException *exception) { dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf endPhase:@"runtime_details" state:@"failed" count:0 bytes:0 warning:@"Detailed enrichment failed; complete class index is preserved." error:exception.reason ?: @"exception"]; [weakSelf phaseControllers]; }); } } });
}
- (void)phaseControllers {
    if ([self phaseCancelled]) { [self finishCollectionWithError:@"cancelled before controllers"]; return; }
    [self beginPhase:@"controllers" message:@"Phase 6/12 — UIViewController enumeration"]; NSURL *controllers = [self sessionFile:@"CONTROLLERS.txt" folder:@"03_CONTROLLERS"]; NSURL *tree = [self sessionFile:@"CONTROLLER_TREE.txt" folder:@"03_CONTROLLERS"]; NSURL *map = [self sessionFile:@"CONTROLLER_VIEW_MAP.txt" folder:@"03_CONTROLLERS"]; __weak typeof(self) weakSelf = self; dispatch_async(dispatch_get_main_queue(), ^{ @try { BOOL truncated = NO; NSUInteger duplicates = 0, depth = 0; NSUInteger count = LegacyWriteControllers(weakSelf.hostWindow, controllers, tree, map, kFullCaptureMaxDepth, kFullCaptureMaxNodes, &truncated, &duplicates, &depth); weakSelf.controllerCount = count; weakSelf.duplicateSkips += duplicates; weakSelf.maximumDepthObserved = MAX(weakSelf.maximumDepthObserved, depth); if (truncated) [weakSelf.limitsReached addObject:@"controllers"]; [weakSelf endPhase:@"controllers" state:truncated ? @"partial" : @"complete" count:count bytes:0 warning:truncated ? @"LIMIT_REACHED controllers" : nil error:nil]; [weakSelf phaseWindows]; } @catch (NSException *exception) { [weakSelf endPhase:@"controllers" state:@"failed" count:0 bytes:0 warning:nil error:exception.reason ?: @"exception"]; [weakSelf phaseWindows]; } });
}
- (void)phaseWindows {
    if ([self phaseCancelled]) { [self finishCollectionWithError:@"cancelled before windows"]; return; }
    [self beginPhase:@"windows" message:@"Phase 7/12 — UIWindow scenes and recursive windows"]; NSURL *url = [self sessionFile:@"VIEW_TREE_WINDOWS.txt" folder:@"04_VIEWS"]; __weak typeof(self) weakSelf = self; dispatch_async(dispatch_get_main_queue(), ^{ @try { BOOL truncated = NO; NSUInteger windows = 0, duplicates = 0, depth = 0; NSUInteger count = LegacyWriteWindowHierarchy(url, kFullCaptureMaxDepth, kFullCaptureMaxNodes, &truncated, &windows, &duplicates, &depth); weakSelf.windowCount = windows; weakSelf.windowViewCount = count; weakSelf.duplicateSkips += duplicates; weakSelf.maximumDepthObserved = MAX(weakSelf.maximumDepthObserved, depth); if (truncated) [weakSelf.limitsReached addObject:@"windows"]; [weakSelf endPhase:@"windows" state:truncated ? @"partial" : @"complete" count:count bytes:0 warning:truncated ? @"LIMIT_REACHED windows" : nil error:nil]; [weakSelf phaseLegacyView]; } @catch (NSException *exception) { [weakSelf endPhase:@"windows" state:@"failed" count:0 bytes:0 warning:nil error:exception.reason ?: @"exception"]; [weakSelf phaseLegacyView]; } });
}
- (void)phaseLegacyView {
    if ([self phaseCancelled]) { [self finishCollectionWithError:@"cancelled before legacy view hierarchy"]; return; }
    [self beginPhase:@"view_legacy" message:@"Phase 8/12 — Legacy visible hierarchy"]; NSURL *url = [self sessionFile:@"VIEW_TREE_LEGACY.txt" folder:@"04_VIEWS"]; __weak typeof(self) weakSelf = self; dispatch_async(dispatch_get_main_queue(), ^{ @try { BOOL truncated = NO; NSUInteger count = LegacyWriteVisibleHierarchy(weakSelf.hostWindow, url, kFullCaptureMaxDepth, kFullCaptureMaxNodes, &truncated); weakSelf.legacyViewCount = count; weakSelf.uniqueViewCount = MAX(weakSelf.uniqueViewCount, count); if (truncated) [weakSelf.limitsReached addObject:@"view_legacy"]; [weakSelf mirrorReport:@"VIEW_TREE_LEGACY.txt" from:url]; [weakSelf endPhase:@"view_legacy" state:truncated ? @"partial" : @"complete" count:count bytes:0 warning:count < 50 ? @"WARNING_VIEW_DUMP_SUSPICIOUSLY_SMALL" : (truncated ? @"LIMIT_REACHED view_legacy" : nil) error:nil]; [weakSelf phaseSecondaryViews]; } @catch (NSException *exception) { [weakSelf endPhase:@"view_legacy" state:@"failed" count:0 bytes:0 warning:@"WARNING_VIEW_DUMP_SUSPICIOUSLY_SMALL" error:exception.reason ?: @"exception"]; [weakSelf phaseSecondaryViews]; } });
}
- (void)phaseSecondaryViews {
    if ([self phaseCancelled]) { [self finishCollectionWithError:@"cancelled before secondary view captures"]; return; }
    [self beginPhase:@"view_controller_roots" message:@"Phase 9/12 — Controller-root and visible-controller hierarchies"]; NSURL *controllerTree = [self sessionFile:@"VIEW_TREE_CONTROLLERS.txt" folder:@"04_VIEWS"]; NSURL *visibleTree = [self sessionFile:@"VIEW_TREE_VISIBLE_CONTROLLER.txt" folder:@"04_VIEWS"]; __weak typeof(self) weakSelf = self; dispatch_async(dispatch_get_main_queue(), ^{ @try { BOOL truncated = NO; NSUInteger duplicates = 0, depth = 0; NSUInteger controllerCount = LegacyWriteControllerViewHierarchy(weakSelf.hostWindow, controllerTree, kFullCaptureMaxDepth, kFullCaptureMaxNodes, &truncated, &duplicates, &depth); BOOL visibleTruncated = NO; NSUInteger visibleDuplicates = 0, visibleDepth = 0; NSUInteger visibleCount = LegacyWriteVisibleControllerHierarchy(weakSelf.hostWindow, visibleTree, kFullCaptureMaxDepth, kFullCaptureMaxNodes, &visibleTruncated, &visibleDuplicates, &visibleDepth); weakSelf.controllerViewCount = controllerCount; weakSelf.visibleControllerViewCount = visibleCount; weakSelf.duplicateSkips += duplicates + visibleDuplicates; weakSelf.maximumDepthObserved = MAX(weakSelf.maximumDepthObserved, MAX(depth, visibleDepth)); if (truncated || visibleTruncated) [weakSelf.limitsReached addObject:@"view_controller_roots"]; [weakSelf endPhase:@"view_controller_roots" state:(truncated || visibleTruncated) ? @"partial" : @"complete" count:controllerCount + visibleCount bytes:0 warning:(truncated || visibleTruncated) ? @"LIMIT_REACHED view_controller_roots" : nil error:nil]; [weakSelf phaseDiagnostics]; } @catch (NSException *exception) { [weakSelf endPhase:@"view_controller_roots" state:@"failed" count:0 bytes:0 warning:nil error:exception.reason ?: @"exception"]; [weakSelf phaseDiagnostics]; } });
}
- (void)phaseDiagnostics {
    if ([self phaseCancelled]) { [self finishCollectionWithError:@"cancelled before diagnostics"]; return; }
    [self beginPhase:@"diagnostics" message:@"Phase 10/12 — Diagnostics and sanity checks"]; [self sanityCheck]; NSString *warnings = self.warnings.count ? [self.warnings componentsJoinedByString:@"\n"] : @"NONE"; WriteTextURL([self sessionFile:@"WARNINGS.txt" folder:@"06_DIAGNOSTICS"], warnings); WriteTextURL([self sessionFile:@"BOOT_DIAGNOSTICS.txt" folder:@"06_DIAGNOSTICS"], [self.startup copy]); WriteTextURL([self sessionFile:@"RUNTIME_STARTUP_REPORT.txt" folder:@"06_DIAGNOSTICS"], [NSString stringWithFormat:@"runtimeClassCount=%lu\nloadedImageCount=%lu\nwindowCount=%lu\ncontrollerCount=%lu\n", (unsigned long)self.runtimeClassCount, (unsigned long)self.loadedImageCount, (unsigned long)self.windowCount, (unsigned long)self.controllerCount]); WriteTextURL([self sessionFile:@"STARTUP_VIEW_TREE.txt" folder:@"06_DIAGNOSTICS"], [NSString stringWithContentsOfURL:[ReportsDirectory() URLByAppendingPathComponent:@"STARTUP_VIEW_TREE.txt"] encoding:NSUTF8StringEncoding error:nil] ?: @"NOT_AVAILABLE\n"); WriteTextURL([self sessionFile:@"DIAGNOSTICS.txt" folder:@"06_DIAGNOSTICS"], [self diagnostics]); [self endPhase:@"diagnostics" state:@"complete" count:self.warnings.count bytes:0 warning:self.warnings.count ? @"Warnings recorded; inspect WARNINGS.txt" : nil error:nil]; [self phaseSummary];
}
- (void)phaseSummary {
    [self beginPhase:@"summary" message:@"Phase 11/12 — Summary and final logs"]; [self writeFinalLogs:(self.forcePartialExport || self.phasesFailed.count) ? @"PARTIAL" : @"COMPLETE"]; [self endPhase:@"summary" state:@"complete" count:self.generatedFiles.count bytes:0 warning:nil error:nil]; [self phaseZip];
}
- (void)phaseZip {
    if ([self phaseCancelled]) { [self finishCollectionWithError:@"cancelled before ZIP creation"]; return; }
    [self beginPhase:@"zip" message:@"Phase 12/12 — Creating RuntimeDump ZIP (streaming)"]; NSURL *directory = self.sessionDirectory; NSURL *parent = [directory URLByDeletingLastPathComponent]; NSURL *zipURL = [parent URLByAppendingPathComponent:@"RuntimeDump.zip"]; __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ @autoreleasepool { NSString *errorText = nil; NSUInteger fileCount = 0; BOOL firstPass = StreamZipDirectory(directory, zipURL, &fileCount, &errorText); dispatch_async(dispatch_get_main_queue(), ^{ if (!firstPass) { weakSelf.zipStatus = @"failed"; [weakSelf endPhase:@"zip" state:@"failed" count:fileCount bytes:0 warning:nil error:errorText ?: @"ZIP creation failed"]; [weakSelf finishCollectionWithURL:nil error:errorText ?: @"ZIP creation failed"]; return; } weakSelf.zipStatus = @"complete"; [weakSelf endPhase:@"zip" state:@"complete" count:fileCount bytes:0 warning:nil error:nil]; weakSelf.collectionRunning = NO; [weakSelf updateSessionState]; [weakSelf writeFinalLogs:(weakSelf.forcePartialExport || weakSelf.phasesFailed.count) ? @"PARTIAL" : @"COMPLETE"]; NSUInteger expectedFileCount = weakSelf.generatedFiles.count; dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ @autoreleasepool { NSString *secondError = nil; NSUInteger secondCount = 0; BOOL secondPass = StreamZipDirectory(directory, zipURL, &secondCount, &secondError); NSData *zipData = secondPass ? [NSData dataWithContentsOfURL:zipURL] : nil; NSUInteger verifiedCount = 0; NSString *verifyReason = nil; BOOL valid = secondPass && ValidateZipArchive(zipData, &verifiedCount, &verifyReason) && verifiedCount == secondCount && secondCount == expectedFileCount; if (!valid && !verifyReason.length) verifyReason = [NSString stringWithFormat:@"ZIP manifest count mismatch expected=%lu created=%lu verified=%lu", (unsigned long)expectedFileCount, (unsigned long)secondCount, (unsigned long)verifiedCount]; dispatch_async(dispatch_get_main_queue(), ^{ if (valid) { weakSelf.zipURL = zipURL; weakSelf.zipStatus = @"complete"; weakSelf.finalLogsAlreadyWritten = YES; [weakSelf finishCollectionWithURL:zipURL error:nil]; } else { weakSelf.zipURL = nil; weakSelf.zipStatus = @"failed"; [weakSelf endPhase:@"zip" state:@"partial" count:verifiedCount bytes:zipData.length warning:@"ZIP validation failed" error:verifyReason ?: @"ZIP validation failed"]; [weakSelf finishCollectionWithURL:nil error:verifyReason ?: @"ZIP validation failed"]; } }); } }); }); } });
}
- (void)finishCollectionWithError:(NSString *)error { [self finishCollectionWithURL:nil error:error]; }
- (void)finishCollectionWithURL:(NSURL *)url error:(NSString *)error {
    if (error.length) { [self.caughtErrors addObject:error]; self.zipStatus = url ? self.zipStatus : @"failed"; }
    self.collectionRunning = NO; self.sessionEndDate = [NSDate date]; BOOL skipFinalLogWrite = self.finalLogsAlreadyWritten && !error.length; self.finalLogsAlreadyWritten = NO; if (!skipFinalLogWrite) { [self writeFinalLogs:error.length ? @"PARTIAL" : @"COMPLETE"]; [self updateSessionState]; }
    if (self.collectionAlert.presentingViewController) { NSString *message = error.length ? [NSString stringWithFormat:@"Partial session preserved.\n%@\n%@", error, self.sessionDirectory.path] : [NSString stringWithFormat:@"Export package ready (%@).\n%@\nZIP: %@", ((self.forcePartialExport || self.phasesFailed.count || ![UIIScreenCoverageStatus([self.sessionDirectory URLByAppendingPathComponent:@"01_SCREENS/SCREEN_INDEX.json"]) isEqualToString:@"CAPTURE_COMPLETE_OBSERVED_SCREENS_ONLY"]) ? @"PARTIAL" : @"COMPLETE"), self.sessionDirectory.path, url.path]; [self.collectionAlert dismissViewControllerAnimated:YES completion:^{ if (url) { [self hideOverlayForSystemUI]; UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil]; share.completionWithItemsHandler = ^(__unused UIActivityType activity, __unused BOOL completed, __unused NSArray *items, __unused NSError *shareError) { [self restoreOverlayAfterSystemUI]; }; [[self presenter] presentViewController:share animated:YES completion:nil]; } else { UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Partial capture preserved" message:message preferredStyle:UIAlertControllerStyleAlert]; [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]]; [[self presenter] presentViewController:alert animated:YES completion:nil]; } }]; }
}
@end

static void UniversalUIInspectorInit(void) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ UIApplication *application = UIApplication.sharedApplication; if (application.applicationState == UIApplicationStateActive || application.applicationState == UIApplicationStateInactive) [InspectorCore.shared start]; }); }
__attribute__((constructor)) static void UniversalUIInspectorConstructor(void) { UniversalUIInspectorInit(); }
