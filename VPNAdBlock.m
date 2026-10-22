/* VPNAdBlock v9 —— 全量诊断版
 *
 * v8 教训：dump 过滤了系统类 → 开屏页全是系统视图 → dump 空
 *          2秒时还在 SplashViewController → 没抓到首页
 * v7 教训：5次启动 20次清扫，零命中 → 类名确实匹配不上
 *
 * v9 关键修正：
 *   ① dump 不过滤任何类（包括 "_" 开头的 SwiftUI 视图）
 *   ② 加「类名普查」：收集视图树所有类名，最后整体输出
 *   ③ 多时间点：3/6/10秒 + viewDidAppear，确保抓到首页
 *   ④ 记录每个出现的 VC 名
 */
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreMotion/CoreMotion.h>
#import <CoreFoundation/CoreFoundation.h>

#define VPN_LEVEL 2
#define VPN_DEBUG 1
#define SHOW_BADGE 1
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

#pragma mark - 类名匹配（清扫用）

static NSString * const BANNER_KEYS[] = {
    @"HomeBannerCell", @"HomeBannerCarousel", @"HomeBanner",
    @"BannerCell", @"BannerCarousel", @"BannerView", nil
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
// 注意：这里只排除明确的 UIKit/Foundation 前缀，
// 不再排除 "_" 开头的 Swift 类型
static BOOL VPNIsKitClass(NSString *cls) {
    return ([cls hasPrefix:@"UI"] || [cls hasPrefix:@"CA"] || [cls hasPrefix:@"NS"] ||
            [cls hasPrefix:@"WK"] || [cls hasPrefix:@"SwiftUI"] || [cls hasPrefix:@"Swift."]);
}
static BOOL VPNIsBanner(UIView *v) {
    if (!v) return NO;
    NSString *cls = NSStringFromClass([v class]);
    if (VPNIsKitClass(cls)) return NO;
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

#pragma mark - 全量 dump + 类名普查

static int gDumpN;
static NSMutableSet *gCensus;

static void VPNDumpTree(UIView *root, int depth) {
    if (!root || depth > 10 || gDumpN > 400) return;
    NSMutableString *pad = [NSMutableString string];
    for (int i = 0; i < depth; i++) [pad appendString:@"  "];

    NSString *cls = NSStringFromClass([root class]);
    @synchronized (gCensus) { [gCensus addObject:cls]; }

    NSString *mark = VPNIsBanner(root) ? @"  <<<BANNER" : @"";
    NSString *hid = root.isHidden ? @" [hidden]" : @"";
    VPNLog([NSString stringWithFormat:@"%@%@%@%@%@", pad, cls,
            NSStringFromCGRect(root.frame), mark, hid]);
    gDumpN++;

    @try {
        for (UIView *sub in root.subviews) VPNDumpTree(sub, depth + 1);
    } @catch (NSException *e) {}
}

static void VPNDumpNow(NSString *tag) {
    @try {
        static dispatch_once_t once;
        dispatch_once(&once, ^{ gCensus = [[NSMutableSet alloc] init]; });

        gDumpN = 0;
        NSArray *wins = VPNWindows();
        VPNLog([NSString stringWithFormat:@"===== DUMP %@ windows=%lu =====", tag, (unsigned long)wins.count]);
        for (UIWindow *w in wins) {
            VPNLog([NSString stringWithFormat:@"[WIN] %@ level=%.1f root=%@ frame=%@",
                    NSStringFromClass([w class]), w.windowLevel,
                    NSStringFromClass([w.rootViewController class]),
                    NSStringFromCGRect(w.frame)]);
            VPNDumpTree(w, 1);
        }
        VPNLog(@"===== DUMP END =====");

        // 类名普查：把所有出现过的类名整体输出，不管多深
        NSArray *all = nil;
        @synchronized (gCensus) { all = [[gCensus allObjects] sortedArrayUsingSelector:@selector(compare:)]; }
        NSMutableString *buf = [NSMutableString string];
        [buf appendFormat:@"===== CENSUS %@ (%lu) =====\n", tag, (unsigned long)all.count];
        for (NSString *c in all) [buf appendFormat:@"  %@\n", c];
        [buf appendString:@"===== CENSUS END ====="];
        VPNLog(buf);
    } @catch (NSException *e) { VPNLog(@"dump err"); }
}

#pragma mark - 角标（加到已有 window）

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
            if (!w) return;
            UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(8, 70, 130, 32)];
            lb.text = @"VPN-OK";
            lb.textColor = [UIColor blackColor];
            lb.backgroundColor = [[UIColor greenColor] colorWithAlphaComponent:0.95];
            lb.font = [UIFont boldSystemFontOfSize:15];
            lb.textAlignment = NSTextAlignmentCenter;
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
    if (!root || depth > 10) return;
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

#pragma mark - viewDidAppear：抓每个页面

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
            VPNLogOnce([@"vc|" stringByAppendingString:vcName],
                       [NSString stringWithFormat:@"VCApp: %@", vcName]);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                VPNDumpNow(vcName);
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
    VPNLog(@"========== VPNAdBlock v9 loaded, LEVEL=2 ==========");

    dispatch_async(dispatch_get_main_queue(), ^{
        VPNHookSensors();
        VPNHookViewController();
    });

#if SHOW_BADGE
    // 角标重试（不引用数组，避免 block 捕获 C 数组报错）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ VPNShowBadge(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ VPNShowBadge(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ VPNShowBadge(); });
#endif

    // 三个时间点，确保覆盖首页（开屏页可能持续数秒）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        VPNDumpNow(@"t3s");
        VPNSweepAll();
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        VPNDumpNow(@"t6s");
        VPNSweepAll();
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        VPNDumpNow(@"t10s");
        VPNSweepAll();
    });
}
