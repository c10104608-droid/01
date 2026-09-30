#import "VisitedScreenRecorder.h"
#import <CommonCrypto/CommonDigest.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

static NSString *UUIVDate(NSDate *date) {
    static NSISO8601DateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ formatter = [NSISO8601DateFormatter new]; });
    return [formatter stringFromDate:date ?: [NSDate date]];
}
static NSString *UUIVSHA256(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}
static NSString *UUIVHashString(NSString *value) {
    return UUIVSHA256([(value ?: @"") dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data]);
}
static NSString *UUIVSafe(NSString *value, NSUInteger limit) {
    if (![value isKindOfClass:NSString.class] || !value.length) return @"NOT_AVAILABLE";
    NSString *flat = [[value stringByReplacingOccurrencesOfString:@"\r" withString:@"\\r"] stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
    return flat.length > limit ? [[flat substringToIndex:limit] stringByAppendingString:@"…"] : flat;
}
static NSDictionary *UUIVRect(CGRect r) {
    return @{ @"x": @(r.origin.x), @"y": @(r.origin.y), @"width": @(r.size.width), @"height": @(r.size.height) };
}
static NSDictionary *UUIVPoint(CGPoint p) { return @{ @"x": @(p.x), @"y": @(p.y) }; }
static BOOL UUIVContains(NSString *value, NSString *part) {
    return value.length && part.length && [value rangeOfString:part options:NSCaseInsensitiveSearch].location != NSNotFound;
}
static const NSUInteger kUUIVMaxScreensPerSession = 200;
static const NSUInteger kUUIVMaxCapturesPerSession = 200;
static const NSUInteger kUUIVMaxStatesPerScreen = 25;
static BOOL UUIVIsExcludedWindow(UIWindow *window, UIWindow *inspector) {
    if (!window || window == inspector || window.hidden || window.alpha < 0.01) return YES;
    NSString *name = NSStringFromClass(window.class) ?: @"";
    NSString *rootName = window.rootViewController ? NSStringFromClass(window.rootViewController.class) : @"";
    if (UUIVContains(name, @"FLEX") || UUIVContains(rootName, @"FLEX") || UUIVContains(name, @"Keyboard") || UUIVContains(name, @"TextEffects")) return YES;
    if (window.windowLevel != UIWindowLevelNormal || !window.rootViewController || CGRectIsEmpty(window.bounds)) return YES;
    return NO;
}
static NSArray<UIWindow *> *UUIVContentWindows(UIWindowScene *scene, UIWindow *inspector) {
    NSMutableArray *windows = [NSMutableArray array];
    for (UIWindow *window in scene.windows) if (!UUIVIsExcludedWindow(window, inspector)) [windows addObject:window];
    [windows sortUsingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
        if (a.isKeyWindow != b.isKeyWindow) return a.isKeyWindow ? NSOrderedAscending : NSOrderedDescending;
        return NSOrderedSame;
    }];
    return windows;
}
static UIViewController *UUIVVisibleController(UIViewController *controller) {
    if (!controller) return nil;
    if (controller.presentedViewController && !UUIVContains(NSStringFromClass(controller.presentedViewController.class), @"UIActivityViewController") && !UUIVContains(NSStringFromClass(controller.presentedViewController.class), @"DocumentPicker")) return UUIVVisibleController(controller.presentedViewController);
    if ([controller isKindOfClass:UINavigationController.class]) return UUIVVisibleController(((UINavigationController *)controller).visibleViewController);
    if ([controller isKindOfClass:UITabBarController.class]) return UUIVVisibleController(((UITabBarController *)controller).selectedViewController);
    if ([controller isKindOfClass:UISplitViewController.class]) {
        NSArray *children = ((UISplitViewController *)controller).viewControllers;
        return UUIVVisibleController(children.lastObject ?: controller);
    }
    return controller;
}
static void UUIVAppendControllerRoute(UIViewController *controller, NSMutableArray<NSString *> *parts, NSUInteger depth, NSMutableSet<NSValue *> *seen) {
    if (!controller || depth > 12) return;
    NSValue *key = [NSValue valueWithNonretainedObject:controller];
    if ([seen containsObject:key]) return;
    [seen addObject:key];
    [parts addObject:NSStringFromClass(controller.class) ?: @"UIViewController"];
    if ([controller isKindOfClass:UINavigationController.class]) {
        for (UIViewController *item in ((UINavigationController *)controller).viewControllers) [parts addObject:[NSString stringWithFormat:@"nav:%@", NSStringFromClass(item.class) ?: @"?"]];
    } else if ([controller isKindOfClass:UITabBarController.class]) {
        UIViewController *selected = ((UITabBarController *)controller).selectedViewController;
        [parts addObject:[NSString stringWithFormat:@"tab:%@", selected ? NSStringFromClass(selected.class) : @"?"]];
    } else if ([controller isKindOfClass:UISplitViewController.class]) {
        for (UIViewController *item in ((UISplitViewController *)controller).viewControllers) [parts addObject:[NSString stringWithFormat:@"split:%@", NSStringFromClass(item.class) ?: @"?"]];
    }
    UUIVAppendControllerRoute(controller.presentedViewController, parts, depth + 1, seen);
}
static void UUIVAppendViewFingerprint(UIView *view, NSUInteger depth, NSUInteger *budget, NSMutableString *out) {
    if (!view || !*budget || depth > 4 || view.hidden || view.alpha < 0.02) return;
    (*budget)--;
    NSString *className = NSStringFromClass(view.class) ?: @"UIView";
    if (UUIVContains(className, @"FLEX")) return;
    NSString *identifier = @"";
    @try { identifier = UUIVSafe(view.accessibilityIdentifier, 80); } @catch (__unused NSException *e) { }
    NSUInteger visibleChildren = 0;
    for (UIView *child in view.subviews) if (!child.hidden && child.alpha >= 0.02) visibleChildren++;
    NSString *textToken = @""; NSString *accessibilityToken = @""; NSString *controlState = @"";
    @try {
        NSString *visibleText = nil;
        if ([view isKindOfClass:UILabel.class]) visibleText = ((UILabel *)view).text;
        else if ([view isKindOfClass:UIButton.class]) visibleText = ((UIButton *)view).currentTitle;
        if (visibleText.length) textToken = [UUIVHashString(visibleText) substringToIndex:12];
        BOOL secure = [view isKindOfClass:UITextField.class] && ((UITextField *)view).secureTextEntry;
        if (!secure && view.accessibilityValue.length) accessibilityToken = [UUIVHashString(view.accessibilityValue) substringToIndex:12];
        if ([view isKindOfClass:UIScrollView.class]) { CGPoint offset=((UIScrollView *)view).contentOffset; controlState=[NSString stringWithFormat:@"scroll:%.1f:%.1f",offset.x,offset.y]; }
        else if ([view isKindOfClass:UISwitch.class]) controlState=[NSString stringWithFormat:@"switch:%d",((UISwitch *)view).on];
        else if ([view isKindOfClass:UISlider.class]) controlState=[NSString stringWithFormat:@"slider:%.3f",((UISlider *)view).value];
        else if ([view isKindOfClass:UISegmentedControl.class]) controlState=[NSString stringWithFormat:@"segment:%ld",(long)((UISegmentedControl *)view).selectedSegmentIndex];
        else if ([view isKindOfClass:UIPageControl.class]) controlState=[NSString stringWithFormat:@"page:%ld",(long)((UIPageControl *)view).currentPage];
    } @catch (__unused NSException *e) { }
    CGRect frame = view.frame;
    [out appendFormat:@"|%@:%@:%lu:%@:%@:%@:frame:%.0f,%.0f,%.0f,%.0f", className, identifier, (unsigned long)visibleChildren, textToken, accessibilityToken, controlState, frame.origin.x, frame.origin.y, frame.size.width, frame.size.height];
    NSUInteger childCount = 0;
    for (UIView *child in view.subviews) {
        if (++childCount > 20 || !*budget) break;
        UUIVAppendViewFingerprint(child, depth + 1, budget, out);
    }
}

@interface UUIVisitedScreenRecorder ()
@property(nonatomic, readwrite, getter=isRecording) BOOL recording;
@property(nonatomic, readwrite) NSUInteger screenCount;
@property(nonatomic, readwrite) NSUInteger captureCount;
@property(nonatomic, copy, readwrite) NSString *lastError;
@property(nonatomic, strong) NSURL *sessionDirectory;
@property(nonatomic, strong) NSURL *screensDirectory;
@property(nonatomic, copy) NSString *sessionID;
@property(nonatomic, copy) NSDictionary *buildMetadata;
@property(nonatomic, weak) UIWindowScene *scene;
@property(nonatomic, weak) UIWindow *inspectorWindow;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, strong) NSMutableArray<NSMutableDictionary *> *screenRecords;
@property(nonatomic, copy) NSString *pendingFingerprint;
@property(nonatomic) NSUInteger pendingStableSamples;
@property(nonatomic, copy) NSString *lastObservedFingerprint;
@property(nonatomic, copy) NSString *lastRouteFingerprint;
@property(nonatomic) NSTimeInterval captureDeadline;
@property(nonatomic) BOOL interrupted;
@property(nonatomic) BOOL limitReached;
@end

@implementation UUIVisitedScreenRecorder

- (instancetype)initWithSessionDirectory:(NSURL *)sessionDirectory sessionID:(NSString *)sessionID buildMetadata:(NSDictionary *)buildMetadata {
    if ((self = [super init])) {
        _sessionDirectory = sessionDirectory;
        _screensDirectory = [sessionDirectory URLByAppendingPathComponent:@"01_SCREENS" isDirectory:YES];
        _sessionID = [sessionID copy] ?: @"";
        _buildMetadata = [buildMetadata copy] ?: @{};
        _screenRecords = [NSMutableArray array];
        [[NSFileManager defaultManager] createDirectoryAtURL:_screensDirectory withIntermediateDirectories:YES attributes:nil error:nil];
        [self recoverIndex];
    }
    return self;
}

- (void)recoverIndex {
    NSURL *indexURL = [self.screensDirectory URLByAppendingPathComponent:@"SCREEN_INDEX.json"];
    NSData *data = [NSData dataWithContentsOfURL:indexURL];
    NSDictionary *index = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSArray *screens = [index[@"screens"] isKindOfClass:NSArray.class] ? index[@"screens"] : nil;
    for (NSDictionary *record in screens) if ([record isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *mutableRecord = [record mutableCopy]; NSMutableArray *mutableStates = [NSMutableArray array];
        for (NSDictionary *state in [record[@"states"] isKindOfClass:NSArray.class] ? record[@"states"] : @[]) if ([state isKindOfClass:NSDictionary.class]) [mutableStates addObject:[state mutableCopy]];
        mutableRecord[@"states"] = mutableStates; [self.screenRecords addObject:mutableRecord];
    }
    self.screenCount = self.screenRecords.count;
    self.limitReached = [index[@"limit_reached"] boolValue];
    for (NSDictionary *record in self.screenRecords) self.captureCount += [record[@"states"] isKindOfClass:NSArray.class] ? [record[@"states"] count] : 0;
    if (self.screenRecords.count) self.interrupted = YES;
    for (NSMutableDictionary *screen in self.screenRecords) {
        for (NSMutableDictionary *state in screen[@"states"]) if ([state[@"status"] isEqualToString:@"WRITING"]) { state[@"status"] = @"PARTIAL"; state[@"recovery_note"] = @"Interrupted while writing; preserved and eligible for a retry state."; screen[@"status"] = @"PARTIAL"; }
    }
    [self writeIndex];
}

- (void)startWithScene:(UIWindowScene *)scene inspectorWindow:(UIWindow *)inspectorWindow {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self startWithScene:scene inspectorWindow:inspectorWindow]; }); return; }
    self.scene = scene;
    self.inspectorWindow = inspectorWindow;
    self.recording = YES;
    self.lastError = @"";
    [self.timer invalidate];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(observeTick) userInfo:nil repeats:YES];
    [self observeTick];
}

- (void)stop {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self stop]; }); return; }
    self.recording = NO;
    [self.timer invalidate];
    self.timer = nil;
    self.pendingFingerprint = nil;
    self.pendingStableSamples = 0;
    [self writeIndex];
}

- (NSDictionary *)fingerprintForScene:(UIWindowScene *)scene windows:(NSArray<UIWindow *> *)windows {
    UIViewController *visible = UUIVVisibleController(windows.firstObject.rootViewController);
    NSMutableArray<NSString *> *routeParts = [NSMutableArray array];
    UUIVAppendControllerRoute(windows.firstObject.rootViewController, routeParts, 0, [NSMutableSet set]);
    if (!routeParts.count && visible) [routeParts addObject:NSStringFromClass(visible.class) ?: @"UIViewController"];
    NSString *route = [routeParts componentsJoinedByString:@"/"];
    NSMutableString *structure = [NSMutableString stringWithFormat:@"scene:%@;windows:%lu;route:%@", scene.session.persistentIdentifier ?: @"scene", (unsigned long)windows.count, route];
    NSUInteger budget = 96;
    for (UIWindow *window in windows) {
        [structure appendFormat:@"|window:%@:%@", NSStringFromClass(window.class) ?: @"UIWindow", NSStringFromCGRect(window.bounds)];
        UUIVAppendViewFingerprint(window, 0, &budget, structure);
    }
    NSString *routeHash = [UUIVHashString(route) substringToIndex:12];
    NSString *stateHash = [UUIVHashString(structure) substringToIndex:16];
    return @{ @"route": route, @"routeFingerprint": routeHash, @"stateFingerprint": stateHash, @"signature": structure, @"visibleController": visible ? NSStringFromClass(visible.class) : @"NOT_AVAILABLE" };
}

- (void)observeTick {
    if (!self.recording || UIApplication.sharedApplication.applicationState != UIApplicationStateActive || self.scene.activationState != UISceneActivationStateForegroundActive) return;
    NSArray<UIWindow *> *windows = UUIVContentWindows(self.scene, self.inspectorWindow);
    if (!windows.count || !windows.firstObject.rootViewController) return;
    UIViewController *presented = windows.firstObject.rootViewController;
    for (NSUInteger guard=0; presented.presentedViewController && guard<12; guard++) presented = presented.presentedViewController;
    NSString *presentedClass = presented ? NSStringFromClass(presented.class) : @"";
    NSString *presentedTitle = presented.title ?: @"";
    if (UUIVContains(presentedClass,@"FLEX") || UUIVContains(presentedClass,@"UIActivityViewController") || UUIVContains(presentedClass,@"DocumentPicker") || [presentedTitle isEqualToString:@"Universal UI Inspector"] || [presentedTitle isEqualToString:@"ANALYZE AND EXPORT"] || [presentedTitle isEqualToString:@"Capture Status / Log"] || [presentedTitle isEqualToString:@"Stability Diagnostic"]) return;
    NSDictionary *fp = [self fingerprintForScene:self.scene windows:windows];
    NSString *value = [NSString stringWithFormat:@"%@:%@", fp[@"routeFingerprint"], fp[@"stateFingerprint"]];
    if ([value isEqualToString:self.lastObservedFingerprint]) return;
    if (![value isEqualToString:self.pendingFingerprint]) {
        self.pendingFingerprint = value;
        self.pendingStableSamples = 1;
        return;
    }
    self.pendingStableSamples++;
    if (self.pendingStableSamples < 3) return;
    if (![value isEqualToString:self.lastObservedFingerprint]) {
        NSError *error = nil;
        if ([self writeCaptureForScene:self.scene windows:windows fingerprint:fp trigger:@"automatic_stable_transition" forceVariant:NO error:&error]) {
            self.lastObservedFingerprint = value;
            self.lastRouteFingerprint = fp[@"routeFingerprint"];
            self.lastError = @"";
        } else if (error) {
            self.lastError = error.localizedDescription ?: @"automatic capture failed";
            if (self.limitReached) { self.lastObservedFingerprint = value; self.recording = NO; [self.timer invalidate]; self.timer = nil; [self writeIndex]; }
        }
    }
}

- (BOOL)captureManualWithScene:(UIWindowScene *)scene inspectorWindow:(UIWindow *)inspectorWindow error:(NSError **)error {
    if (!NSThread.isMainThread) {
        if (error) *error = [NSError errorWithDomain:@"UUIVisitedScreenRecorder" code:1 userInfo:@{NSLocalizedDescriptionKey:@"UIKit capture must run on the main thread"}];
        return NO;
    }
    NSArray<UIWindow *> *windows = UUIVContentWindows(scene, inspectorWindow);
    if (!windows.count || !windows.firstObject.rootViewController) {
        if (error) *error = [NSError errorWithDomain:@"UUIVisitedScreenRecorder" code:2 userInfo:@{NSLocalizedDescriptionKey:@"No eligible foreground app window was found"}];
        return NO;
    }
    UIViewController *presented = windows.firstObject.rootViewController; for (NSUInteger guard=0; presented.presentedViewController && guard<12; guard++) presented = presented.presentedViewController;
    NSString *presentedClass = NSStringFromClass(presented.class) ?: @"";
    if (UUIVContains(presentedClass,@"FLEX") || UUIVContains(presentedClass,@"UIActivityViewController") || UUIVContains(presentedClass,@"DocumentPicker")) { if (error) *error = [NSError errorWithDomain:@"UUIVisitedScreenRecorder" code:6 userInfo:@{NSLocalizedDescriptionKey:@"Manual capture deferred while FLEX or system share/document UI is presented"}]; return NO; }
    NSDictionary *fp = [self fingerprintForScene:scene windows:windows];
    BOOL ok = [self writeCaptureForScene:scene windows:windows fingerprint:fp trigger:@"manual" forceVariant:YES error:error];
    if (ok) {
        NSString *value = [NSString stringWithFormat:@"%@:%@", fp[@"routeFingerprint"], fp[@"stateFingerprint"]];
        self.lastObservedFingerprint = value;
        self.pendingFingerprint = value;
        self.pendingStableSamples = 3;
    }
    return ok;
}

- (NSString *)safeDisplayLabel:(NSString *)controllerClass sequence:(NSUInteger)sequence {
    NSString *source = controllerClass.length && ![controllerClass isEqualToString:@"NOT_AVAILABLE"] ? controllerClass : [NSString stringWithFormat:@"Screen_%04lu", (unsigned long)sequence];
    NSMutableString *clean = [NSMutableString string];
    for (NSUInteger i = 0; i < source.length && clean.length < 32; i++) {
        unichar c = [source characterAtIndex:i];
        if ([[NSCharacterSet alphanumericCharacterSet] characterIsMember:c] || c == '_' || c == '-') [clean appendFormat:@"%C", c];
        else if (clean.length && ![clean hasSuffix:@"_"]) [clean appendString:@"_"];
    }
    while ([clean hasSuffix:@"_"]) [clean deleteCharactersInRange:NSMakeRange(clean.length - 1, 1)];
    return clean.length ? clean : [NSString stringWithFormat:@"Screen_%04lu", (unsigned long)sequence];
}

- (NSMutableDictionary *)controllerTreeFor:(UIViewController *)controller parent:(NSString *)parent depth:(NSUInteger)depth nodes:(NSUInteger *)nodes seen:(NSMutableSet<NSValue *> *)seen viewOwners:(NSMutableDictionary<NSValue *, NSString *> *)viewOwners flat:(NSMutableArray *)flat truncated:(BOOL *)truncated {
    if (!controller) return nil;
    if (CACurrentMediaTime() > self.captureDeadline || depth > 64 || *nodes >= 1000) { *truncated = YES; return nil; }
    NSValue *ptr = [NSValue valueWithNonretainedObject:controller];
    if ([seen containsObject:ptr]) return nil;
    [seen addObject:ptr]; (*nodes)++;
    NSString *nodeID = [NSString stringWithFormat:@"C%06lu", (unsigned long)*nodes];
    NSString *className = NSStringFromClass(controller.class) ?: @"UIViewController";
    Class controllerSuperclass = class_getSuperclass(controller.class);
    NSMutableDictionary *record = [@{ @"node_id": nodeID, @"parent_id": parent ?: NSNull.null, @"child_order": @(*nodes - 1), @"depth": @(depth), @"class": className, @"superclass": controllerSuperclass ? NSStringFromClass(controllerSuperclass) : @"NOT_AVAILABLE", @"view_loaded": @(controller.isViewLoaded), @"children": [NSMutableArray array] } mutableCopy];
    if (controller.isViewLoaded && controller.view) viewOwners[[NSValue valueWithNonretainedObject:controller.view]] = nodeID;
    @try {
        if ([controller isKindOfClass:UINavigationController.class]) record[@"navigation_stack"] = [[(UINavigationController *)controller viewControllers] valueForKeyPath:@"class.description"] ?: @[];
        if ([controller isKindOfClass:UITabBarController.class]) record[@"selected_tab"] = ((UITabBarController *)controller).selectedViewController ? NSStringFromClass(((UITabBarController *)controller).selectedViewController.class) : @"NOT_AVAILABLE";
        if ([controller isKindOfClass:UISplitViewController.class]) record[@"split_controllers"] = [[(UISplitViewController *)controller viewControllers] valueForKeyPath:@"class.description"] ?: @[];
        if (controller.presentedViewController) record[@"presented_class"] = NSStringFromClass(controller.presentedViewController.class) ?: @"NOT_AVAILABLE";
    } @catch (__unused NSException *e) { record[@"relationship_error"] = @YES; }
    [flat addObject:record];
    NSMutableArray *children = record[@"children"];
    NSArray *childControllers = @[];
    @try { childControllers = controller.childViewControllers ?: @[]; } @catch (__unused NSException *e) { *truncated = YES; }
    for (UIViewController *child in childControllers) {
        NSMutableDictionary *row = [self controllerTreeFor:child parent:nodeID depth:depth + 1 nodes:nodes seen:seen viewOwners:viewOwners flat:flat truncated:truncated];
        if (row) { row[@"child_order"] = @(children.count); [children addObject:row]; }
    }
    if (controller.presentedViewController) {
        NSMutableDictionary *row = [self controllerTreeFor:controller.presentedViewController parent:nodeID depth:depth + 1 nodes:nodes seen:seen viewOwners:viewOwners flat:flat truncated:truncated];
        if (row) { row[@"child_order"] = @(children.count); [children addObject:row]; }
    }
    return record;
}

- (NSString *)nearestControllerForView:(UIView *)view owners:(NSDictionary<NSValue *, NSString *> *)owners {
    UIView *cursor = view;
    NSUInteger guard = 0;
    while (cursor && guard++ < 128) {
        NSString *owner = owners[[NSValue valueWithNonretainedObject:cursor]];
        if (owner) return owner;
        cursor = cursor.superview;
    }
    return @"NOT_AVAILABLE";
}

- (void)appendView:(UIView *)view parent:(NSString *)parent childOrder:(NSUInteger)childOrder depth:(NSUInteger)depth nodes:(NSUInteger *)nodes maxNodes:(NSUInteger)maxNodes records:(NSMutableArray *)records visible:(NSMutableArray *)visible text:(NSMutableString *)text owners:(NSDictionary<NSValue *, NSString *> *)owners truncated:(BOOL *)truncated excluded:(NSUInteger *)excluded {
    if (!view) return;
    if (CACurrentMediaTime() > self.captureDeadline || depth > 64 || *nodes >= maxNodes) { *truncated = YES; return; }
    NSString *className = NSStringFromClass(view.class) ?: @"UIView";
    if (UUIVContains(className, @"FLEX")) { (*excluded)++; return; }
    (*nodes)++;
    NSString *nodeID = [NSString stringWithFormat:@"V%06lu", (unsigned long)*nodes];
    CGRect frame = CGRectZero, bounds = CGRectZero;
    CGPoint center = CGPointZero;
    CGAffineTransform transform = CGAffineTransformIdentity;
    NSString *identifier = @"NOT_AVAILABLE", *label = @"NOT_AVAILABLE", *value = @"NOT_AVAILABLE", *textValue = @"NOT_AVAILABLE";
    BOOL hidden = YES, interaction = NO, opaque = NO, clips = NO, accessibilityElement = NO;
    CGFloat alpha = 0;
    NSUInteger childCount = 0;
    @try {
        frame = view.frame; bounds = view.bounds; center = view.center; transform = view.transform;
        hidden = view.hidden; alpha = view.alpha; interaction = view.userInteractionEnabled; opaque = view.opaque; clips = view.clipsToBounds; childCount = view.subviews.count; accessibilityElement = view.isAccessibilityElement;
        identifier = UUIVSafe(view.accessibilityIdentifier, 256); label = UUIVSafe(view.accessibilityLabel, 256);
        BOOL secure = [view isKindOfClass:UITextField.class] && ((UITextField *)view).secureTextEntry;
        if (!secure) value = UUIVSafe(view.accessibilityValue, 256);
        if ([view isKindOfClass:UILabel.class]) textValue = UUIVSafe(((UILabel *)view).text, 256);
        else if ([view isKindOfClass:UIButton.class]) textValue = UUIVSafe(((UIButton *)view).currentTitle, 256);
        if (secure) { value = @"REDACTED_SECURE_INPUT"; textValue = @"REDACTED_SECURE_INPUT"; }
    } @catch (__unused NSException *e) { *truncated = YES; }
    Class viewSuperclass = class_getSuperclass(view.class);
    NSMutableDictionary *record = [@{ @"node_id": nodeID, @"parent_id": parent ?: NSNull.null, @"child_order": @(childOrder), @"depth": @(depth), @"class": className, @"superclass": viewSuperclass ? NSStringFromClass(viewSuperclass) : @"NOT_AVAILABLE", @"image_or_framework_path": UUIVSafe([NSBundle bundleForClass:view.class].bundleIdentifier, 256), @"frame": UUIVRect(frame), @"bounds": UUIVRect(bounds), @"center": UUIVPoint(center), @"transform": @{ @"a": @(transform.a), @"b": @(transform.b), @"c": @(transform.c), @"d": @(transform.d), @"tx": @(transform.tx), @"ty": @(transform.ty) }, @"alpha": @(alpha), @"hidden": @(hidden), @"opaque": @(opaque), @"clips_to_bounds": @(clips), @"user_interaction_enabled": @(interaction), @"accessibility_element": @(accessibilityElement), @"accessibility_identifier": identifier, @"accessibility_label": label, @"accessibility_value": value, @"text": textValue, @"subview_count": @(childCount), @"owning_view_controller_node_id": [self nearestControllerForView:view owners:owners], @"address": [NSString stringWithFormat:@"%p", view], @"address_scope": @"transient_process_only" } mutableCopy];
    @try {
        UIColor *color = view.backgroundColor;
        if (color) {
            CGFloat r=0,g=0,b=0,a=0,white=0;
            if ([color getRed:&r green:&g blue:&b alpha:&a]) record[@"background_color_rgba"] = @{ @"r":@(r), @"g":@(g), @"b":@(b), @"a":@(a) };
            else if ([color getWhite:&white alpha:&a]) record[@"background_color_gray"] = @{ @"white":@(white), @"alpha":@(a) };
        }
        CALayer *layer = view.layer;
        if (layer) record[@"layer"] = @{ @"class": NSStringFromClass(layer.class) ?: @"CALayer", @"frame": UUIVRect(layer.frame), @"bounds": UUIVRect(layer.bounds), @"opacity": @(layer.opacity), @"hidden": @(layer.hidden), @"corner_radius": @(layer.cornerRadius), @"masks_to_bounds": @(layer.masksToBounds), @"z_position": @(layer.zPosition) };
        if ([view isKindOfClass:UIScrollView.class]) { UIScrollView *scroll=(UIScrollView *)view; record[@"scroll"] = @{ @"content_offset": UUIVPoint(scroll.contentOffset), @"content_size": @{ @"width": @(scroll.contentSize.width), @"height": @(scroll.contentSize.height) }, @"zoom_scale": @(scroll.zoomScale) }; }
        if ([view isKindOfClass:UIImageView.class] && ((UIImageView *)view).image) { UIImage *image=((UIImageView *)view).image; record[@"image_metadata"] = @{ @"width_points": @(image.size.width), @"height_points": @(image.size.height), @"scale": @(image.scale), @"rendering_mode": @(image.renderingMode) }; }
    } @catch (__unused NSException *e) { record[@"optional_metadata_error"] = @YES; }
    [records addObject:record];
    if (accessibilityElement || interaction || ![label isEqualToString:@"NOT_AVAILABLE"] || ![textValue isEqualToString:@"NOT_AVAILABLE"]) [visible addObject:@{ @"node_id":nodeID, @"class":className, @"frame":record[@"frame"], @"accessibility_identifier":identifier, @"accessibility_label":label, @"accessibility_value":value, @"text":textValue, @"coordinate_space":@"window_local_points" }];
    [text appendFormat:@"%@%@ %@ frame=%@ label=%@ text=%@\n", [@"  " stringByPaddingToLength:MIN(depth * 2, 128) withString:@" " startingAtIndex:0], nodeID, className, NSStringFromCGRect(frame), label, textValue];
    NSArray<UIView *> *children = @[];
    @try { children = [view.subviews copy] ?: @[]; } @catch (__unused NSException *e) { *truncated = YES; }
    NSUInteger order = 0;
    for (UIView *child in children) {
        [self appendView:child parent:nodeID childOrder:order++ depth:depth+1 nodes:nodes maxNodes:maxNodes records:records visible:visible text:text owners:owners truncated:truncated excluded:excluded];
        if (*nodes >= maxNodes) break;
    }
}

- (BOOL)writeCaptureForScene:(UIWindowScene *)scene windows:(NSArray<UIWindow *> *)windows fingerprint:(NSDictionary *)fp trigger:(NSString *)trigger forceVariant:(BOOL)force error:(NSError **)error {
    if (!NSThread.isMainThread) return NO;
    @try {
        NSString *routeHash = fp[@"routeFingerprint"] ?: @"unknown";
        NSString *stateHash = fp[@"stateFingerprint"] ?: @"unknown";
        NSDate *now = [NSDate date];
        NSMutableDictionary *screen = nil;
        NSUInteger screenSequence = 0;
        for (NSUInteger i = 0; i < self.screenRecords.count; i++) {
            NSMutableDictionary *candidate = self.screenRecords[i];
            if ([candidate[@"route_fingerprint"] isEqualToString:routeHash]) { screen = candidate; screenSequence = i + 1; break; }
        }
        if (!screen) {
            if (self.screenRecords.count >= kUUIVMaxScreensPerSession) { self.limitReached = YES; self.lastError = @"screen limit reached"; if (error) *error = [NSError errorWithDomain:@"UUIVisitedScreenRecorder" code:4 userInfo:@{NSLocalizedDescriptionKey:@"Capture stopped at the 200-screen session limit"}]; [self writeIndex]; return NO; }
            screenSequence = self.screenRecords.count + 1;
            NSString *label = [self safeDisplayLabel:fp[@"visibleController"] sequence:screenSequence];
            NSString *screenID = [NSString stringWithFormat:@"SCREEN_%04lu_%@_%@", (unsigned long)screenSequence, label, [routeHash substringToIndex:MIN(8, routeHash.length)]];
            screen = [@{ @"screen_id": screenID, @"sequence": @(screenSequence), @"directory": screenID, @"display_label": label, @"route_fingerprint": routeHash, @"route_description": fp[@"route"] ?: @"NOT_AVAILABLE", @"first_seen": UUIVDate(now), @"last_seen": UUIVDate(now), @"visits": @0, @"states": [NSMutableArray array], @"status": @"DISCOVERED" } mutableCopy];
            [self.screenRecords addObject:screen];
            [NSFileManager.defaultManager createDirectoryAtURL:[self.screensDirectory URLByAppendingPathComponent:screenID isDirectory:YES] withIntermediateDirectories:YES attributes:nil error:nil];
        }
        screen[@"last_seen"] = UUIVDate(now);
        screen[@"visits"] = @([screen[@"visits"] unsignedIntegerValue] + 1);
        NSMutableArray *states = [screen[@"states"] isKindOfClass:NSMutableArray.class] ? screen[@"states"] : [screen[@"states"] mutableCopy];
        screen[@"states"] = states;
        NSMutableDictionary *state = nil;
        if (!force) for (NSMutableDictionary *candidate in states) if ([candidate[@"state_fingerprint"] isEqualToString:stateHash] && [candidate[@"status"] isEqualToString:@"CAPTURED"]) { state = candidate; break; }
        if (state && !force) {
            state[@"last_seen"] = UUIVDate(now);
            state[@"visits"] = @([state[@"visits"] unsignedIntegerValue] + 1);
            screen[@"status"] = @"CAPTURED";
            [self writeIndex];
            [self appendCaptureEvent:@{@"schema_version":@"uui-capture-event-1.0",@"timestamp":UUIVDate([NSDate date]),@"event":@"duplicate_visit_deduplicated",@"screen_id":screen[@"screen_id"],@"state_id":state[@"state_id"] ?: @"NOT_AVAILABLE",@"trigger":trigger}];
            return YES;
        }
        if (self.captureCount >= kUUIVMaxCapturesPerSession || states.count >= kUUIVMaxStatesPerScreen) { self.limitReached = YES; self.lastError = @"capture/state limit reached"; if (error) *error = [NSError errorWithDomain:@"UUIVisitedScreenRecorder" code:5 userInfo:@{NSLocalizedDescriptionKey:@"Capture stopped at the bounded per-session/per-screen state limit"}]; [self writeIndex]; return NO; }
        NSUInteger stateSequence = states.count + 1;
        NSString *stateID = [NSString stringWithFormat:@"STATE_%04lu_%@", (unsigned long)stateSequence, [stateHash substringToIndex:MIN(8, stateHash.length)]];
        NSString *relative = [NSString stringWithFormat:@"%@/%@", screen[@"directory"], stateID];
        NSURL *stateDir = [[self.screensDirectory URLByAppendingPathComponent:screen[@"directory"] isDirectory:YES] URLByAppendingPathComponent:stateID isDirectory:YES];
        NSError *mkdirError = nil;
        if (![NSFileManager.defaultManager createDirectoryAtURL:stateDir withIntermediateDirectories:YES attributes:nil error:&mkdirError]) { if (error) *error = mkdirError; return NO; }
        NSString *captureID = [NSUUID UUID].UUIDString;
        self.captureDeadline = CACurrentMediaTime() + 2.0;
        NSMutableDictionary *stateRecord = [@{ @"state_id": stateID, @"directory": relative, @"state_fingerprint": stateHash, @"first_seen": UUIVDate(now), @"last_seen": UUIVDate(now), @"capture_count": @1, @"visits": @1, @"status": @"WRITING", @"capture_id": captureID } mutableCopy];
        [states addObject:stateRecord];
        screen[@"status"] = @"WRITING";
        [self writeIndex];
        NSDictionary *pending = @{ @"schema_version": @"uui-capture-status-1.0", @"status": @"PARTIAL", @"reason": @"capture files are being written atomically", @"capture_id": captureID, @"started_at": UUIVDate(now) };
        [self writeObject:pending toURL:[stateDir URLByAppendingPathComponent:@"CAPTURE_STATUS.json"] error:nil];

        UIWindow *host = windows.firstObject;
        NSUInteger controllerNodes = 0;
        BOOL truncated = NO;
        NSMutableArray *controllerFlat = [NSMutableArray array];
        NSMutableDictionary *owners = [NSMutableDictionary dictionary];
        NSMutableSet *controllerSeen = [NSMutableSet set];
        NSMutableDictionary *controllerTree = [self controllerTreeFor:host.rootViewController parent:nil depth:0 nodes:&controllerNodes seen:controllerSeen viewOwners:owners flat:controllerFlat truncated:&truncated];
        NSMutableArray *viewRecords = [NSMutableArray array], *visible = [NSMutableArray array];
        NSMutableString *viewText = [NSMutableString stringWithString:@"UniversalUIInspector view tree; node IDs are stable within this snapshot only.\n"];
        NSUInteger viewNodes = 0, excludedViews = 0;
        for (NSUInteger i = 0; i < windows.count; i++) [self appendView:windows[i] parent:nil childOrder:i depth:0 nodes:&viewNodes maxNodes:12000 records:viewRecords visible:visible text:viewText owners:owners truncated:&truncated excluded:&excludedViews];
        NSMutableString *controllerText = [NSMutableString stringWithString:@"UniversalUIInspector controller tree; hierarchy and containment are preserved.\n"];
        for (NSDictionary *record in controllerFlat) [controllerText appendFormat:@"%@%@ %@\n", [@"  " stringByPaddingToLength:MIN([record[@"depth"] unsignedIntegerValue] * 2, 128) withString:@" " startingAtIndex:0], record[@"node_id"], record[@"class"]];
        NSString *snapshotID = captureID;
        NSDictionary *context = @{ @"schema_version": @"uui-context-1.0", @"snapshot_id":snapshotID, @"session_id":self.sessionID, @"scene_identifier":scene.session.persistentIdentifier ?: @"NOT_AVAILABLE", @"window_count":@(windows.count), @"windows":@[], @"captured_at":UUIVDate(now), @"trigger":trigger, @"controller_class":fp[@"visibleController"] ?: @"NOT_AVAILABLE" };
        NSMutableArray *windowRecords = [NSMutableArray array];
        for (NSUInteger i = 0; i < windows.count; i++) {
            UIWindow *window = windows[i];
            [windowRecords addObject:@{ @"window_id":[NSString stringWithFormat:@"W%03lu",(unsigned long)i+1], @"class":NSStringFromClass(window.class) ?: @"UIWindow", @"is_key_window":@(window.isKeyWindow), @"window_level":@(window.windowLevel), @"hidden":@(window.hidden), @"frame":UUIVRect(window.frame), @"bounds":UUIVRect(window.bounds), @"root_controller":window.rootViewController ? NSStringFromClass(window.rootViewController.class) : @"NOT_AVAILABLE", @"scene_identifier":scene.session.persistentIdentifier ?: @"NOT_AVAILABLE" }];
        }
        NSData *png = nil;
        NSString *screenshotError = nil;
        @try {
            CGSize size = host.bounds.size;
            if (excludedViews > 0) screenshotError = @"FLEX-owned subtrees were detected in the host window; screenshot suppressed to avoid presenting an overlay-contaminated image";
            else if (size.width > 0 && size.height > 0) {
                UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
                format.scale = host.screen.scale > 0 ? host.screen.scale : UIScreen.mainScreen.scale;
                UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
                UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) { BOOL drawn = [host drawViewHierarchyInRect:host.bounds afterScreenUpdates:YES]; if (!drawn) [host.layer renderInContext:ctx.CGContext]; }];
                png = UIImagePNGRepresentation(image);
            } else screenshotError = @"empty host window bounds";
        } @catch (NSException *exception) { screenshotError = exception.reason ?: @"screenshot renderer exception"; }
        NSDictionary *meta = @{ @"schema_version":@"uui-screen-metadata-1.0", @"capture_id":captureID, @"session_id":self.sessionID, @"screen_id":screen[@"screen_id"], @"state_id":stateID, @"route_fingerprint":routeHash, @"state_fingerprint":stateHash, @"captured_at":UUIVDate(now), @"trigger":trigger, @"capture_status":truncated ? @"PARTIAL" : (screenshotError ? @"PARTIAL" : @"CAPTURED"), @"duplicate_or_retry_reason":force ? @"manual capture explicitly preserves a new state variant" : @"stable fingerprint after three consecutive one-second observations", @"scene_identifier":scene.session.persistentIdentifier ?: @"NOT_AVAILABLE", @"window_count":@(windows.count), @"primary_window_class":NSStringFromClass(host.class) ?: @"UIWindow", @"controller_class":fp[@"visibleController"] ?: @"NOT_AVAILABLE", @"node_counts":@{@"views":@(viewNodes),@"controllers":@(controllerNodes),@"visible_elements":@(visible.count)}, @"truncated":@(truncated), @"excluded_flex_views":@(excludedViews), @"screenshot_dimensions_points":@{@"width":@(host.bounds.size.width),@"height":@(host.bounds.size.height)}, @"screenshot_dimensions_pixels":@{@"width":@(png ? (NSUInteger)(host.bounds.size.width * (host.screen.scale ?: 1)) : 0),@"height":@(png ? (NSUInteger)(host.bounds.size.height * (host.screen.scale ?: 1)) : 0)}, @"screenshot_error":screenshotError ?: @"", @"overlay_contamination":@(excludedViews > 0 || screenshotError != nil), @"screenshot_policy":@"Rendered primary eligible app window only; recorder and FLEX windows excluded", @"build":self.buildMetadata ?: @{}, @"app":@{@"bundle_identifier":NSBundle.mainBundle.bundleIdentifier ?: @"NOT_AVAILABLE",@"version":NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"NOT_AVAILABLE",@"build":NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"] ?: @"NOT_AVAILABLE"}, @"device":@{@"model":UIDevice.currentDevice.model ?: @"NOT_AVAILABLE",@"os_version":UIDevice.currentDevice.systemVersion ?: @"NOT_AVAILABLE"} };
        NSDictionary *viewObject = @{ @"schema_version":@"uui-view-tree-1.0", @"snapshot_id":snapshotID, @"captured_at":UUIVDate(now), @"coordinate_space":@"window_local_points", @"node_count":@(viewRecords.count), @"truncated":@(truncated), @"views":viewRecords };
        NSDictionary *controllerObject = @{ @"schema_version":@"uui-controller-tree-1.0", @"snapshot_id":snapshotID, @"captured_at":UUIVDate(now), @"node_count":@(controllerFlat.count), @"truncated":@(truncated), @"root":controllerTree ?: NSNull.null, @"controllers":controllerFlat };
        NSDictionary *windowsObject = @{ @"schema_version":@"uui-windows-1.0", @"snapshot_id":snapshotID, @"scene_identifier":scene.session.persistentIdentifier ?: @"NOT_AVAILABLE", @"eligible_window_count":@(windowRecords.count), @"excluded_window_classes":@[@"inspector overlay",@"FLEX windows",@"keyboard/text-effects windows",@"non-normal window levels"], @"windows":windowRecords };
        NSMutableDictionary *summary = [@{ @"schema_version":@"uui-screen-summary-1.0", @"screen_id":screen[@"screen_id"], @"state_id":stateID, @"controller_class":fp[@"visibleController"] ?: @"NOT_AVAILABLE", @"route_fingerprint":routeHash, @"state_fingerprint":stateHash, @"captured_at":UUIVDate(now), @"trigger":trigger, @"view_count":@(viewRecords.count), @"controller_count":@(controllerFlat.count), @"visible_element_count":@(visible.count), @"truncated":@(truncated), @"screenshot_status":png ? @"PASS" : @"MISSING", @"screenshot_error":screenshotError ?: @"", @"coverage_scope":@"Observed foreground screen only; unvisited app screens cannot be inferred" } mutableCopy];
        NSMutableDictionary *files = [NSMutableDictionary dictionary];
        NSData *viewJSON = [NSJSONSerialization dataWithJSONObject:viewObject options:NSJSONWritingPrettyPrinted error:nil];
        NSData *controllerJSON = [NSJSONSerialization dataWithJSONObject:controllerObject options:NSJSONWritingPrettyPrinted error:nil];
        NSData *windowsJSON = [NSJSONSerialization dataWithJSONObject:windowsObject options:NSJSONWritingPrettyPrinted error:nil];
        NSData *visibleJSON = [NSJSONSerialization dataWithJSONObject:@{ @"schema_version":@"uui-visible-elements-1.0",@"snapshot_id":snapshotID,@"coordinate_space":@"window_local_points",@"count":@(visible.count),@"elements":visible } options:NSJSONWritingPrettyPrinted error:nil];
        NSData *metadataJSON = [NSJSONSerialization dataWithJSONObject:meta options:NSJSONWritingPrettyPrinted error:nil];
        NSData *summaryJSON = [NSJSONSerialization dataWithJSONObject:summary options:NSJSONWritingPrettyPrinted error:nil];
        if (viewJSON) files[@"view_tree.json"] = viewJSON;
        if (controllerJSON) files[@"controller_tree.json"] = controllerJSON;
        if (windowsJSON) files[@"windows.json"] = windowsJSON;
        if (visibleJSON) files[@"visible_elements.json"] = visibleJSON;
        if (metadataJSON) files[@"metadata.json"] = metadataJSON;
        if (summaryJSON) files[@"screen_summary.json"] = summaryJSON;
        files[@"view_tree.txt"] = [viewText dataUsingEncoding:NSUTF8StringEncoding];
        files[@"controller_tree.txt"] = [controllerText dataUsingEncoding:NSUTF8StringEncoding];
        files[@"screen_summary.txt"] = [[NSString stringWithFormat:@"Screen: %@\nState: %@\nController: %@\nCaptured: %@\nTrigger: %@\nViews: %lu\nControllers: %lu\nVisible elements: %lu\nTruncated: %@\nScreenshot: %@\nCoverage: observed screen only; unvisited screens cannot be inferred.\n", screen[@"screen_id"], stateID, fp[@"visibleController"] ?: @"NOT_AVAILABLE", UUIVDate(now), trigger, (unsigned long)viewRecords.count, (unsigned long)controllerFlat.count, (unsigned long)visible.count, truncated ? @"YES" : @"NO", png ? @"PASS" : (screenshotError ?: @"NOT_AVAILABLE")] dataUsingEncoding:NSUTF8StringEncoding];
        if (png.length) files[@"screenshot.png"] = png;
        else files[@"screenshot_error.json"] = [NSJSONSerialization dataWithJSONObject:@{@"schema_version":@"uui-screenshot-error-1.0",@"error":screenshotError ?: @"screenshot unavailable",@"overlay_contamination":@(excludedViews > 0 || screenshotError != nil)} options:NSJSONWritingPrettyPrinted error:nil];
        NSError *writeError = nil;
        for (NSString *name in files) if (![files[name] writeToURL:[stateDir URLByAppendingPathComponent:name] options:NSDataWritingAtomic error:&writeError]) { if (error) *error = writeError; stateRecord[@"status"] = @"PARTIAL"; stateRecord[@"error"] = writeError.localizedDescription ?: @"atomic file write failed"; screen[@"status"] = @"PARTIAL"; [self writeIndex]; return NO; }
        NSDictionary *completeStatus = @{ @"schema_version":@"uui-capture-status-1.0", @"status":(truncated || !png) ? @"PARTIAL" : @"CAPTURED", @"capture_id":captureID, @"completed_at":UUIVDate([NSDate date]), @"file_count":@(files.count), @"reason":truncated ? @"bounded traversal limit reached" : (!png ? (screenshotError ?: @"screenshot missing") : @"") };
        if (![self writeObject:completeStatus toURL:[stateDir URLByAppendingPathComponent:@"CAPTURE_STATUS.json"] error:&writeError]) { if (error) *error = writeError; return NO; }
        stateRecord[@"last_seen"] = UUIVDate([NSDate date]);
        stateRecord[@"status"] = (truncated || !png) ? @"PARTIAL" : @"CAPTURED";
        stateRecord[@"file_count"] = @(files.count + 1);
        screen[@"status"] = (truncated || !png) ? @"PARTIAL" : @"CAPTURED";
        self.captureCount++;
        self.screenCount = self.screenRecords.count;
        [self writeIndex];
        self.lastError = @"";
        [self appendCaptureEvent:@{@"schema_version":@"uui-capture-event-1.0",@"timestamp":UUIVDate([NSDate date]),@"event":@"capture_saved",@"screen_id":screen[@"screen_id"],@"state_id":stateID,@"trigger":trigger,@"status":stateRecord[@"status"] ?: @"PARTIAL"}];
        return YES;
    } @catch (NSException *exception) {
        NSString *message = exception.reason ?: exception.name ?: @"capture exception";
        self.lastError = message;
        if (error) *error = [NSError errorWithDomain:@"UUIVisitedScreenRecorder" code:3 userInfo:@{NSLocalizedDescriptionKey:message}];
        return NO;
    }
}

- (BOOL)writeObject:(id)object toURL:(NSURL *)url error:(NSError **)error {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingPrettyPrinted error:error];
    return data && [data writeToURL:url options:NSDataWritingAtomic error:error];
}

- (void)appendCaptureEvent:(NSDictionary *)event {
    NSData *data = [NSJSONSerialization dataWithJSONObject:event options:0 error:nil]; if (!data) return; NSMutableData *line = [data mutableCopy]; [line appendBytes:"\n" length:1]; NSURL *url = [[self.sessionDirectory URLByAppendingPathComponent:@"07_LOGS" isDirectory:YES] URLByAppendingPathComponent:@"CAPTURE_EVENTS.jsonl"]; NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:url.path]; if (!handle) { [line writeToURL:url options:NSDataWritingAtomic error:nil]; return; } @try { [handle seekToEndOfFile]; [handle writeData:line]; } @catch (__unused NSException *e) { } [handle closeFile];
}

- (void)writeIndex {
    NSMutableArray *records = [NSMutableArray array];
    for (NSDictionary *screen in self.screenRecords) [records addObject:screen];
    NSDictionary *index = @{ @"schema_version":@"uui-screen-index-1.0", @"session_id":self.sessionID ?: @"", @"generated_at":UUIVDate([NSDate date]), @"recording":@(self.recording), @"screen_count":@(records.count), @"capture_count":@(self.captureCount), @"limit_reached":@(self.limitReached), @"limits":@{@"max_screens":@(kUUIVMaxScreensPerSession),@"max_captures":@(kUUIVMaxCapturesPerSession),@"max_states_per_screen":@(kUUIVMaxStatesPerScreen)}, @"coverage_scope":@"Observed screens only; unvisited screens cannot be inferred from a running UI", @"screens":records, @"build":self.buildMetadata ?: @{} };
    NSError *error = nil;
    if (![self writeObject:index toURL:[self.screensDirectory URLByAppendingPathComponent:@"SCREEN_INDEX.json"] error:&error]) self.lastError = error.localizedDescription ?: @"screen index write failed";
}

- (NSDictionary *)statusDictionary {
    return @{ @"recording":@(self.recording), @"screen_count":@(self.screenCount), @"capture_count":@(self.captureCount), @"last_error":self.lastError ?: @"", @"session_directory":self.sessionDirectory.path ?: @"NOT_AVAILABLE", @"pending_stability_samples":@(self.pendingStableSamples), @"recovered_previous_index":@(self.interrupted), @"limit_reached":@(self.limitReached) };
}

- (void)dealloc { [self.timer invalidate]; }
@end
