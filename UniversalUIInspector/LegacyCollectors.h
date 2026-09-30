#import <UIKit/UIKit.h>
#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

NSDictionary *UUIBuildMetadata(void);

// These functions are the restored manual collectors. The automatic coordinator
// calls these same functions; it does not use a second generic scanner.
NSUInteger LegacyWriteRuntimeClassIndex(NSURL *jsonlURL, NSURL *textURL, NSURL *summaryURL);
NSUInteger LegacyWriteRuntimeDetails(NSURL *jsonlURL, NSURL *textURL, NSURL *summaryURL);
NSUInteger LegacyWriteProtocols(NSURL *textURL, NSURL *jsonlURL, NSURL *summaryURL);
NSUInteger LegacyWriteLoadedImages(NSURL *textURL, NSURL *jsonlURL, NSURL *summaryURL);

NSUInteger LegacyWriteVisibleHierarchy(UIWindow *host,
                                       NSURL *url,
                                       NSUInteger maxDepth,
                                       NSUInteger maxNodes,
                                       BOOL * _Nullable truncated);

NSUInteger LegacyWriteWindowHierarchy(NSURL *url,
                                      NSUInteger maxDepth,
                                      NSUInteger maxNodes,
                                      BOOL * _Nullable truncated,
                                      NSUInteger * _Nullable windowCount,
                                      NSUInteger * _Nullable duplicateSkips,
                                      NSUInteger * _Nullable maxDepthObserved);

NSUInteger LegacyWriteControllers(UIWindow * _Nullable host,
                                  NSURL *controllersURL,
                                  NSURL *treeURL,
                                  NSURL *viewMapURL,
                                  NSUInteger maxDepth,
                                  NSUInteger maxNodes,
                                  BOOL * _Nullable truncated,
                                  NSUInteger * _Nullable duplicateSkips,
                                  NSUInteger * _Nullable maxDepthObserved);

NSUInteger LegacyWriteControllerViewHierarchy(UIWindow * _Nullable host,
                                              NSURL *url,
                                              NSUInteger maxDepth,
                                              NSUInteger maxNodes,
                                              BOOL * _Nullable truncated,
                                              NSUInteger * _Nullable duplicateSkips,
                                              NSUInteger * _Nullable maxDepthObserved);

NSUInteger LegacyWriteVisibleControllerHierarchy(UIWindow * _Nullable host,
                                                  NSURL *url,
                                                  NSUInteger maxDepth,
                                                  NSUInteger maxNodes,
                                                  BOOL * _Nullable truncated,
                                                  NSUInteger * _Nullable duplicateSkips,
                                                  NSUInteger * _Nullable maxDepthObserved);

NS_ASSUME_NONNULL_END
