#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>

#pragma mark - 调试日志宏

#define WVBLog(fmt, ...) NSLog(@"[WeChatVideoBeauty] " fmt, ##__VA_ARGS__)

#pragma mark - 常量

#define kSettingKeyMirror @"wvb_mirror_enabled"
#define kSettingKeyBeauty @"wvb_beauty_enabled"
#define kSettingKeyWhiten @"wvb_whiten_level"
#define kSettingKeySmooth @"wvb_smooth_level"

#pragma mark - 视频帧处理工具

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
        WVBLog(@"WVBVideoFrameHandler initialized");
    }
    return self;
}

- (CVPixelBufferRef)processPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    if (!pixelBuffer) {
        WVBLog(@"processPixelBuffer: pixelBuffer is nil");
        return NULL;
    }

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL beautyEnabled = [defaults boolForKey:kSettingKeyBeauty];
    if (!beautyEnabled) {
        return NULL; // 返回 NULL 表示不处理，用原始帧
    }

    CGFloat whitenLevel = [defaults floatForKey:kSettingKeyWhiten];
    CGFloat smoothLevel = [defaults floatForKey:kSettingKeySmooth];

    @try {
        CIImage *image = [CIImage imageWithCVPixelBuffer:pixelBuffer];
        if (!image) {
            WVBLog(@"failed to create CIImage from pixelBuffer");
            return NULL;
        }

        // 美白：CIColorControls 调整亮度/饱和度/对比度
        if (whitenLevel > 0.01) {
            CIFilter *colorControls = [CIFilter filterWithName:@"CIColorControls"];
            [colorControls setValue:image forKey:kCIInputImageKey];
            [colorControls setValue:@(0.05 * whitenLevel) forKey:kCIInputBrightnessKey];
            [colorControls setValue:@(1.0 + 0.08 * whitenLevel) forKey:kCIInputSaturationKey];
            [colorControls setValue:@(1.0 + 0.03 * whitenLevel) forKey:kCIInputContrastKey];
            image = [colorControls valueForKey:kCIOutputImageKey];
        }

        // 磨皮：CINoiseReduction 降噪 + 轻微锐化
        if (smoothLevel > 0.01) {
            CIFilter *noiseReduction = [CIFilter filterWithName:@"CINoiseReduction"];
            [noiseReduction setValue:image forKey:kCIInputImageKey];
            [noiseReduction setValue:@(0.02 * smoothLevel) forKey:@"inputNoiseLevel"];
            [noiseReduction setValue:@(0.3 * smoothLevel) forKey:@"inputSharpness"];
            image = [noiseReduction valueForKey:kCIOutputImageKey];
        }

        // 创建输出 PixelBuffer
        size_t width = CVPixelBufferGetWidth(pixelBuffer);
        size_t height = CVPixelBufferGetHeight(pixelBuffer);
        OSType pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);

        CVPixelBufferRef outputBuffer = NULL;
        CVReturn ret = CVPixelBufferCreate(kCFAllocatorDefault, width, height, pixelFormat, NULL, &outputBuffer);
        if (ret != kCVReturnSuccess || !outputBuffer) {
            WVBLog(@"failed to create output pixelBuffer, ret=%d", (int)ret);
            return NULL;
        }

        // 渲染
        [self.ciContext render:image toCVPixelBuffer:outputBuffer];
        return outputBuffer;
    } @catch (NSException *e) {
        WVBLog(@"EXCEPTION in processPixelBuffer: %@", e);
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
            // 美颜未开启或处理失败，用原始帧
            if ([self.originalDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
                [self.originalDelegate captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
            }
            return;
        }

        // 从处理后的 PixelBuffer 创建新的 CMSampleBuffer
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
            WVBLog(@"failed to create new sampleBuffer, using original");
            if ([self.originalDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
                [self.originalDelegate captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
            }
        }

        CVPixelBufferRelease(processedBuffer);
    } @catch (NSException *e) {
        WVBLog(@"EXCEPTION in captureOutput: %@", e);
        if ([self.originalDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
            [self.originalDelegate captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
        }
    }
}

@end

#pragma mark - 管理器单例

@interface WVBManager : NSObject
@property (nonatomic, strong) UIWindow *floatWindow;
@property (nonatomic, strong) UIButton *floatButton;
@property (nonatomic, assign) BOOL isDragging;
+ (instancetype)sharedManager;
- (void)setupFloatButton;
- (void)showSettings;
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
        WVBLog(@"WVBManager initialized");
    }
    return self;
}

- (void)setupFloatButton {
    if (self.floatWindow) {
        WVBLog(@"floatWindow already exists");
        return;
    }

    WVBLog(@"setting up float button");

    CGFloat buttonSize = 44.0;
    CGRect screenBounds = [UIScreen mainScreen].bounds;
    CGFloat initialX = screenBounds.size.width - buttonSize - 16;
    CGFloat initialY = 120;

    self.floatWindow = [[UIWindow alloc] initWithFrame:CGRectMake(initialX, initialY, buttonSize, buttonSize)];
    self.floatWindow.windowLevel = UIWindowLevelStatusBar + 100;
    self.floatWindow.backgroundColor = [UIColor clearColor];
    self.floatWindow.hidden = NO;

    self.floatButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.floatButton.frame = self.floatWindow.bounds;
    self.floatButton.backgroundColor = [UIColor colorWithRed:0.0 green:0.5 blue:1.0 alpha:0.85];
    self.floatButton.layer.cornerRadius = buttonSize / 2.0;
    self.floatButton.layer.borderWidth = 2.0;
    self.floatButton.layer.borderColor = [UIColor whiteColor].CGColor;
    [self.floatButton setTitle:@"✨" forState:UIControlStateNormal];
    self.floatButton.titleLabel.font = [UIFont systemFontOfSize:20];
    [self.floatButton addTarget:self action:@selector(handleButtonTap) forControlEvents:UIControlEventTouchUpInside];

    // 拖动手势
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self.floatButton addGestureRecognizer:pan];

    [self.floatWindow addSubview:self.floatButton];

    WVBLog(@"float button setup complete at frame: %@", NSStringFromCGRect(self.floatWindow.frame));
}

- (void)handleButtonTap {
    WVBLog(@"float button tapped");
    [self showSettings];
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    CGPoint translation = [pan translationInView:self.floatWindow];
    CGPoint newCenter = CGPointMake(self.floatWindow.center.x + translation.x,
                                      self.floatWindow.center.y + translation.y);

    // 限制在屏幕范围内
    CGRect screenBounds = [UIScreen mainScreen].bounds;
    CGFloat halfWidth = self.floatWindow.bounds.size.width / 2.0;
    CGFloat halfHeight = self.floatWindow.bounds.size.height / 2.0;
    newCenter.x = MAX(halfWidth, MIN(screenBounds.size.width - halfWidth, newCenter.x));
    newCenter.y = MAX(halfHeight + 40, MIN(screenBounds.size.height - halfHeight - 40, newCenter.y));

    self.floatWindow.center = newCenter;
    [pan setTranslation:CGPointZero inView:self.floatWindow];
}

- (void)showSettings {
    WVBLog(@"showing settings");

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL mirrorEnabled = [defaults boolForKey:kSettingKeyMirror];
    BOOL beautyEnabled = [defaults boolForKey:kSettingKeyBeauty];
    CGFloat whitenLevel = [defaults floatForKey:kSettingKeyWhiten];
    CGFloat smoothLevel = [defaults floatForKey:kSettingKeySmooth];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"微信视频美颜助手"
                                                                     message:[NSString stringWithFormat:@"镜像: %@ | 美颜: %@\n美白: %.0f%% | 磨皮: %.0f%%",
                                                                              mirrorEnabled ? @"开" : @"关",
                                                                              beautyEnabled ? @"开" : @"关",
                                                                              whitenLevel * 100,
                                                                              smoothLevel * 100]
                                                              preferredStyle:UIAlertControllerStyleActionSheet];

    [alert addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"视频镜像: %@", mirrorEnabled ? @"✅ 开" : @"❌ 关"]
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [self toggleMirror];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"视频美颜: %@", beautyEnabled ? @"✅ 开" : @"❌ 关"]
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [self toggleBeauty];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"美白强度 +10%"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        CGFloat level = [defaults floatForKey:kSettingKeyWhiten];
        level = MIN(1.0, level + 0.1);
        [defaults setFloat:level forKey:kSettingKeyWhiten];
        [defaults synchronize];
        WVBLog(@"whiten level set to: %.1f", level);
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"美白强度 -10%"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        CGFloat level = [defaults floatForKey:kSettingKeyWhiten];
        level = MAX(0.0, level - 0.1);
        [defaults setFloat:level forKey:kSettingKeyWhiten];
        [defaults synchronize];
        WVBLog(@"whiten level set to: %.1f", level);
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"磨皮强度 +10%"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        CGFloat level = [defaults floatForKey:kSettingKeySmooth];
        level = MIN(1.0, level + 0.1);
        [defaults setFloat:level forKey:kSettingKeySmooth];
        [defaults synchronize];
        WVBLog(@"smooth level set to: %.1f", level);
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"磨皮强度 -10%"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        CGFloat level = [defaults floatForKey:kSettingKeySmooth];
        level = MAX(0.0, level - 0.1);
        [defaults setFloat:level forKey:kSettingKeySmooth];
        [defaults synchronize];
        WVBLog(@"smooth level set to: %.1f", level);
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"关闭"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    // iPad 适配
    alert.popoverPresentationController.sourceView = self.floatButton;
    alert.popoverPresentationController.sourceRect = self.floatButton.bounds;

    UIViewController *rootVC = self.floatWindow.rootViewController;
    if (!rootVC) {
        rootVC = [[UIViewController alloc] init];
        self.floatWindow.rootViewController = rootVC;
    }
    [rootVC presentViewController:alert animated:YES completion:nil];
}

- (void)toggleMirror {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL current = [defaults boolForKey:kSettingKeyMirror];
    [defaults setBool:!current forKey:kSettingKeyMirror];
    [defaults synchronize];
    WVBLog(@"mirror toggled: %@ -> %@", current ? @"ON" : @"OFF", !current ? @"ON" : @"OFF");
}

- (void)toggleBeauty {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL current = [defaults boolForKey:kSettingKeyBeauty];
    [defaults setBool:!current forKey:kSettingKeyBeauty];
    [defaults synchronize];
    WVBLog(@"beauty toggled: %@ -> %@", current ? @"ON" : @"OFF", !current ? @"ON" : @"OFF");
}

@end

#pragma mark - Hook AVCaptureConnection（视频镜像）

%hook AVCaptureConnection

- (void)setVideoMirrored:(BOOL)videoMirrored {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL mirrorEnabled = [defaults boolForKey:kSettingKeyMirror];

    if (mirrorEnabled) {
        // 判断是否是前置摄像头
        BOOL isFrontCamera = NO;
        @try {
            AVCaptureInputPort *port = [self inputPorts].firstObject;
            if (port) {
                AVCaptureDevice *device = [port device];
                if (device && device.position == AVCaptureDevicePositionFront) {
                    isFrontCamera = YES;
                }
            }
        } @catch (NSException *e) {
            WVBLog(@"EXCEPTION checking front camera: %@", e);
        }

        if (isFrontCamera) {
            WVBLog(@"setVideoMirrored forced to YES (front camera, mirror enabled)");
            %orig(YES);
            return;
        }
    }

    %orig(videoMirrored);
}

%end

#pragma mark - Hook AVCaptureVideoDataOutput（美颜帧处理）

%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate queue:(dispatch_queue_t)queue {
    WVBLog(@"setSampleBufferDelegate called, delegate class: %@", NSStringFromClass([delegate class]));

    if (delegate) {
        WVBVideoFrameHandler *handler = [WVBVideoFrameHandler sharedHandler];
        handler.originalDelegate = delegate;
        WVBLog(@"original delegate saved, using WVBVideoFrameHandler as proxy");
        %orig(handler, queue);
    } else {
        WVBLog(@"delegate is nil, passing through");
        %orig(delegate, queue);
    }
}

%end

#pragma mark - Hook UIApplication（启动时设置悬浮按钮）

%hook UIApplication

- (void)applicationDidBecomeActive:(UIApplication *)application {
    %orig;
    WVBLog(@"applicationDidBecomeActive, setting up float button");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[WVBManager sharedManager] setupFloatButton];
    });
}

%end

#pragma mark - 构造函数

static void __attribute__((constructor)) WVBInitialize(void) {
    WVBLog(@"========================================");
    WVBLog(@"WeChatVideoBeauty v1.0 LOADED");
    WVBLog(@"========================================");

    // 初始化默认设置
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

    WVBLog(@"default settings loaded: mirror=%d, beauty=%d, whiten=%.1f, smooth=%.1f",
           [defaults boolForKey:kSettingKeyMirror],
           [defaults boolForKey:kSettingKeyBeauty],
           [defaults floatForKey:kSettingKeyWhiten],
           [defaults floatForKey:kSettingKeySmooth]);
}
