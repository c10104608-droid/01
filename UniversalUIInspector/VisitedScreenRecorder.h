#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface UUIVisitedScreenRecorder : NSObject
@property(nonatomic, readonly, getter=isRecording) BOOL recording;
@property(nonatomic, readonly) NSUInteger screenCount;
@property(nonatomic, readonly) NSUInteger captureCount;
@property(nonatomic, copy, readonly) NSString *lastError;

- (instancetype)initWithSessionDirectory:(NSURL *)sessionDirectory
                               sessionID:(NSString *)sessionID
                            buildMetadata:(NSDictionary *)buildMetadata;
- (void)startWithScene:(UIWindowScene *)scene inspectorWindow:(nullable UIWindow *)inspectorWindow;
- (void)stop;
- (BOOL)captureManualWithScene:(UIWindowScene *)scene
                inspectorWindow:(nullable UIWindow *)inspectorWindow
                          error:(NSError * _Nullable * _Nullable)error;
- (NSDictionary *)statusDictionary;

@end

NS_ASSUME_NONNULL_END
