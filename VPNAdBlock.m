/* VPNAdBlock v9 —— 修正诊断时机与角标方式
 * v8 教训：2秒时App还在开屏页，且dump过滤了所有系统类 → 什么都看不到
 * v9：角标改用「加到已有window」；dump改到4s/8s+viewDidAppear；不过滤系统类
 */
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreMotion/CoreMotion.h>
#import <CoreFoundation/CoreFoundation.h>

#define VPN_LEVEL 2
#define VPN_DEBUG 1
#define SHOW_BADGE 1
#define DUMP_ALL  1
#define BANNER_BY_POSITION 0
static const NSTimeInterval kSensorBlockSeconds = 10.0;

#pragma mark - 日志

static NSString *VPNPath(NSString *k) {
    if ([k isEqualToString:@"doc"])
        return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"vpn_adblock.log"];
    if ([k isEqualToString:@"cache"])
        return [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"vpn_adblock.log"];
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"vpn_adblock.log"];
}
static CFAbsoluteTime gStart = 0;

static void VPNLog(NSString *line) {
#if VPN_DEBUG
    static NSDateFormatter *fmt;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ fmt = [[NSDateFormatter alloc] init]; fmt.dateFormat = @"HH:mm:ss.SSS"; });
    NSString *out = [NSString stringWithFormat:@"[%@] %@\n", [fmt stringFromDate:[NSDate date]], line];
    NSLog(@"[VPNAdBlock] %@", line);
    for (NSString *k in @[@"doc", @"cache", @"tmp"]) {
        NSString *p = VPNPath(k);
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:p]) [@"" writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
        if (!fh) continue;
        [fh seekToEndOfFile];
        [fh writeData:[out dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
#endif
}
static NSMutableSet *gLogged;
static void VPNLogOnce(NSString *key, NSString *line) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gLogged = [[NSMutableSet alloc] init]; });
    @synchronized (gLogged) {
        if ([gLogged containsObject:key]) return;
        [gLogged addObject:key];
    }
    VPNLog(line);
}

#pragma mark - 类名

static NSString * const BANNER_KEYS[] = {
    @"HomeBannerCell", @"HomeBannerCarousel", @"HomeBanner", @"BannerCell", @"BannerCarousel", nil
};
static NSString * const EXCLUDE[] = {
    @"Address", @"Adapter", @"Adaptor", @"Advanced", @"Advisory",
    @"Add", @"Read", @"Load", @"Shadow", @"Gradient", @"Badge", @"Header", @"Trade", nil
};
static BOOL VPNHit(NSString *cls, NSString *const keys[]) {
    if (cls.length == 0) return NO;
    for (int i = 0; keys[i]; i++) if ([cls rangeOfString:keys[i]].length > 0) return YES;
    return NO;
}
static BOOL VPNIsSystem(NSString *cls) {
    return ([cls hasPrefix:@"UI"] || [cls hasPrefix:@"CA"] || [cls hasPrefix:@"NS"] ||
            [cls hasPrefix:@"WK"] || [cls hasPrefix:@"_"] || [cls hasPrefix:@"SwiftUI"] ||
            [cls hasPrefix:@"Swift."]);
}
static BOOL VPNIsBanner(UIView *v) {
    if (!v) return NO;
    NSString *cls = NSStringFromClass([v class]);
    if (VPNIsSystem(cls)) return NO;
    if (VPNHit(cls, EXCLUDE)) return NO;
    return VPNHit(cls, BANNER_KEYS);
}

#pragma mark - 隐藏

static void VPNHideView(UIView *v, NSString *reason) {
    if (!v || v.isHidden) return;
    VPNLog([NSString stringWithFormat:@"HIDE[%@]: %@ frame=%@", reason,
            NSStringFromClass([v class]), NSStringFromCGRect(v.frame)]);
    v.hidden = YES;
    v.alpha = 0.0;
    v.userInteractionEnabled = NO;
}

#pragma mark - window 列表

static NSArray *VPNWindows(void) {
    NSMutableArray *out = [NSMutableArray array];
    @try {
        if (@available(iOS 13.0, *)) {
            for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
                if (![s isKindOfClass:[UIWindowScene class]]) continue;
                for (UIWindow *w in ((UIWindowScene *)s).windows) if (w) [out addObject:w];
            }
        }
    } @catch (NSException *e) { VPNLog(@"win err"); }
    if (out.count == 0) {
        @try { UIWindow *w = [UIApplication sharedApplication].keyWindow; if (w) [out addObject:w]; } @catch (NSException *e) {}
    }
    return out;
}

#pragma mark - dump（不过滤系统类）

#if DUMP_ALL
static int gDumpN;
static void VPNDumpTree(UIView *root, int depth) {
    if (!root || depth > 9 || gDumpN > 250) return;
    NSMutableString *pad = [NSMutableString string];
    for (int i = 0; i < depth; i++) [pad appendString:@"  "];
    NSString *mark = VPNIsBanner(root) ? @"  <<<BANNER" : @"";
    VPNLog([NSString stringWithFormat:@"%@%@%@%@", pad,
            NSStringFromClass([root class]),
            NSStringFromCGRect(root.frame), mark]);
    gDumpN++;
    @try {
        for (UIView *sub in root.subviews) VPNDumpTree(sub, depth + 1);
    } @catch (NSException *e) {}
}
static void VPNDumpNow(NSString *tag) {
    @try {
        gDumpN = 0;
        NSArray *wins = VPNWindows();
        VPNLog([NSString stringWithFormat:@"===== DUMP %@ windows=%lu =====", tag, (unsigned long)wins.count]);
        for (UIWindow *w in wins) {
            VPNLog([NSString stringWithFormat:@"[WIN] %@ level=%.1f root=%@",
                    NSStringFromClass([w class]), w.windowLevel,
                    NSStringFromClass([w.rootViewController class])]);
            VPNDumpTree(w, 1);
        }
        VPNLog(@"===== DUMP END =====");
    } @catch (NSException *e) { VPNLog(@"dump err"); }
}
#endif

#pragma mark - 角标：加到已有 window（iOS13+ 新建 window 不显示）

#if SHOW_BADGE
static NSMutableArray *gBadgeLabels;
static void VPNShowBadge(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (!gBadgeLabels) gBadgeLabels = [NSMutableArray array];
            if (gBadgeLabels.count > 0) return;
            UIWindow *w = nil;
            @try { w = [UIApplication sharedApplication].keyWindow; } @catch (NSException *e) {}
            if (!w) w = VPNWindows().firstObject;
            if (!w) return;   // 稍后由重试逻辑再试
            UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(8, 70, 130, 32)];
            lb.text = @"VPN✓OK";
            lb.textColor = [UIColor blackColor];
            lb.backgroundColor = [[UIColor greenColor] colorWithAlphaComponent:0.95];
            lb.font = [UIFont boldSystemFontOfSize:15];
            lb.textAlignment = NSTextAlignmentCenter;
            lb.layer.cornerRadius = 6;
            lb.layer.masksToBounds = YES;
            lb.userInteractionEnabled = NO;
            [w addSubview:lb];
            [w bringSubviewToFront:lb];
            [gBadgeLabels addObject:lb];
            VPNLog([NSString stringWithFormat:@"BADGE added to %@", NSStringFromClass([w class])]);
        } @catch (NSException *e) { VPNLog(@"badge err"); }
    });
}
#endif

#pragma mark - 清扫

static void VPNSweep(UIView *root, int depth) {
    if (!root || depth > 9) return;
    @try {
        for (UIView *v in root.subviews) {
            if (VPNIsBanner(v)) { VPNHideView(v, @"banner"); }
            else { VPNSweep(v, depth + 1); }
        }
    } @catch (NSException *e) {}
}
static void VPNSweepAll(void) {
    for (UIWindow *w in VPNWindows()) {
        if (w.windowLevel >= UIWindowLevelAlert) continue;
        if ([w.rootViewController isKindOfClass:[UIAlertController class]]) continue;
        VPNSweep(w, 0);
    }
}

#pragma mark - viewDidAppear：确保抓到首页

static void VPNHookViewController(void) {
    Class VC = objc_getClass("UIViewController");
    if (!VC) return;
    Method m = class_getInstanceMethod(VC, @selector(viewDidAppear:));
    if (!m) return;
    IMP o = method_getImplementation(m);
    method_setImplementation(m, imp_implementationWithBlock(^void(id self, BOOL animated) {
        if (o) ((void (*)(id, SEL, BOOL))o)(self, @selector(viewDidAppear:), animated);
        @try {
            NSString *vcName = NSStringFromClass([self class]);
            VPNLog([NSString stringWithFormat:@"VCApp: %@", vcName]);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
#if DUMP_ALL
                VPNDumpNow(vcName);
#endif
                VPNSweepAll();
#if SHOW_BADGE
                VPNShowBadge();
#endif
            });
        } @catch (NSException *e) {}
    }));
    VPNLog(@"hooked viewDidAppear");
}

#pragma mark - 传感器

static BOOL VPNInSensorWindow(void) {
    if (gStart == 0) return YES;
    return ((CFAbsoluteTimeGetCurrent() - gStart) < kSensorBlockSeconds);
}
static void VPNHookSensors(void) {
    Class CMM = objc_getClass("CMMotionManager");
    if (!CMM) return;
    Method m1 = class_getInstanceMethod(CMM, @selector(startAccelerometerUpdatesToQueue:withHandler:));
    if (m1) {
        IMP o = method_getImplementation(m1);
        method_setImplementation(m1, imp_implementationWithBlock(^void(id self, NSOperationQueue *q, void (^h)(CMAccelerometerData *, NSError *)) {
            if (VPNInSensorWindow()) { VPNLogOnce(@"acc", @"shake blocked"); return; }
            if (o) ((void (*)(id, SEL, NSOperationQueue *, void (^)(CMAccelerometerData *, NSError *)))o)(self, @selector(startAccelerometerUpdatesToQueue:withHandler:), q, h);
        }));
    }
}

#pragma mark - 入口

__attribute__((constructor))
static void VPNEntry(void) {
    gStart = CFAbsoluteTimeGetCurrent();
    VPNLog([NSString stringWithFormat:@"========== VPNAdBlock v9 loaded, LEVEL=%d ==========", VPN_LEVEL]);

    dispatch_async(dispatch_get_main_queue(), ^{
        VPNHookSensors();
        VPNHookViewController();
    });

    // 角标：早期 window 可能还没建好，多次重试
#if SHOW_BADGE
    for (int i = 0; i < 6; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((1.0 + i * 1.5) * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ VPNShowBadge(); });
    }
#endif

    // dump + 清扫：4s / 8s（此时已进首页）
    NSTimeInterval ds[] = {4.0, 8.0};
    for (int i = 0; i < 2; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ds[i] * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
#if DUMP_ALL
            VPNDumpNow([NSString stringWithFormat:@"t%.0fs", ds[i]]);
#endif
            VPNSweepAll();
        });
    }
}
