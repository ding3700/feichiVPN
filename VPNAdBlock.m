/* ===================================================================
 *  VPNAdBlock v3 —— 飞驰 VPN（XunchiVPN）广告净化插件
 *
 *  【实测情报】已拿到全部关键类名，不再需要猜测
 *
 *  Info.plist：
 *    Bundle ID  : com.feixun.vpn
 *    可执行文件 : XunchiVPN
 *    最低系统   : iOS 15.0
 *    构建环境   : Xcode 26.5 / iPhoneOS 26.5，Swift 项目
 *    解密来源   : DumpDecrypter（From DumpDecrypter = true）
 *
 *  静态分析报告（cryptid=0，无 Frameworks，广告全自研）：
 *    _TtC9XunchiVPN19SplashBrandMarkView                       开屏品牌标记
 *    _TtC9XunchiVPN20SplashViewController                      开屏页
 *    _TtC9XunchiVPNP33_...14HomeBannerCell                     首页 banner 单元
 *    _TtC9XunchiVPNP33_...18HomeBannerCarousel                 首页 banner 轮播
 *    _TtC9XunchiVPNP33_...21AnnouncementPopupView              公告弹窗 ★
 *
 *  【Swift 带来的两个约束】
 *    ① 方法不暴露给 ObjC runtime → 方法级 hook 基本无效，只能打视图层
 *    ② 运行时类名可能表现为 mangled（_TtC9XunchiVPN...）
 *       也可能表现为 demangled（XunchiVPN.HomeBannerCell
 *       或 XunchiVPN.(unknown context at $xxx).HomeBannerCell）
 *       → 必须用【子串匹配】才能同时覆盖两种形态
 *
 *  【v3 相对 v2 的性能优化】
 *    类名已精确已知，不再需要遍历全类做方法扫描（那是悦通行启动慢的主因）。
 *    这里只在【视图树遍历时】做字符串匹配，开销极小。
 *
 *  日志：Documents/vpn_adblock.log
 * =================================================================== */

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreMotion/CoreMotion.h>
#import <CoreFoundation/CoreFoundation.h>
#import <WebKit/WebKit.h>

#pragma mark - ============ 【可调开关】 ============

//   0 = 空壳，零 hook
//   1 = 只拦摇一摇
//   2 = + 弹窗拦截（present / 新 window）
//   3 = + 精确类名视图隐藏（banner + 弹窗）★ 主力
//   4 = + 位置识别兜底（治漏网的自研 banner）
//   5 = 透视 dump，零拦截
#define VPN_LEVEL 4

#define VPN_DEBUG 1

// 位置识别兜底开关（LEVEL>=4 时才生效）
// 若顶部/底部正常 UI 被误隐藏，改 0
#define BANNER_BY_POSITION 1

#define BANNER_MIN_W_RATIO   0.85
#define BANNER_MIN_H         40.0
#define BANNER_MAX_H         170.0
#define BANNER_EDGE_ZONE     140.0

static const NSTimeInterval kSensorBlockSeconds = 10.0;

#pragma mark - 异步日志

static NSMutableArray *gLogBuf;
static dispatch_queue_t gLogQ;
static NSString *gLogPath;

static NSString *VPNLogPath(void) {
    if (!gLogPath) {
        NSString *doc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        gLogPath = [doc stringByAppendingPathComponent:@"vpn_adblock.log"];
    }
    return gLogPath;
}

static void VPNFlushLocked(NSArray *batch) {
    dispatch_async(gLogQ, ^{
        NSString *text = [batch componentsJoinedByString:@""];
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:VPNLogPath()]) {
            [@"" writeToFile:VPNLogPath() atomically:NO encoding:NSUTF8StringEncoding error:nil];
        }
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:VPNLogPath()];
        if (!fh) return;
        [fh seekToEndOfFile];
        [fh writeData:[text dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    });
}

static CFAbsoluteTime gStart = 0;

static void VPNLog(NSString *line) {
#if VPN_DEBUG
    static NSDateFormatter *fmt;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"HH:mm:ss.SSS";
        gLogBuf = [[NSMutableArray alloc] init];
        gLogQ = dispatch_queue_create("vpn.log", DISPATCH_QUEUE_SERIAL);
    });
    NSString *out = [NSString stringWithFormat:@"[%@] %@\n", [fmt stringFromDate:[NSDate date]], line];
    NSLog(@"[VPNAdBlock] %@", line);

    @synchronized (gLogBuf) {
        [gLogBuf addObject:out];
        if (gLogBuf.count >= 40) {
            NSArray *b = [gLogBuf copy];
            [gLogBuf removeAllObjects];
            VPNFlushLocked(b);
        }
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

#pragma mark - 【核心】精确类名匹配

// 报告实测的五个广告类，取其特征子串。
// 同时覆盖 mangled(_TtC9XunchiVPN...) 与 demangled(XunchiVPN.HomeBannerCell) 两种形态。
static NSString * const EXACT_KEYS[] = {
    @"HomeBannerCell",        // 首页 banner 单元
    @"HomeBannerCarousel",    // 首页 banner 轮播
    @"AnnouncementPopupView", // 点连接后的公告/推荐弹窗 ★
    @"SplashBrandMarkView",   // 开屏品牌标记
    @"SplashViewController",  // 开屏页
    nil
};

// 通用语义兜底（万一还有别的自研广告 view）
static NSString * const SEMANTIC_KEYS[] = {
    @"Banner", @"AdView", @"Advert", @"Promot", @"Sponsor", @"Popup", nil
};

// 排除：防止误伤（Swift 项目里 Banner 字样也可能出现在正常业务类）
static NSString * const EXCLUDE[] = {
    @"Address", @"Adapter", @"Adaptor", @"Advanced", @"Advisory",
    @"Add", @"Read", @"Load", @"Shadow", @"Gradient", @"Badge", @"Header", @"Trade",
    nil
};

static BOOL VPNMatchExact(NSString *cls) {
    if (cls.length == 0) return NO;
    for (int i = 0; EXACT_KEYS[i]; i++) {
        if ([cls rangeOfString:EXACT_KEYS[i]].length > 0) return YES;
    }
    return NO;
}

static BOOL VPNMatchSemantic(NSString *cls) {
    if (cls.length == 0) return NO;
    for (int i = 0; EXCLUDE[i]; i++) {
        if ([cls rangeOfString:EXCLUDE[i]].length > 0) return NO;
    }
    for (int i = 0; SEMANTIC_KEYS[i]; i++) {
        if ([cls rangeOfString:SEMANTIC_KEYS[i]].length > 0) return YES;
    }
    return NO;
}

// 系统类一律不碰
static BOOL VPNIsSystem(NSString *cls) {
    return ([cls hasPrefix:@"UI"] || [cls hasPrefix:@"CA"] || [cls hasPrefix:@"NS"] ||
            [cls hasPrefix:@"WK"] || [cls hasPrefix:@"_"] || [cls hasPrefix:@"SwiftUI"]);
}

static BOOL VPNIsAdView(UIView *v) {
    if (!v) return NO;
    NSString *cls = NSStringFromClass([v class]);
    if (VPNIsSystem(cls)) return NO;
    if (VPNMatchExact(cls)) return YES;
#if VPN_LEVEL >= 4
    if (VPNMatchSemantic(cls)) return YES;
#endif
    return NO;
}

#pragma mark - 位置识别兜底（LEVEL >= 4）

static BOOL VPNLooksLikeDockBanner(UIView *v) {
#if !BANNER_BY_POSITION
    return NO;
#else
    if (!v || !v.window) return NO;
    if (v.isHidden || v.alpha < 0.05) return NO;

    CGRect f = [v convertRect:v.bounds toView:nil];
    if (f.size.width <= 0 || f.size.height <= 0) return NO;

    CGRect sb = [UIScreen mainScreen].bounds;
    CGFloat sw = MIN(sb.size.width, sb.size.height);
    CGFloat sh = MAX(sb.size.width, sb.size.height);

    BOOL nearFullWidth = (f.size.width >= sw * BANNER_MIN_W_RATIO);
    BOOL bannerHeight  = (f.size.height >= BANNER_MIN_H && f.size.height <= BANNER_MAX_H);
    if (!(nearFullWidth && bannerHeight)) return NO;

    BOOL atTop    = (f.origin.y <= BANNER_EDGE_ZONE);
    BOOL atBottom = ((f.origin.y + f.size.height) >= sh - BANNER_EDGE_ZONE);
    return (atTop || atBottom);
#endif
}

#pragma mark - 视图清扫

static void VPNHideView(UIView *v, NSString *reason) {
    if (!v || v.isHidden) return;
    VPNLogOnce([@"h|" stringByAppendingString:NSStringFromClass([v class])],
               [NSString stringWithFormat:@"hide[%@]: %@ frame=%@",
                reason, NSStringFromClass([v class]), NSStringFromCGRect(v.frame)]);
    v.hidden = YES;
    v.alpha = 0.0;
    v.userInteractionEnabled = NO;
}

static NSArray *VPNWindows(void) {
    NSMutableArray *out = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if (![s isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)s).windows) [out addObject:w];
        }
    }
    if (out.count == 0) {
        UIWindow *w = [UIApplication sharedApplication].keyWindow;
        if (w) [out addObject:w];
    }
    return out;
}

// UICollectionViewCell / UITableViewCell 比较特殊：
// 它们被 cell 复用池持有，隐藏单个 cell 可能被复用。
// 所以发现容器（Carousel）时，优先隐藏整个容器。
static void VPNSweep(UIView *root, int depth) {
    if (!root || depth > 8) return;
    for (UIView *v in root.subviews) {
        BOOL handled = NO;
        if (VPNIsAdView(v)) {
            VPNHideView(v, @"class");
            handled = YES;
        } else if (VPN_LEVEL >= 4 && VPNLooksLikeDockBanner(v)) {
            VPNHideView(v, @"dock");
            handled = YES;
        }
        if (!handled) VPNSweep(v, depth + 1);
    }
}

static void VPNSweepAll(void) {
    for (UIWindow *w in VPNWindows()) VPNSweep(w, 0);
}

#pragma mark - 弹窗拦截

static void VPNCheckWindow(UIWindow *w) {
    if (!w) return;
    NSString *wcls = NSStringFromClass([w class]);
    NSString *rvc  = NSStringFromClass([w.rootViewController class]);

    if (VPNMatchExact(wcls) || VPNMatchExact(rvc)) {
        VPNLog([NSString stringWithFormat:@"popup window kill: %@ root=%@ level=%.1f",
                wcls, rvc, w.windowLevel]);
        w.hidden = YES;
        return;
    }
    if (w.windowLevel > UIWindowLevelNormal + 1.0) {
        VPNSweep(w, 0);
    }
}

static void VPNHookWindow(void) {
    Class W = objc_getClass("UIWindow");
    if (!W) return;

    Method m = class_getInstanceMethod(W, @selector(makeKeyAndVisible));
    if (m) {
        IMP o = method_getImplementation(m);
        method_setImplementation(m, imp_implementationWithBlock(^void(id self, SEL _cmd) {
            if (o) ((void (*)(id, SEL))o)(self, _cmd);
            __block UIWindow *ww = (UIWindow *)self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ VPNCheckWindow(ww); });
        }));
        VPNLog(@"hooked UIWindow makeKeyAndVisible");
    }

    Method mh = class_getInstanceMethod(W, @selector(setHidden:));
    if (mh) {
        IMP o = method_getImplementation(mh);
        method_setImplementation(mh, imp_implementationWithBlock(^void(id self, SEL _cmd, BOOL h) {
            if (o) ((void (*)(id, SEL, BOOL))o)(self, _cmd, h);
            if (!h) {
                __block UIWindow *ww = (UIWindow *)self;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ VPNCheckWindow(ww); });
            }
        }));
        VPNLog(@"hooked UIWindow setHidden:");
    }
}

static void VPNHookPresent(void) {
    Class VC = objc_getClass("UIViewController");
    if (!VC) return;
    Method m = class_getInstanceMethod(VC, @selector(presentViewController:animated:completion:));
    if (!m) return;
    IMP o = method_getImplementation(m);
    method_setImplementation(m, imp_implementationWithBlock(^void(id self, SEL _cmd, UIViewController *vc, BOOL flag, void (^comp)(void)) {
        NSString *cls = NSStringFromClass([vc class]);
        if (VPNMatchExact(cls)) {
            VPNLog([NSString stringWithFormat:@"block present: %@", cls]);
            if (comp) comp();
            return;
        }
        if (o) ((void (*)(id, SEL, UIViewController *, BOOL, void (^)(void)))o)(self, _cmd, vc, flag, comp);
    }));
    VPNLog(@"hooked UIViewController presentViewController:");
}

#pragma mark - 传感器层（摇一摇）

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
            if (VPNInSensorWindow()) { VPNLogOnce(@"acc", @"shake blocked: accelerometer"); return; }
            if (o) ((void (*)(id, SEL, NSOperationQueue *, void (^)(CMAccelerometerData *, NSError *)))o)(self, @selector(startAccelerometerUpdatesToQueue:withHandler:), q, h);
        }));
    }
    Method m2 = class_getInstanceMethod(CMM, @selector(startDeviceMotionUpdatesToQueue:withHandler:));
    if (m2) {
        IMP o = method_getImplementation(m2);
        method_setImplementation(m2, imp_implementationWithBlock(^void(id self, NSOperationQueue *q, void (^h)(CMDeviceMotion *, NSError *)) {
            if (VPNInSensorWindow()) { VPNLogOnce(@"dm", @"shake blocked: deviceMotion"); return; }
            if (o) ((void (*)(id, SEL, NSOperationQueue *, void (^)(CMDeviceMotion *, NSError *)))o)(self, @selector(startDeviceMotionUpdatesToQueue:withHandler:), q, h);
        }));
    }
    Method m3 = class_getInstanceMethod(CMM, @selector(startGyroUpdatesToQueue:withHandler:));
    if (m3) {
        IMP o = method_getImplementation(m3);
        method_setImplementation(m3, imp_implementationWithBlock(^void(id self, NSOperationQueue *q, void (^h)(CMGyroData *, NSError *)) {
            if (VPNInSensorWindow()) { VPNLogOnce(@"gy", @"shake blocked: gyro"); return; }
            if (o) ((void (*)(id, SEL, NSOperationQueue *, void (^)(CMGyroData *, NSError *)))o)(self, @selector(startGyroUpdatesToQueue:withHandler:), q, h);
        }));
    }

    Class R = objc_getClass("UIResponder");
    if (!R) return;
    Method me = class_getInstanceMethod(R, @selector(motionEnded:withEvent:));
    if (me) {
        IMP o = method_getImplementation(me);
        method_setImplementation(me, imp_implementationWithBlock(^void(id self, UIEventSubtype motion, UIEvent *ev) {
            if (motion == UIEventSubtypeMotionShake && VPNInSensorWindow()) {
                VPNLogOnce(@"me", @"shake swallowed: motionEnded"); return;
            }
            if (o) ((void (*)(id, SEL, UIEventSubtype, UIEvent *))o)(self, @selector(motionEnded:withEvent:), motion, ev);
        }));
    }
}

#pragma mark - LEVEL 5 dump

static void VPNDumpTree(UIView *root, int depth, NSMutableString *buf) {
    if (!root || depth > 9) return;
    NSMutableString *pad = [NSMutableString string];
    for (int i = 0; i < depth; i++) [pad appendString:@"  "];

    NSString *cls = NSStringFromClass([root class]);
    NSString *mark = @"";
    if (VPNMatchExact(cls)) mark = @"   <<< AD-EXACT";
    else if (VPNLooksLikeDockBanner(root)) mark = @"   <<< DOCK-POS";

    [buf appendFormat:@"%@%@ | %@%@\n", pad, cls, NSStringFromCGRect(root.frame), mark];
    for (UIView *sub in root.subviews) VPNDumpTree(sub, depth + 1, buf);
}

static void VPNDumpAll(NSString *scene) {
    NSArray *wins = VPNWindows();
    NSMutableString *buf = [NSMutableString string];
    [buf appendFormat:@"\n########## DUMP [%@] windows=%lu ##########\n", scene, (unsigned long)wins.count];
    for (UIWindow *w in wins) {
        [buf appendFormat:@"== WINDOW %@ root=%@ level=%.1f frame=%@\n",
         NSStringFromClass([w class]), NSStringFromClass([w.rootViewController class]),
         w.windowLevel, NSStringFromCGRect(w.frame)];
        VPNDumpTree(w, 1, buf);
    }
    [buf appendString:@"########## END ##########\n"];
    VPNLog(buf);
}

#pragma mark - 页面出现时清扫

static void VPNHookViewController(void) {
    Class VC = objc_getClass("UIViewController");
    if (!VC) return;
    Method m = class_getInstanceMethod(VC, @selector(viewDidAppear:));
    if (!m) return;
    IMP o = method_getImplementation(m);
    method_setImplementation(m, imp_implementationWithBlock(^void(id self, BOOL animated) {
        if (o) ((void (*)(id, SEL, BOOL))o)(self, @selector(viewDidAppear:), animated);
        NSString *vcName = NSStringFromClass([self class]);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
#if VPN_LEVEL == 5
            VPNDumpAll(vcName);
#elif VPN_LEVEL >= 3
            VPNSweepAll();
#endif
        });
    }));
    VPNLog(@"hooked UIViewController viewDidAppear:");
}

#pragma mark - 入口

__attribute__((constructor))
static void VPNEntry(void) {
    gStart = CFAbsoluteTimeGetCurrent();
    VPNLog([NSString stringWithFormat:@"========== VPNAdBlock v3 loaded, LEVEL=%d ==========", VPN_LEVEL]);

#if VPN_LEVEL == 0
    VPNLog(@"LEVEL 0: 空壳，零 hook。");
    return;
#endif

    dispatch_async(dispatch_get_main_queue(), ^{
        VPNHookSensors();
#if VPN_LEVEL >= 2
        VPNHookPresent();
        VPNHookWindow();
#endif
#if VPN_LEVEL >= 3
        VPNHookViewController();
#endif
    });

    // Swift 视图不会走方法 hook，只能靠定时清扫。
    // 类名已精确已知，遍历视图树开销极小，多扫几轮无性能压力。
    // 弹窗（点击连接后）出现时机不定，所以覆盖到 12 秒。
    NSTimeInterval delays[] = {0.5, 1.5, 3.0, 5.0, 8.0, 12.0};
    for (int i = 0; i < 6; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[i] * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
#if VPN_LEVEL == 5
            if (i == 2 || i == 5) VPNDumpAll([NSString stringWithFormat:@"t%.1fs", delays[i]]);
#elif VPN_LEVEL >= 3
            VPNSweepAll();
#endif
        });
    }
}
