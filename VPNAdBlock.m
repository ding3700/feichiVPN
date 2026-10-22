/* VPNAdBlock v10 —— 飞驰 VPN（XunchiVPN）去广告插件 · 最终版
 *
 * 实测确认的类名：
 *   首页顶部/底部 banner = ...18HomeBannerCarousel   ✅ 已验证（顶 y=61 / 底 y=770）
 *   推荐面板（点连接 / 签到后从下弹出）
 *             = ...34RecommendationsSheetViewController  ★ v10 新增
 *   绝不处理：RewardCelebrationView / FloatingClaimButton（正常功能）
 *
 * 策略：
 *   banner   —— 视图树匹配后 hidden（不移除，防 Auto Layout 崩）
 *   推荐面板 —— viewDidAppear 完成 0.6s 后隐藏其 view
 *               （不 dismiss、不拦截 present，避免 Swift 强解包崩溃）
 *
 * 日志：Documents/vpn_adblock.log
 */
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreMotion/CoreMotion.h>
#import <CoreFoundation/CoreFoundation.h>

#pragma mark - ============ 开关 ============

//  2 = 只清首页 banner
//  3 = + 推荐面板拦截  ★ 推荐用这个
#define VPN_LEVEL 3

#define VPN_DEBUG 1
static const NSTimeInterval kSensorBlockSeconds = 10.0;

#pragma mark - 日志

static NSString *VPNPath(NSString *k) {
    if ([k isEqualToString:@"doc"])
        return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"vpn_adblock.log"];
    return [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"vpn_adblock.log"];
}
static CFAbsoluteTime gStart = 0;

static void VPNLog(NSString *line) {
#if VPN_DEBUG
    static NSDateFormatter *fmt;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ fmt = [[NSDateFormatter alloc] init]; fmt.dateFormat = @"HH:mm:ss.SSS"; });
    NSString *out = [NSString stringWithFormat:@"[%@] %@\n", [fmt stringFromDate:[NSDate date]], line];
    NSLog(@"[VPNAdBlock] %@", line);
    NSString *p = VPNPath(@"doc");
    if ([[NSFileManager defaultManager] fileExistsAtPath:p]) {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:[out dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
            return;
        }
    }
    [out writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
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

#pragma mark - 类名（已实测锁定）

// 首页 banner
static NSString * const BANNER_KEYS[] = {
    @"HomeBannerCarousel",
    @"HomeBannerCell",
    nil
};
// 推荐面板（真凶）
static NSString * const SHEET_KEYS[] = {
    @"RecommendationsSheet",
    nil
};
// 绝不碰：正常功能（签到领奖、浮动领会员按钮）
static NSString * const SAFE_KEYS[] = {
    @"RewardCelebration", @"FloatingClaim", @"Claim", @"Reward",
    @"Sign", @"CheckIn", @"Member", @"Vip", nil
};
static NSString * const EXCLUDE[] = {
    @"Address", @"Adapter", @"Adaptor", @"Advanced", @"Advisory",
    @"Add", @"Read", @"Load", @"Shadow", @"Gradient", @"Badge", @"Header", @"Trade", nil
};

static BOOL VPNHit(NSString *cls, NSString *const keys[]) {
    if (cls.length == 0) return NO;
    for (int i = 0; keys[i]; i++) {
        if ([cls rangeOfString:keys[i]].length > 0) return YES;
    }
    return NO;
}
static BOOL VPNIsKitClass(NSString *cls) {
    return ([cls hasPrefix:@"UI"] || [cls hasPrefix:@"CA"] || [cls hasPrefix:@"NS"] ||
            [cls hasPrefix:@"WK"] || [cls hasPrefix:@"SwiftUI"] || [cls hasPrefix:@"Swift."]);
}
static BOOL VPNIsSafe(NSString *cls) { return VPNHit(cls, SAFE_KEYS); }

static BOOL VPNIsBanner(UIView *v) {
    if (!v) return NO;
    NSString *cls = NSStringFromClass([v class]);
    if (VPNIsKitClass(cls) || VPNIsSafe(cls) || VPNHit(cls, EXCLUDE)) return NO;
    return VPNHit(cls, BANNER_KEYS);
}
static BOOL VPNIsSheetVC(NSString *cls) {
    if (cls.length == 0) return NO;
    if (VPNIsSafe(cls)) return NO;
    return VPNHit(cls, SHEET_KEYS);
}

#pragma mark - 隐藏（只 hidden，不移除、不改 frame）

static void VPNHideView(UIView *v, NSString *reason) {
    if (!v || v.isHidden) return;
    VPNLog([NSString stringWithFormat:@"HIDE[%@]: %@", reason, NSStringFromClass([v class])]);
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
                for (UIWindow *w in ((UIWindowScene *)s).windows) {
                    if (w) [out addObject:w];
                }
            }
        }
    } @catch (NSException *e) {}
    if (out.count == 0) {
        @try {
            UIWindow *w = [UIApplication sharedApplication].keyWindow;
            if (w) [out addObject:w];
        } @catch (NSException *e) {}
    }
    return out;
}

#pragma mark - banner 清扫

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

#pragma mark - 推荐面板拦截

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

#if VPN_LEVEL >= 3
            // 推荐面板：等展示动画完成后再隐藏 view
            // 不 dismiss、不拦 present —— 那会触发 Swift 生命周期强解包崩溃
            if (VPNIsSheetVC(vcName)) {
                VPNLogOnce([@"sheet|" stringByAppendingString:vcName],
                           [NSString stringWithFormat:@"SHEET detected: %@", vcName]);
                __weak UIViewController *weakVC = (UIViewController *)self;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    UIViewController *vc = weakVC;
                    if (!vc) return;
                    UIView *v = vc.view;
                    if (!v || v.isHidden) return;
                    VPNLog([NSString stringWithFormat:@"HIDE[sheet]: %@", vcName]);
                    v.hidden = YES;
                    v.alpha = 0.0;
                    v.userInteractionEnabled = NO;
                });
            }
#endif
            // 每个页面出现后补扫一次 banner（覆盖懒加载轮播）
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ VPNSweepAll(); });
        } @catch (NSException *e) {}
    }));
    VPNLog(@"hooked viewDidAppear");
}

#pragma mark - 传感器（摇一摇）

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
    VPNLog([NSString stringWithFormat:@"========== VPNAdBlock v10 loaded, LEVEL=%d ==========", VPN_LEVEL]);

    dispatch_async(dispatch_get_main_queue(), ^{
        VPNHookSensors();
        VPNHookViewController();
    });

    // banner 清扫：多次补扫，覆盖懒加载轮播
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ VPNSweepAll(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ VPNSweepAll(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(7.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ VPNSweepAll(); });

#if VPN_LEVEL >= 3
    // 推荐面板兜底：定时扫描顶级 VC，防 viewDidAppear 漏掉
    for (int i = 0; i < 20; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((3.0 + i * 3.0) * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try {
                for (UIWindow *w in VPNWindows()) {
                    if (w.windowLevel >= UIWindowLevelAlert) continue;
                    UIViewController *root = w.rootViewController;
                    if (!root) continue;
                    UIViewController *top = root;
                    int guard = 0;
                    while (top.presentedViewController && guard++ < 8) {
                        top = top.presentedViewController;
                    }
                    NSString *tn = NSStringFromClass([top class]);
                    if (VPNIsSheetVC(tn) && top.view && !top.view.isHidden) {
                        VPNLogOnce([@"fb|" stringByAppendingString:tn],
                                   [NSString stringWithFormat:@"HIDE[sheet-fallback]: %@", tn]);
                        top.view.hidden = YES;
                        top.view.alpha = 0.0;
                        top.view.userInteractionEnabled = NO;
                    }
                }
            } @catch (NSException *e) {}
        });
    }
#endif
}
