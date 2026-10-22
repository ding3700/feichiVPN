/* VPNAdBlock v7 —— 飞驰 VPN（XunchiVPN）
 *
 * 实测情报：
 *   首页顶部/底部 banner = HomeBannerCell / HomeBannerCarousel
 *   「推荐」面板（点免费领会员 / 开始连接 后弹出）= 弹窗类
 *   「今日已领取」对话框 = 正常功能，不是广告，不碰
 *
 * v7 关键修正：
 *   ① 删除 presentViewController 拦截 —— 阻塞展示会导致 Swift 强解包崩溃
 *   ② 只做「展示完成后隐藏」，绝不阻塞
 *   ③ banner 与弹窗分级，可分别测试
 */
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreMotion/CoreMotion.h>
#import <CoreFoundation/CoreFoundation.h>

//  0 = 空壳，零 hook
//  1 = 只拦摇一摇
//  2 = + 只隐藏首页 banner（完全不碰弹窗）★ 先用这个
//  3 = + 弹窗延迟隐藏（展示完成后才藏）
//  4 = + 位置识别兜底
//  5 = 屏幕 dump
#define VPN_LEVEL 2

#define VPN_DEBUG 1
#define SHOW_BADGE 1        // 绿色角标，确认插件加载；确认后改 0
#define BANNER_BY_POSITION 1
static const NSTimeInterval kSensorBlockSeconds = 10.0;

#pragma mark - 日志（同步写三处）

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

// 首页 banner（图20）
static NSString * const BANNER_KEYS[] = {
    @"HomeBannerCell",
    @"HomeBannerCarousel",
    nil
};
// 弹窗（图22 推荐面板）—— 仅 LEVEL>=3 才处理
static NSString * const POPUP_KEYS[] = {
    @"AnnouncementPopupView",
    @"Recommend",
    nil
};
// 通用语义兜底，仅 LEVEL>=4
static NSString * const SEMANTIC_KEYS[] = {
    @"Banner", @"AdView", @"Advert", @"Promot", @"Sponsor", nil
};
static NSString * const EXCLUDE[] = {
    @"Address", @"Adapter", @"Adaptor", @"Advanced", @"Advisory",
    @"Add", @"Read", @"Load", @"Shadow", @"Gradient", @"Badge", @"Header", @"Trade", nil
};
// 绝不处理：正常功能弹窗（图21 今日已领取）
static NSString * const SAFE[] = {
    @"Claim", @"Reward", @"Sign", @"CheckIn", @"Member", @"Vip", @"Toast", @"Alert", nil
};

static BOOL VPNHit(NSString *cls, NSString *const keys[]) {
    if (cls.length == 0) return NO;
    for (int i = 0; keys[i]; i++) {
        if ([cls rangeOfString:keys[i]].length > 0) return YES;
    }
    return NO;
}
static BOOL VPNIsSystem(NSString *cls) {
    return ([cls hasPrefix:@"UI"] || [cls hasPrefix:@"CA"] || [cls hasPrefix:@"NS"] ||
            [cls hasPrefix:@"WK"] || [cls hasPrefix:@"_"] || [cls hasPrefix:@"SwiftUI"]);
}
static BOOL VPNIsSafe(NSString *cls) {
    return VPNHit(cls, SAFE);
}

static BOOL VPNIsBanner(UIView *v) {
    if (!v) return NO;
    NSString *cls = NSStringFromClass([v class]);
    if (VPNIsSystem(cls) || VPNIsSafe(cls)) return NO;
    for (int i = 0; EXCLUDE[i]; i++) if ([cls rangeOfString:EXCLUDE[i]].length > 0) return NO;
    if (VPNHit(cls, BANNER_KEYS)) return YES;
#if VPN_LEVEL >= 4
    if (VPNHit(cls, SEMANTIC_KEYS)) return YES;
#endif
    return NO;
}

static BOOL VPNIsPopup(UIView *v) {
#if VPN_LEVEL < 3
    return NO;
#else
    if (!v) return NO;
    NSString *cls = NSStringFromClass([v class]);
    if (VPNIsSystem(cls) || VPNIsSafe(cls)) return NO;
    for (int i = 0; EXCLUDE[i]; i++) if ([cls rangeOfString:EXCLUDE[i]].length > 0) return NO;
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
    BOOL atTop = (f.origin.y <= 140.0);
    BOOL atBottom = ((f.origin.y + f.size.height) >= sh - 140.0);
    return (atTop || atBottom);
#endif
}

#pragma mark - 清扫（只隐藏，不移除、不改 frame）

static void VPNHideView(UIView *v, NSString *reason) {
    if (!v || v.isHidden) return;
    VPNLogOnce([@"h|" stringByAppendingString:NSStringFromClass([v class])],
               [NSString stringWithFormat:@"hide[%@]: %@", reason, NSStringFromClass([v class])]);
    v.hidden = YES;
    v.alpha = 0.0;
    v.userInteractionEnabled = NO;
}

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

// includePopup=NO 时只清 banner（安全模式）
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

// 只扫 App 主窗口，跳过系统 Alert / 浮层
static void VPNSweepSafe(void) {
    for (UIWindow *w in VPNWindows()) {
        if (![w isKindOfClass:[UIWindow class]]) continue;
        if (w.windowLevel > UIWindowLevelNormal + 1.0) continue;
        VPNSweepWith(w, 0, NO);   // 安全模式：只清 banner
    }
}

// 弹窗清扫：只在展示完成后调用
static void VPNSweepPopup(void) {
#if VPN_LEVEL >= 3
    for (UIWindow *w in VPNWindows()) {
        if (![w isKindOfClass:[UIWindow class]]) continue;
        if ([w.rootViewController isKindOfClass:[UIAlertController class]]) continue;
        VPNSweepWith(w, 0, YES);
    }
#endif
}

#pragma mark - 绿色角标（确认插件加载）

#if SHOW_BADGE
static void VPNShowBadge(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *w = [[UIWindow alloc] initWithFrame:CGRectMake(6, 60, 96, 26)];
        w.windowLevel = UIWindowLevelStatusBar + 100;
        w.backgroundColor = [[UIColor greenColor] colorWithAlphaComponent:0.85];
        w.userInteractionEnabled = NO;   // 不挡触摸
        UILabel *lb = [[UILabel alloc] initWithFrame:w.bounds];
        lb.text = @"VPN✓";
        lb.textColor = [UIColor blackColor];
        lb.font = [UIFont boldSystemFontOfSize:13];
        lb.textAlignment = NSTextAlignmentCenter;
        UIViewController *vc = [UIViewController new];
        vc.view.backgroundColor = [UIColor clearColor];
        [vc.view addSubview:lb];
        w.rootViewController = vc;
        w.hidden = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            w.hidden = YES;
            w.rootViewController = nil;
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
    VPNLog([NSString stringWithFormat:@"========== VPNAdBlock v7 loaded, LEVEL=%d ==========", VPN_LEVEL]);
    VPNLog([NSString stringWithFormat:@"日志文件: %@", VPNPath(@"doc")]);

#if VPN_LEVEL == 0
    VPNLog(@"LEVEL 0: 零 hook。若仍闪退 = 注入本身问题。");
#if SHOW_BADGE
    VPNShowBadge();
#endif
    return;
#endif

    dispatch_async(dispatch_get_main_queue(), ^{
        VPNHookSensors();
#if SHOW_BADGE
        VPNShowBadge();
#endif
    });

    // 首页 banner：展示完成后清扫，安全
    NSTimeInterval safeDelays[] = {1.0, 2.5, 5.0, 9.0};
    for (int i = 0; i < 4; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(safeDelays[i] * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ VPNSweepSafe(); });
    }

#if VPN_LEVEL >= 3
    // 弹窗：只在展示完成后（延迟 2s）才隐藏，绝不阻塞 present
    // 之后每 2 秒复查一次，持续 60 秒，覆盖随时弹出的推荐面板
    __block int round = 0;
    __block void (^recheck)(void) = ^{
        if (round++ > 30) { return; }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            VPNSweepPopup();
        });
    };
    for (int i = 0; i < 30; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((2.0 + i * 2.0) * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ VPNSweepPopup(); });
    }
#endif
}
