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
+ (instancetype)sharedHandler;
- (CVPixelBufferRef)processPixelBuffer:(CVPixelBufferRef)pixelBuffer;
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
        self.ciContext = [CIContext contextWithOptions:nil];
        wvbLog(@"WVBVideoFrameHandler init, ciContext=%@", self.ciContext);
    }
    return self;
}

- (CVPixelBufferRef)processPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    if (!pixelBuffer) {
        wvbLog(@"❌ processPixelBuffer: pixelBuffer is nil");
        return NULL;
    }

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL beautyEnabled = [defaults boolForKey:kSettingKeyBeauty];
    if (!beautyEnabled) {
        wvbLog(@"⚠️  beauty disabled, skip");
        return NULL;
    }

    CGFloat whitenLevel = [defaults floatForKey:kSettingKeyWhiten];
    CGFloat smoothLevel = [defaults floatForKey:kSettingKeySmooth];
    wvbLog(@"processPixelBuffer: whiten=%.2f smooth=%.2f", whitenLevel, smoothLevel);

    @try {
        CIImage *image = [CIImage imageWithCVPixelBuffer:pixelBuffer];
        if (!image) {
            wvbLog(@"❌ failed to create CIImage");
            return NULL;
        }

        // 美白
        if (whitenLevel > 0.01) {
            CIFilter *colorControls = [CIFilter filterWithName:@"CIColorControls"];
            [colorControls setValue:image forKey:kCIInputImageKey];
            [colorControls setValue:@(0.05 * whitenLevel) forKey:kCIInputBrightnessKey];
            [colorControls setValue:@(1.0 + 0.08 * whitenLevel) forKey:kCIInputSaturationKey];
            [colorControls setValue:@(1.0 + 0.03 * whitenLevel) forKey:kCIInputContrastKey];
            image = [colorControls valueForKey:kCIOutputImageKey];
        }

        // 磨皮
        if (smoothLevel > 0.01) {
            CIFilter *noiseReduction = [CIFilter filterWithName:@"CINoiseReduction"];
            [noiseReduction setValue:image forKey:kCIInputImageKey];
            [noiseReduction setValue:@(0.02 * smoothLevel) forKey:@"inputNoiseLevel"];
            [noiseReduction setValue:@(0.3 * smoothLevel) forKey:@"inputSharpness"];
            image = [noiseReduction valueForKey:kCIOutputImageKey];
        }

        size_t width = CVPixelBufferGetWidth(pixelBuffer);
        size_t height = CVPixelBufferGetHeight(pixelBuffer);
        OSType pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);

        CVPixelBufferRef outputBuffer = NULL;
        CVReturn ret = CVPixelBufferCreate(kCFAllocatorDefault, width, height, pixelFormat, NULL, &outputBuffer);
        if (ret != kCVReturnSuccess || !outputBuffer) {
            wvbLog(@"❌ CVPixelBufferCreate failed, ret=%d", (int)ret);
            return NULL;
        }

        [self.ciContext render:image toCVPixelBuffer:outputBuffer];
        wvbLog(@"✅ rendered to outputBuffer %p", outputBuffer);
        return outputBuffer;
    } @catch (NSException *e) {
        wvbLog(@"❌ EXCEPTION in processPixelBuffer: %@", e);
        return NULL;
    }
}

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    if (!sampleBuffer || !self.originalDelegate) {
        if (self.originalDelegate && [self.originalDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
            [self.originalDelegate captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
        }
        return;
    }

    @try {
        CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (!pixelBuffer) {
            if ([self.originalDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
                [self.originalDelegate captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
            }
            return;
        }

        CVPixelBufferRef processedBuffer = [self processPixelBuffer:pixelBuffer];
        if (!processedBuffer) {
            if ([self.originalDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
                [self.originalDelegate captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
            }
            return;
        }

        CMSampleBufferRef newSampleBuffer = NULL;
        CMSampleTimingInfo timingInfo;
        CMSampleBufferGetSampleTimingInfo(sampleBuffer, 0, &timingInfo);

        CMVideoFormatDescriptionRef formatDesc = NULL;
        CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, processedBuffer, &formatDesc);

        CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, processedBuffer, true, NULL, NULL, formatDesc, &timingInfo, &newSampleBuffer);

        if (formatDesc) CFRelease(formatDesc);

        if (newSampleBuffer) {
            if ([self.originalDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
                [self.originalDelegate captureOutput:output didOutputSampleBuffer:newSampleBuffer fromConnection:connection];
            }
            CFRelease(newSampleBuffer);
        } else {
            wvbLog(@"❌ CMSampleBufferCreateForImageBuffer failed");
            if ([self.originalDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
                [self.originalDelegate captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
            }
        }

        CVPixelBufferRelease(processedBuffer);
    } @catch (NSException *e) {
        wvbLog(@"❌ EXCEPTION in captureOutput: %@", e);
        if ([self.originalDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
            [self.originalDelegate captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
        }
    }
}

@end

// ============ 悬浮按钮管理器 ============

@class WVBSettingsVC;

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

    // 全屏透明背景窗口
    self.settingsWindow = [[UIWindow alloc] initWithFrame:screenBounds];
    self.settingsWindow.windowLevel = UIWindowLevelStatusBar + 3000;
    self.settingsWindow.backgroundColor = [UIColor clearColor];
    self.settingsWindow.rootViewController = [[UIViewController alloc] init];

    // 点击背景关闭
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(hideSettings)];
    [self.settingsWindow.rootViewController.view addGestureRecognizer:tap];

    // 设置面板
    WVBSettingsVC *vc = [[WVBSettingsVC alloc] init];
    vc.manager = self;
    vc.view.frame = CGRectMake(0, 0, screenBounds.size.width, screenBounds.size.height);

    [self.settingsWindow.rootViewController addChildViewController:vc];
    [self.settingsWindow.rootViewController.view addSubview:vc.view];
    [vc didMoveToParentViewController:self.settingsWindow.rootViewController];

    [self.settingsWindow makeKeyAndVisible];
    wvbLog(@"settingsWindow shown");
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

// ============ 设置面板（自定义模态，不依赖微信 VC 层级）=============

@interface WVBSettingsVC : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, weak) WVBManager *manager;
@property (nonatomic, strong) UITableView *tableView;
@end

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

    UIButton *plusBtn = (UIButton *)[stack viewWithTag:1];
    UIButton *minusBtn = (UIButton *)[stack viewWithTag:0];
    plusBtn.tag = indexPath.section;
    minusBtn.tag = indexPath.section;
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

- (void)increaseLevel:(UIButton *)btn {
    NSInteger section = btn.tag;
    NSString *key = (section == 1) ? @"wvb_whiten_level" : @"wvb_smooth_level";
    CGFloat level = [[NSUserDefaults standardUserDefaults] floatForKey:key];
    level = MIN(1.0, level + 0.1);
    [[NSUserDefaults standardUserDefaults] setFloat:level forKey:key];
    [[NSUserDefaults standardUserDefaults] synchronize];
    wvbLog(@"%@ +10%% -> %.1f", (section == 1) ? @"whiten" : @"smooth", level);
    [self.tableView reloadData];
}

- (void)decreaseLevel:(UIButton *)btn {
    NSInteger section = btn.tag;
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
        @try {
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
        } @catch (NSException *e) {
            wvbLog(@"EXCEPTION checking front camera: %@", e);
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
    wvbLog(@"========================================");
    wvbLog(@"setSampleBufferDelegate called");
    wvbLog(@"   delegate class: %@", NSStringFromClass([delegate class]));
    wvbLog(@"   respondsToSelector: %@",
           [delegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)] ? @"YES" : @"NO");

    if (delegate) {
        WVBVideoFrameHandler *handler = [WVBVideoFrameHandler sharedHandler];
        handler.originalDelegate = delegate;
        wvbLog(@"✅ hooked! handler=%@ originalDelegate=%@", handler, delegate);
        %orig(handler, queue);
    } else {
        wvbLog(@"⚠️  delegate nil, pass through");
        %orig(delegate, queue);
    }
    wvbLog(@"========================================");
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
