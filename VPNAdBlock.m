/* VPNAdBlock v8 —— 诊断版
 * v7 修复了闪退（删 present 拦截），但清扫没命中。
 * v8 加诊断输出：window 情况 + 真实类名，一次看清真相。
 * 同时修复角标强引用 bug。
 */
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreMotion/CoreMotion.h>
#import <CoreFoundation/CoreFoundation.h>

//  0 = 空壳
//  1 = 摇一摇
//  2 = banner + 诊断输出 ★ 默认
//  3 = + 弹窗
//  4 = + 位置识别
#define VPN_LEVEL 2

#define VPN_DEBUG 1
#define SHOW_BADGE 1
#define DUMP_VIEWS 1     // 输出视图树到日志 ★ 关键
#define BANNER_BY_POSITION 0   // 先关掉，避免误伤干扰诊断
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
static NSString * const POPUP_KEYS[] = {
    @"AnnouncementPopupView", @"Recommend", @"Popup", nil
};
static NSString * const EXCLUDE[] = {
    @"Address", @"Adapter", @"Adaptor", @"Advanced", @"Advisory",
    @"Add", @"Read", @"Load", @"Shadow", @"Gradient", @"Badge", @"Header", @"Trade", nil
};
static NSString * const SAFE[] = {
    @"Claim", @"Reward", @"Sign", @"CheckIn", @"Member", @"Vip", @"Toast", nil
};

static BOOL VPNHit(NSString *cls, NSString *const keys[]) {
    if (cls.length == 0) return NO;
    for (int i = 0; keys[i]; i++) if ([cls rangeOfString:keys[i]].length > 0) return YES;
    return NO;
}
static BOOL VPNIsSystem(NSString *cls) {
    if ([cls hasPrefix:@"UI"] || [cls hasPrefix:@"CA"] || [cls hasPrefix:@"NS"] ||
        [cls hasPrefix:@"WK"] || [cls hasPrefix:@"_"] || [cls hasPrefix:@"SwiftUI"]) return YES;
    // Swift 内部类型
    if ([cls hasPrefix:@"Swift."] || [cls hasPrefix:@"__"]) return YES;
    return NO;
}
static BOOL VPNIsSafe(NSString *cls) { return VPNHit(cls, SAFE); }
static BOOL VPNIsExcluded(NSString *cls) { return VPNHit(cls, EXCLUDE); }

static BOOL VPNIsBanner(UIView *v) {
    if (!v) return NO;
    NSString *cls = NSStringFromClass([v class]);
    if (VPNIsSystem(cls) || VPNIsSafe(cls) || VPNIsExcluded(cls)) return NO;
    return VPNHit(cls, BANNER_KEYS);
}
static BOOL VPNIsPopup(UIView *v) {
#if VPN_LEVEL < 3
    return NO;
#else
    if (!v) return NO;
    NSString *cls = NSStringFromClass([v class]);
    if (VPNIsSystem(cls) || VPNIsSafe(cls) || VPNIsExcluded(cls)) return NO;
    return VPNHit(cls, POPUP_KEYS);
#endif
}

#pragma mark - 位置识别

static BOOL VPNLooksLikeDockBanner(UIView *v) {
#if !BANNER_BY_POSITION
    return NO;
#else
    if (!v || !v.window) return NO;
    if (v.isHidden || v.alpha < 0.05) return NO;
    NSString *cls = NSStringFromClass([v class]);
    if (VPNIsSystem(cls) || VPNIsSafe(cls)) return NO;
    CGRect f = [v convertRect:v.bounds toView:nil];
    if (f.size.width <= 0 || f.size.height <= 0) return NO;
    CGRect sb = [UIScreen mainScreen].bounds;
    CGFloat sw = MIN(sb.size.width, sb.size.height);
    CGFloat sh = MAX(sb.size.width, sb.size.height);
    if (f.size.width < sw * 0.85) return NO;
    if (!(f.size.height >= 40.0 && f.size.height <= 170.0)) return NO;
    return ((f.origin.y <= 140.0) || ((f.origin.y + f.size.height) >= sh - 140.0));
#endif
}

#pragma mark - 隐藏

static void VPNHideView(UIView *v, NSString *reason) {
    if (!v || v.isHidden) return;
    VPNLog([NSString stringWithFormat:@"HIDE[%@]: %@", reason, NSStringFromClass([v class])]);
    v.hidden = YES;
    v.alpha = 0.0;
    v.userInteractionEnabled = NO;
}

#pragma mark - 诊断 dump

#if DUMP_VIEWS
static int gDumpCount;
static void VPNDumpTree(UIView *root, int depth) {
    if (!root || depth > 7 || gDumpCount > 150) return;
    NSString *cls = NSStringFromClass([root class]);
    // 只记录非系统类，且数量受控
    if (!VPNIsSystem(cls)) {
        NSMutableString *pad = [NSMutableString string];
        for (int i = 0; i < depth; i++) [pad appendString:@"  "];
        NSString *mark = VPNIsBanner(root) ? @" <<<BANNER" : @"";
        VPNLog([NSString stringWithFormat:@"%@%@%@", pad, cls, mark]);
        gDumpCount++;
    }
    for (UIView *sub in root.subviews) VPNDumpTree(sub, depth + 1);
}
#endif

static NSArray *VPNWindows(void) {
    NSMutableArray *out = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if (![s isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)s).windows) if (w) [out addObject:w];
        }
    }
    if (out.count == 0) {
        UIWindow *w = [UIApplication sharedApplication].keyWindow;
        if (w) [out addObject:w];
    }
    return out;
}

// 放宽：只跳过 Alert 及以上（系统弹窗），不再用 +1.0
static BOOL VPNWindowScannable(UIWindow *w) {
    if (![w isKindOfClass:[UIWindow class]]) return NO;
    if (w.windowLevel >= UIWindowLevelAlert) return NO;
    if ([w.rootViewController isKindOfClass:[UIAlertController class]]) return NO;
    return YES;
}

static void VPNSweepWith(UIView *root, int depth, BOOL includePopup) {
    if (!root || depth > 8) return;
    for (UIView *v in root.subviews) {
        BOOL handled = NO;
        if (VPNIsBanner(v)) { VPNHideView(v, @"banner"); handled = YES; }
        else if (includePopup && VPNIsPopup(v)) { VPNHideView(v, @"popup"); handled = YES; }
        else if (VPN_LEVEL >= 4 && VPNLooksLikeDockBanner(v)) { VPNHideView(v, @"dock"); handled = YES; }
        if (!handled) VPNSweepWith(v, depth + 1, includePopup);
    }
}

static void VPNSweepSafe(void) {
    NSArray *wins = VPNWindows();
    for (UIWindow *w in wins) {
        if (!VPNWindowScannable(w)) {
            VPNLog([NSString stringWithFormat:@"SKIP window level=%.1f root=%@",
                    w.windowLevel, NSStringFromClass([w.rootViewController class])]);
            continue;
        }
        VPNSweepWith(w, 0, NO);
    }
}

#pragma mark - 角标（修复强引用）

#if SHOW_BADGE
static UIWindow *gBadgeWindow = nil;   // ★ static 强引用，防止被释放
static void VPNShowBadge(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gBadgeWindow) return;
        UIWindow *w = [[UIWindow alloc] initWithFrame:CGRectMake(6, 60, 100, 28)];
        w.windowLevel = UIWindowLevelStatusBar + 100;
        w.backgroundColor = [[UIColor greenColor] colorWithAlphaComponent:0.9];
        w.userInteractionEnabled = NO;
        UILabel *lb = [[UILabel alloc] initWithFrame:w.bounds];
        lb.text = @"VPN✓";
        lb.textColor = [UIColor blackColor];
        lb.font = [UIFont boldSystemFontOfSize:14];
        lb.textAlignment = NSTextAlignmentCenter;
        UIViewController *vc = [UIViewController new];
        vc.view.backgroundColor = [UIColor clearColor];
        [vc.view addSubview:lb];
        w.rootViewController = vc;
        gBadgeWindow = w;          // ★ 持有
        w.hidden = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            gBadgeWindow.hidden = YES;
            gBadgeWindow.rootViewController = nil;
            gBadgeWindow = nil;
        });
    });
}
#endif

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
    VPNLog([NSString stringWithFormat:@"========== VPNAdBlock v8 loaded, LEVEL=%d ==========", VPN_LEVEL]);

#if VPN_LEVEL == 0
#if SHOW_BADGE
    VPNShowBadge();
#endif
    VPNLog(@"LEVEL 0");
    return;
#endif

    dispatch_async(dispatch_get_main_queue(), ^{
        VPNHookSensors();
#if SHOW_BADGE
        VPNShowBadge();
#endif
    });

    // 诊断：2 秒时 dump 一次完整视图树
#if DUMP_VIEWS
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gDumpCount = 0;
        NSArray *wins = VPNWindows();
        VPNLog([NSString stringWithFormat:@"--- DUMP BEGIN windows=%lu ---", (unsigned long)wins.count]);
        for (UIWindow *w in wins) {
            VPNLog([NSString stringWithFormat:@"[WIN] %@ level=%.1f root=%@ frame=%@ scannable=%d",
                    NSStringFromClass([w class]), w.windowLevel,
                    NSStringFromClass([w.rootViewController class]),
                    NSStringFromCGRect(w.frame), VPNWindowScannable(w)]);
            VPNDumpTree(w, 1);
        }
        VPNLog(@"--- DUMP END ---");
    });
#endif

    // 清扫
    NSTimeInterval delays[] = {1.5, 3.0, 5.0, 9.0};
    for (int i = 0; i < 4; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[i] * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ VPNSweepSafe(); });
    }

#if VPN_LEVEL >= 3
    for (int i = 0; i < 30; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((2.0 + i * 2.0) * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            for (UIWindow *w in VPNWindows()) {
                if (VPNWindowScannable(w)) VPNSweepWith(w, 0, YES);
            }
        });
    }
#endif
}
