/* VPNAdBlock v12 —— 零闪现 + 自动关闭
 *
 * v11 已解决：banner 零闪现、推荐面板全程透明
 * v11 遗留：透明面板的「系统遮罩容器」仍在拦截点击，需多点一次
 *
 * v12 新增：隐藏 view 后主动 dismiss
 *   注意区分两种操作：
 *     拦截 present  —— present 从未发生，Swift 强解包 presentedViewController 会崩
 *     present 后 dismiss —— 等价于用户手动关闭，Swift 自己就在等这个动作，安全
 *
 *   现在 sheet 已走完 willAppear→didAppear 全流程，dismiss 属于正常生命周期操作。
 *   用 animated:NO 避免关闭动画期间访问已释放的转场上下文。
 */
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreMotion/CoreMotion.h>
#import <CoreFoundation/CoreFoundation.h>

#pragma mark - ============ 开关 ============

//  2 = 只清 banner
//  3 = banner + 推荐面板  ★
#define VPN_LEVEL 3

// 即时隐藏（零闪现核心）
#define INSTANT_HIDE 1

// 隐藏后自动 dismiss（消除多余点击）
// 若发现关闭瞬间闪退，改 0 退回「只隐藏」
#define DISMISS_SHEET 1

#define VPN_DEBUG 1
static const NSTimeInterval kSensorBlockSeconds = 10.0;

#pragma mark - 日志

static NSString *VPNPath(void) {
    return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
            stringByAppendingPathComponent:@"vpn_adblock.log"];
}
static CFAbsoluteTime gStart = 0;

static void VPNLog(NSString *line) {
#if VPN_DEBUG
    static NSDateFormatter *fmt;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ fmt = [[NSDateFormatter alloc] init]; fmt.dateFormat = @"HH:mm:ss.SSS"; });
    NSString *out = [NSString stringWithFormat:@"[%@] %@\n", [fmt stringFromDate:[NSDate date]], line];
    NSLog(@"[VPNAdBlock] %@", line);
    NSString *p = VPNPath();
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
    if ([gLogged containsObject:key]) return;
    [gLogged addObject:key];
    VPNLog(line);
}

#pragma mark - 类名（实测锁定）

static NSString * const BANNER_KEYS[] = { @"HomeBannerCarousel", @"HomeBannerCell", nil };
static NSString * const SHEET_KEYS[]  = { @"RecommendationsSheet", nil };
static NSString * const SAFE_KEYS[]   = {
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
static BOOL VPNIsBannerName(NSString *cls) {
    if (cls.length == 0) return NO;
    if (VPNIsKitClass(cls)) return NO;
    if (VPNHit(cls, SAFE_KEYS)) return NO;
    if (VPNHit(cls, EXCLUDE)) return NO;
    return VPNHit(cls, BANNER_KEYS);
}
static BOOL VPNIsSheetVC(NSString *cls) {
    if (cls.length == 0) return NO;
    if (VPNHit(cls, SAFE_KEYS)) return NO;
    return VPNHit(cls, SHEET_KEYS);
}

#pragma mark - 类名缓存

static NSMutableDictionary *gClsCache;
static BOOL VPNIsBannerCached(NSString *cls) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gClsCache = [[NSMutableDictionary alloc] init]; });
    NSNumber *c = [gClsCache objectForKey:cls];
    if (c) return [c boolValue];
    BOOL r = VPNIsBannerName(cls);
    [gClsCache setObject:[NSNumber numberWithBool:r] forKey:cls];
    return r;
}

#pragma mark - 隐藏

static void VPNHideView(UIView *v, NSString *reason) {
    if (!v || v.isHidden) return;
    VPNLog([NSString stringWithFormat:@"HIDE[%@]: %@", reason, NSStringFromClass([v class])]);
    v.hidden = YES;
    v.alpha = 0.0;
    v.userInteractionEnabled = NO;
}

#pragma mark - window

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

#pragma mark - 兜底清扫

static void VPNSweep(UIView *root, int depth) {
    if (!root || depth > 10) return;
    @try {
        for (UIView *v in root.subviews) {
            if (VPNIsBannerCached(NSStringFromClass([v class]))) { VPNHideView(v, @"sweep"); }
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

#pragma mark - ① 零闪现：didAddSubview 即时隐藏

static void VPNHookAddSubview(void) {
    Class V = [UIView class];
    if (!V) return;
    Method m = class_getInstanceMethod(V, @selector(didAddSubview:));
    if (!m) return;
    IMP o = method_getImplementation(m);
    method_setImplementation(m, imp_implementationWithBlock(^void(UIView *self, UIView *sub) {
        if (o) ((void (*)(id, SEL, UIView *))o)(self, @selector(didAddSubview:), sub);
#if INSTANT_HIDE
        @try {
            if (!sub) return;
            NSString *cls = NSStringFromClass([sub class]);
            if (VPNIsBannerCached(cls)) {
                sub.hidden = YES;
                sub.alpha = 0.0;
                sub.userInteractionEnabled = NO;
                VPNLogOnce([@"inst|" stringByAppendingString:cls],
                           [NSString stringWithFormat:@"HIDE[instant]: %@", cls]);
            }
        } @catch (NSException *e) {}
#endif
    }));
    VPNLog(@"hooked UIView didAddSubview:");
}

#pragma mark - ② 推荐面板：willAppear 透明 → didAppear 隐藏 → dismiss

static void VPNHookViewWillAppear(void) {
    Class VC = objc_getClass("UIViewController");
    if (!VC) return;
    Method m = class_getInstanceMethod(VC, @selector(viewWillAppear:));
    if (!m) return;
    IMP o = method_getImplementation(m);
    method_setImplementation(m, imp_implementationWithBlock(^void(id self, BOOL animated) {
#if VPN_LEVEL >= 3
        @try {
            NSString *vcName = NSStringFromClass([self class]);
            if (VPNIsSheetVC(vcName)) {
                UIView *v = ((UIViewController *)self).view;
                if (v) v.alpha = 0.0;   // 动画开始前就透明，全程不可见
                VPNLogOnce([@"wa|" stringByAppendingString:vcName],
                           [NSString stringWithFormat:@"SHEET pre-alpha0: %@", vcName]);
            }
        } @catch (NSException *e) {}
#endif
        if (o) ((void (*)(id, SEL, BOOL))o)(self, @selector(viewWillAppear:), animated);
    }));
}

static void VPNHookViewDidAppear(void) {
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
            if (VPNIsSheetVC(vcName)) {
                __weak UIViewController *weakVC = (UIViewController *)self;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    UIViewController *vc = weakVC;
                    if (!vc) return;
                    UIView *v = vc.view;
                    if (v && !v.isHidden) {
                        VPNLog([NSString stringWithFormat:@"HIDE[sheet]: %@", vcName]);
                        v.hidden = YES;
                        v.alpha = 0.0;
                        v.userInteractionEnabled = NO;
                    }

#if DISMISS_SHEET
                    // 再延迟一拍，确保转场上下文完全稳定后再关闭
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        @try {
                            UIViewController *cur = weakVC;
                            if (!cur) return;
                            // 只有仍处于被 present 状态才关闭
                            if (cur.presentingViewController || cur.navigationController) {
                                VPNLog([NSString stringWithFormat:@"SHEET dismiss: %@", vcName]);
                                [cur dismissViewControllerAnimated:NO completion:nil];
                            } else {
                                VPNLog(@"SHEET skip dismiss: no presenting VC");
                            }
                        } @catch (NSException *e) {
                            VPNLog(@"dismiss exception (ignored)");
                        }
                    });
#endif
                });
            }
#endif
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ VPNSweepAll(); });
        } @catch (NSException *e) {}
    }));
    VPNLog(@"hooked UIViewController viewDidAppear:");
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
    VPNLog([NSString stringWithFormat:@"========== VPNAdBlock v12 loaded, LEVEL=%d ==========", VPN_LEVEL]);

    dispatch_async(dispatch_get_main_queue(), ^{
        VPNHookSensors();
        VPNHookAddSubview();
        VPNHookViewWillAppear();
        VPNHookViewDidAppear();
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ VPNSweepAll(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ VPNSweepAll(); });

#if VPN_LEVEL >= 3
    for (int i = 0; i < 20; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((3.0 + i * 3.0) * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try {
                for (UIWindow *w in VPNWindows()) {
                    if (w.windowLevel >= UIWindowLevelAlert) continue;
                    UIViewController *top = w.rootViewController;
                    if (!top) continue;
                    int guard = 0;
                    while (top.presentedViewController && guard++ < 8) {
                        top = top.presentedViewController;
                    }
                    NSString *tn = NSStringFromClass([top class]);
                    if (VPNIsSheetVC(tn)) {
                        if (top.view && !top.view.isHidden) {
                            VPNLogOnce([@"fb|" stringByAppendingString:tn],
                                       [NSString stringWithFormat:@"HIDE[sheet-fb]: %@", tn]);
                            top.view.hidden = YES;
                            top.view.alpha = 0.0;
                            top.view.userInteractionEnabled = NO;
                        }
#if DISMISS_SHEET
                        if (top.presentingViewController) {
                            VPNLogOnce([@"fbd|" stringByAppendingString:tn],
                                       [NSString stringWithFormat:@"SHEET dismiss-fb: %@", tn]);
                            [top dismissViewControllerAnimated:NO completion:nil];
                        }
#endif
                    }
                }
            } @catch (NSException *e) {}
        });
    }
#endif
}
