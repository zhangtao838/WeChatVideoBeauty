#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>

// ============ 文件日志（写到 /tmp/wvb.log，不用 syslog）============

static void wvbLog(NSString *format, ...) {
    static BOOL truncated = NO;
    if (!truncated) {
        [[NSFileManager defaultManager] removeItemAtPath:@"/tmp/wvb.log" error:NULL];
        truncated = YES;
    }
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    [fmt setDateFormat:@"HH:mm:ss.SSS"];
    va_list args;
    va_start(args, format);
    NSString *body = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *entry = [NSString stringWithFormat:@"[%@] %@\n",
                       [fmt stringFromDate:[NSDate date]], body];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:@"/tmp/wvb.log"];
    if (!fh) {
        [[NSFileManager defaultManager] createFileAtPath:@"/tmp/wvb.log"
                                                contents:nil
                                              attributes:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:@"/tmp/wvb.log"];
    }
    [fh seekToEndOfFile];
    [fh writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

// ============ 常量 ============

#define kSettingKeyMirror @"wvb_mirror_enabled"
#define kSettingKeyBeauty @"wvb_beauty_enabled"
#define kSettingKeyWhiten @"wvb_whiten_level"
#define kSettingKeySmooth @"wvb_smooth_level"

// ============ 视频帧处理工具 ============

@interface WVBVideoFrameHandler : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, weak) id<AVCaptureVideoDataOutputSampleBufferDelegate> originalDelegate;
@property (nonatomic, strong) CIContext *ciContext;
@property (nonatomic, strong) dispatch_queue_t originalQueue; // dispatch_queue 在 ARC 下是 ObjC 对象，必须 strong 而非 assign
@property (nonatomic, assign) NSInteger debugFrameCount; // 诊断用：每 60 帧打一条耗时日志
+ (instancetype)sharedHandler;
- (BOOL)applyBeautyToPixelBuffer:(CVPixelBufferRef)pixelBuffer;
@end

@implementation WVBVideoFrameHandler

+ (instancetype)sharedHandler {
    static WVBVideoFrameHandler *handler = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        handler = [[WVBVideoFrameHandler alloc] init];
    });
    return handler;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // Metal-backed CIContext（默认实现线程安全，可跨队列使用）：
        // 之前的软渲染器(kCIContextUseSoftwareRenderer)在视频帧率下极慢，会把采集队列拖垮
        self.ciContext = [CIContext context];
        wvbLog(@"WVBVideoFrameHandler init, ciContext=%@", self.ciContext);
    }
    return self;
}

// 在"原始" pixel buffer 里原地渲染美颜效果。
// 设计要点：绝不新建 CVPixelBuffer / CMSampleBuffer / CMFormatDescription，
// 微信拿到的是它自己产出的 sample buffer，只是内容被改了——
// timing、attachment、格式描述、IOSurface 全部保持原样，从根上排除"外来替换帧被微信管线拒绝"的闪退。
- (BOOL)applyBeautyToPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    if (!pixelBuffer) {
        return NO;
    }

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL beautyEnabled = [defaults boolForKey:kSettingKeyBeauty];
    if (!beautyEnabled) {
        return NO;
    }

    CGFloat whitenLevel = [defaults floatForKey:kSettingKeyWhiten];
    CGFloat smoothLevel = [defaults floatForKey:kSettingKeySmooth];

    if (whitenLevel < 0.01 && smoothLevel < 0.01) {
        return NO;
    }

    @autoreleasepool {
        CIImage *image = [CIImage imageWithCVPixelBuffer:pixelBuffer];
        if (!image) {
            return NO;
        }

        // 美白：亮度/饱和度/对比度。幅度按 whitenLevel 走，默认 0.5 就能看出提亮+气色，
        // 拉满(1.0)也不会过曝。
        if (whitenLevel > 0.01) {
            CIFilter *colorControls = [CIFilter filterWithName:@"CIColorControls"];
            if (colorControls) {
                [colorControls setValue:image forKey:kCIInputImageKey];
                [colorControls setValue:@(0.12 * whitenLevel) forKey:kCIInputBrightnessKey];
                [colorControls setValue:@(1.0 + 0.12 * whitenLevel) forKey:kCIInputSaturationKey];
                [colorControls setValue:@(1.0 + 0.06 * whitenLevel) forKey:kCIInputContrastKey];
                image = [colorControls valueForKey:kCIOutputImageKey];
                if (!image) {
                    return NO;
                }
            }
        }

        // 磨皮：高斯模糊 + 与原图交叉混合（mix 越大越接近模糊图），再用锐化把眼、眉、轮廓
        // 的边缘拉回来，避免整张脸糊掉。CINoiseReduction 几乎看不出效果，已弃用。
        if (smoothLevel > 0.01) {
            CGFloat sigma = 2.0 + 2.0 * smoothLevel;          // 默认 0.5 → sigma 3，拉满 → 4
            CIImage *blurred = [image imageByApplyingGaussianBlur:sigma];

            CIFilter *dissolve = [CIFilter filterWithName:@"CIDissolveTransition"];
            if (dissolve) {
                [dissolve setValue:blurred forKey:kCIInputImageKey];
                [dissolve setValue:image forKey:kCIInputTargetImageKey];
                [dissolve setValue:@(smoothLevel * 0.9) forKey:kCIInputTimeKey]; // 最多混 90%，留 10% 原图细节
                image = [dissolve valueForKey:kCIOutputImageKey];
                if (!image) {
                    return NO;
                }
            }

            CIFilter *sharpen = [CIFilter filterWithName:@"CISharpenLuminance"];
            if (sharpen) {
                [sharpen setValue:image forKey:kCIInputImageKey];
                [sharpen setValue:@(0.3 + 0.3 * smoothLevel) forKey:@"inputSharpness"];
                image = [sharpen valueForKey:kCIOutputImageKey];
                if (!image) {
                    return NO;
                }
            }
        }

        [self.ciContext render:image toCVPixelBuffer:pixelBuffer];

        return YES;
    }
}

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    @autoreleasepool {
        // 安全检查
        if (!sampleBuffer || !self.originalDelegate) {
            return;
        }

        // 保存原始 delegate（避免回调过程中 self 被篡改）
        id<AVCaptureVideoDataOutputSampleBufferDelegate> delegate = self.originalDelegate;
        if (![delegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
            return;
        }

        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

        // 美颜开着时：在原始 pixel buffer 上原地处理（成功与否都传回原始 sample buffer）
        if ([defaults boolForKey:kSettingKeyBeauty]) {
            CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
            BOOL processed = NO;
            OSType fmt = 0;
            @try {
                CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
                if (pixelBuffer) {
                    fmt = CVPixelBufferGetPixelFormatType(pixelBuffer);
                    processed = [self applyBeautyToPixelBuffer:pixelBuffer];
                }
            } @catch (...) {
                // .mm 里 @catch(...) 能接住 ObjC 和 C++ 两类异常；处理失败就退回原始帧，绝不让微信崩
                wvbLog(@"❌ beauty processing exception, falling back to raw frame");
                processed = NO;
            }

            self.debugFrameCount++;
            if (self.debugFrameCount == 1 || self.debugFrameCount % 60 == 0) {
                wvbLog(@"beauty frame #%ld %@ cost=%.1fms fmt=%c%c%c%c",
                       (long)self.debugFrameCount,
                       processed ? @"processed" : @"passthrough",
                       (CFAbsoluteTimeGetCurrent() - t0) * 1000.0,
                       (char)(fmt >> 24) & 0xff, (char)(fmt >> 16) & 0xff,
                       (char)(fmt >> 8) & 0xff, (char)fmt & 0xff);
            }
        }

        // 始终传回原始 sample buffer（美颜是原地改内容，不需要替换 buffer）
        [delegate captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
    }
}

@end

// ============ 设置面板（完整 interface，必须在 WVBManager 前面，避免前向声明不够用）=============

@class WVBManager;  // 前向声明：WVBSettingsVC 的 property 里弱引用它，@class 就够用（@interface 会破坏 Logos 的块深度计数）

@interface WVBSettingsVC : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, weak) WVBManager *manager;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIView *panelView;
@end

// ============ 悬浮按钮管理器 ============

@interface WVBManager : NSObject
@property (nonatomic, strong) UIWindow *floatWindow;
@property (nonatomic, strong) UIButton *floatButton;
@property (nonatomic, strong) UIWindow *settingsWindow;
+ (instancetype)sharedManager;
- (void)setupFloatButton;
- (void)showSettings;
- (void)hideSettings;
- (void)toggleMirror;
- (void)toggleBeauty;
@end

@implementation WVBManager

+ (instancetype)sharedManager {
    static WVBManager *manager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [[WVBManager alloc] init];
    });
    return manager;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        wvbLog(@"WVBManager init");
    }
    return self;
}

- (void)setupFloatButton {
    CGRect screenBounds = [UIScreen mainScreen].bounds;

    if (self.floatWindow) {
        wvbLog(@"floatWindow already exists, hidden=%@ -> show it",
               self.floatWindow.hidden ? @"YES" : @"NO");
        self.floatWindow.hidden = NO;
        return;
    }

    wvbLog(@"=== setupFloatButton start ===");

    CGFloat buttonSize = 44.0;
    CGFloat screenWidth = screenBounds.size.width;
    CGFloat initialX = screenWidth - buttonSize - 16;
    CGFloat initialY = 120;

    wvbLog(@"screen: %@, button pos: (%.0f, %.0f)",
           NSStringFromCGRect(screenBounds), initialX, initialY);

    self.floatWindow = [[UIWindow alloc] initWithFrame:CGRectMake(initialX, initialY, buttonSize, buttonSize)];
    self.floatWindow.windowLevel = UIWindowLevelStatusBar + 1000;
    self.floatWindow.backgroundColor = [UIColor clearColor];
    self.floatWindow.rootViewController = [[UIViewController alloc] init];
    self.floatWindow.rootViewController.view.backgroundColor = [UIColor clearColor];
    self.floatWindow.hidden = NO;
    [self.floatWindow makeKeyAndVisible];

    wvbLog(@"floatWindow created: frame=%@ level=%.0f hidden=%@",
           NSStringFromCGRect(self.floatWindow.frame),
           self.floatWindow.windowLevel,
           self.floatWindow.hidden ? @"YES" : @"NO");

    self.floatButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.floatButton.frame = CGRectMake(0, 0, buttonSize, buttonSize);
    self.floatButton.backgroundColor = [UIColor clearColor];
    self.floatButton.layer.cornerRadius = buttonSize / 2.0;
    self.floatButton.layer.borderWidth = 2.0;
    self.floatButton.layer.borderColor = [UIColor whiteColor].CGColor;
    self.floatButton.layer.shadowColor = [UIColor blackColor].CGColor;
    self.floatButton.layer.shadowOffset = CGSizeMake(0, 2);
    self.floatButton.layer.shadowOpacity = 0.3;
    self.floatButton.layer.shadowRadius = 4;
    [self.floatButton setTitle:@"✨" forState:UIControlStateNormal];
    self.floatButton.titleLabel.font = [UIFont systemFontOfSize:20];
    [self.floatButton addTarget:self action:@selector(handleButtonTap) forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self.floatButton addGestureRecognizer:pan];

    [self.floatWindow addSubview:self.floatButton];

    wvbLog(@"floatButton added: frame=%@ title='%@' subviews=%lu",
           NSStringFromCGRect(self.floatButton.frame),
           [self.floatButton titleForState:UIControlStateNormal],
           (unsigned long)self.floatWindow.subviews.count);
    wvbLog(@"=== setupFloatButton done ===");
}

- (void)handleButtonTap {
    wvbLog(@"float button tapped");
    [self showSettings];
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    CGPoint translation = [pan translationInView:self.floatWindow];
    CGPoint newCenter = CGPointMake(self.floatWindow.center.x + translation.x,
                                      self.floatWindow.center.y + translation.y);

    CGRect screenBounds = [UIScreen mainScreen].bounds;
    CGFloat halfWidth = self.floatWindow.bounds.size.width / 2.0;
    CGFloat halfHeight = self.floatWindow.bounds.size.height / 2.0;
    newCenter.x = MAX(halfWidth, MIN(screenBounds.size.width - halfWidth, newCenter.x));
    newCenter.y = MAX(halfHeight + 40, MIN(screenBounds.size.height - halfHeight - 40, newCenter.y));

    self.floatWindow.center = newCenter;
    [pan setTranslation:CGPointZero inView:self.floatWindow];
}

- (void)showSettings {
    wvbLog(@"showSettings");

    if (self.settingsWindow) {
        self.settingsWindow.hidden = NO;
        return;
    }

    CGRect screenBounds = [UIScreen mainScreen].bounds;

    // 全屏背景窗口
    self.settingsWindow = [[UIWindow alloc] initWithFrame:screenBounds];
    self.settingsWindow.windowLevel = UIWindowLevelStatusBar + 3000;
    self.settingsWindow.backgroundColor = [UIColor clearColor];
    self.settingsWindow.rootViewController = [[UIViewController alloc] init];

    // 设置面板
    WVBSettingsVC *vc = [[WVBSettingsVC alloc] init];
    vc.manager = self;
    vc.view.frame = CGRectMake(0, 0, screenBounds.size.width, screenBounds.size.height);

    [self.settingsWindow.rootViewController addChildViewController:vc];
    [self.settingsWindow.rootViewController.view addSubview:vc.view];
    [vc didMoveToParentViewController:self.settingsWindow.rootViewController];

    // 点击面板外部关闭（在 vc.view 上加 tap，通过坐标判断是否点在面板上）
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleSettingsBackgroundTap:)];
    tap.cancelsTouchesInView = NO;
    [vc.view addGestureRecognizer:tap];

    [self.settingsWindow makeKeyAndVisible];
    wvbLog(@"settingsWindow shown");
}

- (void)handleSettingsBackgroundTap:(UITapGestureRecognizer *)tap {
    // 检查 tap 位置是否在面板内
    WVBSettingsVC *vc = (WVBSettingsVC *)self.settingsWindow.rootViewController.childViewControllers.firstObject;
    if (!vc || !vc.panelView) {
        [self hideSettings];
        return;
    }

    CGPoint location = [tap locationInView:vc.view];
    if (CGRectContainsPoint(vc.panelView.frame, location)) {
        // 点在面板内部，不关闭
        return;
    }

    // 点在面板外部，关闭
    [self hideSettings];
}

- (void)hideSettings {
    wvbLog(@"hideSettings");
    self.settingsWindow.hidden = YES;
}

- (void)toggleMirror {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL current = [defaults boolForKey:kSettingKeyMirror];
    [defaults setBool:!current forKey:kSettingKeyMirror];
    [defaults synchronize];
    wvbLog(@"mirror: %@ -> %@", current ? @"ON" : @"OFF", !current ? @"ON" : @"OFF");
}

- (void)toggleBeauty {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL current = [defaults boolForKey:kSettingKeyBeauty];
    [defaults setBool:!current forKey:kSettingKeyBeauty];
    [defaults synchronize];
    wvbLog(@"beauty: %@ -> %@", current ? @"ON" : @"OFF", !current ? @"ON" : @"OFF");
}

@end

// ============ 设置面板实现（interface 已移到 WVBManager 前面）=============

@implementation WVBSettingsVC

- (void)viewDidLoad {
    [super viewDidLoad];

    // 半透明背景
    self.view.backgroundColor = [UIColor clearColor];

    // 面板容器
    CGFloat panelWidth = 320;
    CGFloat panelHeight = 420;
    CGRect screenBounds = [UIScreen mainScreen].bounds;
    if (screenBounds.size.width < panelWidth) {
        panelWidth = screenBounds.size.width - 40;
    }
    if (panelHeight > screenBounds.size.height - 120) {
        panelHeight = screenBounds.size.height - 120;
    }
    CGFloat panelX = (screenBounds.size.width - panelWidth) / 2;
    CGFloat panelY = (screenBounds.size.height - panelHeight) / 2;

    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(panelX, panelY, panelWidth, panelHeight)];
    panel.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.95];
    panel.layer.cornerRadius = 16;
    panel.layer.shadowColor = [UIColor blackColor].CGColor;
    panel.layer.shadowOffset = CGSizeMake(0, 4);
    panel.layer.shadowOpacity = 0.3;
    panel.layer.shadowRadius = 12;
    self.panelView = panel;
    [self.view addSubview:panel];

    // 标题
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 16, panelWidth, 30)];
    title.text = @"✨ 微信视频美颜助手";
    title.textAlignment = NSTextAlignmentCenter;
    title.font = [UIFont boldSystemFontOfSize:18];
    title.textColor = [UIColor colorWithRed:0.18 green:0.49 blue:0.96 alpha:1.0];
    [panel addSubview:title];

    // 表格
    CGFloat tableY = 52;
    CGFloat tableH = panelHeight - tableY - 16;
    self.tableView = [[UITableView alloc] initWithFrame:CGRectMake(12, tableY, panelWidth - 24, tableH)
                                                  style:UITableViewStyleGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.layer.cornerRadius = 12;
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.separatorInset = UIEdgeInsetsZero;
    self.tableView.estimatedRowHeight = 50;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    [panel addSubview:self.tableView];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 4;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 2;  // 镜像 + 美颜开关
    if (section == 1) return 2;  // 美白 +/-
    if (section == 2) return 2;  // 磨皮 +/-
    return 1;                    // 关闭按钮
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"功能开关";
    if (section == 1) return @"美白强度";
    if (section == 2) return @"磨皮强度";
    return @"";
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    if (section == 3) return 8;  // 关闭按钮区域，小间距
    return 32;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *kSwitchCell = @"SwitchCell";
    static NSString *kSliderCell = @"SliderCell";
    static NSString *kCloseCell = @"CloseCell";

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    if (indexPath.section == 3 && indexPath.row == 0) {
        // 关闭按钮
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kCloseCell];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kCloseCell];
            cell.textLabel.text = @"❌ 关闭";
            cell.textLabel.textAlignment = NSTextAlignmentCenter;
            cell.textLabel.textColor = [UIColor redColor];
            cell.textLabel.font = [UIFont boldSystemFontOfSize:16];
        }
        return cell;
    }

    if (indexPath.section == 0) {
        // 开关行
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kSwitchCell];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kSwitchCell];
            cell.accessoryView = [[UISwitch alloc] init];
            ((UISwitch *)cell.accessoryView).onTintColor = [UIColor colorWithRed:0.18 green:0.49 blue:0.96 alpha:1.0];
        }

        if (indexPath.row == 0) {
            cell.textLabel.text = @"📷 视频镜像";
            BOOL on = [defaults boolForKey:@"wvb_mirror_enabled"];
            ((UISwitch *)cell.accessoryView).on = on;
            [((UISwitch *)cell.accessoryView) removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
            ((UISwitch *)cell.accessoryView).tag = 100;
            [((UISwitch *)cell.accessoryView) addTarget:self action:@selector(toggleSwitch:) forControlEvents:UIControlEventValueChanged];
        } else {
            cell.textLabel.text = @"💄 视频美颜";
            BOOL on = [defaults boolForKey:@"wvb_beauty_enabled"];
            ((UISwitch *)cell.accessoryView).on = on;
            [((UISwitch *)cell.accessoryView) removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
            ((UISwitch *)cell.accessoryView).tag = 101;
            [((UISwitch *)cell.accessoryView) addTarget:self action:@selector(toggleSwitch:) forControlEvents:UIControlEventValueChanged];
        }
        cell.textLabel.font = [UIFont systemFontOfSize:15];
        return cell;
    }

    // 强度行（标题 + [-] [+] 按钮）
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kSliderCell];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kSliderCell];
        cell.textLabel.font = [UIFont systemFontOfSize:15];

        UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectMake(0, 0, 100, 28)];
        stack.axis = UILayoutConstraintAxisHorizontal;
        stack.spacing = 8;
        stack.alignment = UIStackViewAlignmentCenter;
        stack.distribution = UIStackViewDistributionFillEqually;
        stack.tag = 999;

        UIButton *plus = [UIButton buttonWithType:UIButtonTypeSystem];
        [plus setTitle:@"+10%" forState:UIControlStateNormal];
        plus.titleLabel.font = [UIFont boldSystemFontOfSize:13];
        plus.tag = 1;

        UIButton *minus = [UIButton buttonWithType:UIButtonTypeSystem];
        [minus setTitle:@"-10%" forState:UIControlStateNormal];
        minus.titleLabel.font = [UIFont boldSystemFontOfSize:13];
        minus.tag = 0;

        [stack addArrangedSubview:minus];
        [stack addArrangedSubview:plus];
        cell.accessoryView = stack;
    }

    // 清理旧 target（避免 reuse 时重复触发）
    UIStackView *stack = (UIStackView *)cell.accessoryView;
    for (UIView *v in stack.arrangedSubviews) {
        if ([v isKindOfClass:[UIButton class]]) {
            [(UIButton *)v removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
        }
    }

    NSString *key = (indexPath.section == 1) ? @"wvb_whiten_level" : @"wvb_smooth_level";
    CGFloat level = [defaults floatForKey:key];
    NSString *prefix = (indexPath.section == 1) ? @"美白" : @"磨皮";

    cell.textLabel.text = [NSString stringWithFormat:@"%@强度：%.0f%%", prefix, level * 100];

    // 按钮 tag 保持创建时的固定值（minus=0 / plus=1），所属 section 记在 cell.tag 上；
    // 之前把按钮 tag 覆盖成 section，cell 复用后 viewWithTag: 会找错按钮甚至返回 nil
    cell.tag = indexPath.section;
    UIButton *plusBtn = (UIButton *)[stack viewWithTag:1];
    UIButton *minusBtn = (UIButton *)[stack viewWithTag:0];
    [plusBtn addTarget:self action:@selector(increaseLevel:) forControlEvents:UIControlEventTouchUpInside];
    [minusBtn addTarget:self action:@selector(decreaseLevel:) forControlEvents:UIControlEventTouchUpInside];

    return cell;
}

- (void)toggleSwitch:(UISwitch *)sw {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (sw.tag == 100) {
        [defaults setBool:sw.isOn forKey:@"wvb_mirror_enabled"];
        wvbLog(@"mirror: %@", sw.isOn ? @"ON" : @"OFF");
    } else {
        [defaults setBool:sw.isOn forKey:@"wvb_beauty_enabled"];
        wvbLog(@"beauty: %@", sw.isOn ? @"ON" : @"OFF");
    }
    [defaults synchronize];
}

// 从按钮向上遍历视图层级找到所在 cell，读取 cell.tag 里存的 section（比写死 superview 层数稳）
- (NSInteger)wvbSectionForButton:(UIButton *)btn {
    UIView *v = btn;
    while (v && ![v isKindOfClass:[UITableViewCell class]]) {
        v = v.superview;
    }
    return v ? (NSInteger)((UITableViewCell *)v).tag : 0;
}

- (void)increaseLevel:(UIButton *)btn {
    NSInteger section = [self wvbSectionForButton:btn];
    NSString *key = (section == 1) ? @"wvb_whiten_level" : @"wvb_smooth_level";
    CGFloat level = [[NSUserDefaults standardUserDefaults] floatForKey:key];
    level = MIN(1.0, level + 0.1);
    [[NSUserDefaults standardUserDefaults] setFloat:level forKey:key];
    [[NSUserDefaults standardUserDefaults] synchronize];
    wvbLog(@"%@ +10%% -> %.1f", (section == 1) ? @"whiten" : @"smooth", level);
    [self.tableView reloadData];
}

- (void)decreaseLevel:(UIButton *)btn {
    NSInteger section = [self wvbSectionForButton:btn];
    NSString *key = (section == 1) ? @"wvb_whiten_level" : @"wvb_smooth_level";
    CGFloat level = [[NSUserDefaults standardUserDefaults] floatForKey:key];
    level = MAX(0.0, level - 0.1);
    [[NSUserDefaults standardUserDefaults] setFloat:level forKey:key];
    [[NSUserDefaults standardUserDefaults] synchronize];
    wvbLog(@"%@ -10%% -> %.1f", (section == 1) ? @"whiten" : @"smooth", level);
    [self.tableView reloadData];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    // 关闭按钮
    if (indexPath.section == 3) {
        [self.manager hideSettings];
    }
}

@end

// ============ Hook AVCaptureConnection（视频镜像）=============

%hook AVCaptureConnection

- (void)setVideoMirrored:(BOOL)videoMirrored {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL mirrorEnabled = [defaults boolForKey:kSettingKeyMirror];

    wvbLog(@"setVideoMirrored: mirrorEnabled=%@ currentValue=%@",
           mirrorEnabled ? @"YES" : @"NO",
           videoMirrored ? @"YES" : @"NO");

    if (mirrorEnabled) {
        BOOL isFrontCamera = NO;
        AVCaptureInputPort *port = [self inputPorts].firstObject;
        if (port) {
            AVCaptureInput *input = port.input;
            if ([input isKindOfClass:[AVCaptureDeviceInput class]]) {
                AVCaptureDevice *device = [(AVCaptureDeviceInput *)input device];
                if (device && device.position == AVCaptureDevicePositionFront) {
                    isFrontCamera = YES;
                }
            }
        }

        if (isFrontCamera) {
            wvbLog(@"✅ force mirror YES (front camera)");
            %orig(YES);
            return;
        } else {
            wvbLog(@"⚠️  not front camera, pass original");
        }
    }

    %orig(videoMirrored);
}

%end

// ============ Hook AVCaptureVideoDataOutput（美颜帧处理）=============

%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate queue:(dispatch_queue_t)queue {
    wvbLog(@"setSampleBufferDelegate: class=%@ queue=%p", NSStringFromClass([delegate class]), queue);

    if (delegate && [delegate conformsToProtocol:@protocol(AVCaptureVideoDataOutputSampleBufferDelegate)]) {
        WVBVideoFrameHandler *handler = [WVBVideoFrameHandler sharedHandler];
        handler.originalDelegate = delegate;
        handler.originalQueue = queue;
        wvbLog(@"✅ hooked delegate, queue=%p", queue);
        %orig(handler, queue);
    } else {
        wvbLog(@"⚠️  delegate nil or not conforming, pass through");
        %orig(delegate, queue);
    }
}

%end

// ============ 构造函数 ============

%ctor {
    wvbLog(@"========================================");
    wvbLog(@"WeChatVideoBeauty v1.2 LOADED");
    wvbLog(@"   log file: /tmp/wvb.log");
    wvbLog(@"========================================");

    // 默认设置
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (![defaults objectForKey:kSettingKeyMirror]) {
        [defaults setBool:YES forKey:kSettingKeyMirror];
    }
    if (![defaults objectForKey:kSettingKeyBeauty]) {
        [defaults setBool:NO forKey:kSettingKeyBeauty];
    }
    if (![defaults objectForKey:kSettingKeyWhiten]) {
        [defaults setFloat:0.5 forKey:kSettingKeyWhiten];
    }
    if (![defaults objectForKey:kSettingKeySmooth]) {
        [defaults setFloat:0.5 forKey:kSettingKeySmooth];
    }
    [defaults synchronize];

    wvbLog(@"default settings: mirror=YES beauty=NO whiten=0.5 smooth=0.5");

    // 微信进入前台时创建悬浮按钮
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        wvbLog(@"UIApplicationDidBecomeActiveNotification");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[WVBManager sharedManager] setupFloatButton];
        });
    }];

    // 兜底：延迟 2 秒直接创建一次
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        wvbLog(@"delayed setup (2s fallback)");
        [[WVBManager sharedManager] setupFloatButton];
    });

    wvbLog(@"constructor done, check /tmp/wvb.log for floatWindow logs");
}
