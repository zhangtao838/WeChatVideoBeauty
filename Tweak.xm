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

@interface WVBManager : NSObject
@property (nonatomic, strong) UIWindow *floatWindow;
@property (nonatomic, strong) UIButton *floatButton;
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

    CGFloat buttonSize = 56.0;
    CGFloat screenWidth = screenBounds.size.width;
    CGFloat screenHeight = screenBounds.size.height;
    CGFloat initialX = screenWidth - buttonSize - 20;
    CGFloat initialY = 160;

    // 如果屏幕很宽（iPad），让按钮靠右边缘，不要太靠边
    if (screenWidth > 768) {
        initialX = screenWidth - buttonSize - 30;
        initialY = 180;
    }

    wvbLog(@"screen: %@ (w=%.0f h=%.0f), button pos: (%.0f, %.0f)",
           NSStringFromCGRect(screenBounds), screenWidth, screenHeight, initialX, initialY);

    self.floatWindow = [[UIWindow alloc] initWithFrame:CGRectMake(initialX, initialY, buttonSize, buttonSize)];
    self.floatWindow.windowLevel = UIWindowLevelStatusBar + 2000;
    self.floatWindow.backgroundColor = [UIColor clearColor];
    self.floatWindow.rootViewController = [[UIViewController alloc] init];
    self.floatWindow.rootViewController.view.backgroundColor = [UIColor clearColor];
    self.floatWindow.hidden = NO;
    self.floatWindow.clipsToBounds = NO;
    [self.floatWindow makeKeyAndVisible];

    wvbLog(@"floatWindow created: frame=%@ level=%.0f hidden=%@",
           NSStringFromCGRect(self.floatWindow.frame),
           self.floatWindow.windowLevel,
           self.floatWindow.hidden ? @"YES" : @"NO");

    self.floatButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.floatButton.frame = CGRectMake(0, 0, buttonSize, buttonSize);
    self.floatButton.backgroundColor = [UIColor colorWithRed:0.18 green:0.49 blue:0.96 alpha:1.0];
    self.floatButton.layer.cornerRadius = buttonSize / 2.0;
    self.floatButton.layer.borderWidth = 3.0;
    self.floatButton.layer.borderColor = [UIColor whiteColor].CGColor;
    self.floatButton.layer.shadowColor = [UIColor blackColor].CGColor;
    self.floatButton.layer.shadowOffset = CGSizeMake(0, 3);
    self.floatButton.layer.shadowOpacity = 0.4;
    self.floatButton.layer.shadowRadius = 6;
    self.floatButton.clipsToBounds = NO;
    [self.floatButton setTitle:@"美颜" forState:UIControlStateNormal];
    self.floatButton.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    self.floatButton.titleLabel.textColor = [UIColor whiteColor];
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

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL mirrorEnabled = [defaults boolForKey:kSettingKeyMirror];
    BOOL beautyEnabled = [defaults boolForKey:kSettingKeyBeauty];
    CGFloat whitenLevel = [defaults floatForKey:kSettingKeyWhiten];
    CGFloat smoothLevel = [defaults floatForKey:kSettingKeySmooth];

    // iPad 上用 alert 样式，避免 action sheet 变成 popover 只显示一小块
    UIAlertControllerStyle style = UIAlertControllerStyleAlert;
    if (UIUserInterfaceIdiomPad != UI_USER_INTERFACE_IDIOM()) {
        style = UIAlertControllerStyleActionSheet;
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"✨ 微信视频美颜助手"
                                                                   message:[NSString stringWithFormat:@"镜像: %@  |  美颜: %@\n美白: %.0f%%  |  磨皮: %.0f%%",
                                                                            mirrorEnabled ? @"✅开" : @"❌关",
                                                                            beautyEnabled ? @"✅开" : @"❌关",
                                                                            whitenLevel * 100,
                                                                            smoothLevel * 100]
                                                            preferredStyle:style];

    [alert addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"📷 视频镜像: %@", mirrorEnabled ? @"开" : @"关"]
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [self toggleMirror];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self showSettings];
        });
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"💄 视频美颜: %@", beautyEnabled ? @"开" : @"关"]
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [self toggleBeauty];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self showSettings];
        });
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"⬆️ 美白 +10%"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        CGFloat level = [defaults floatForKey:kSettingKeyWhiten];
        level = MIN(1.0, level + 0.1);
        [defaults setFloat:level forKey:kSettingKeyWhiten];
        [defaults synchronize];
        wvbLog(@"whiten +10%% -> %.1f", level);
        [self showSettings];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"⬇️ 美白 -10%"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        CGFloat level = [defaults floatForKey:kSettingKeyWhiten];
        level = MAX(0.0, level - 0.1);
        [defaults setFloat:level forKey:kSettingKeyWhiten];
        [defaults synchronize];
        wvbLog(@"whiten -10%% -> %.1f", level);
        [self showSettings];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"⬆️ 磨皮 +10%"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        CGFloat level = [defaults floatForKey:kSettingKeySmooth];
        level = MIN(1.0, level + 0.1);
        [defaults setFloat:level forKey:kSettingKeySmooth];
        [defaults synchronize];
        wvbLog(@"smooth +10%% -> %.1f", level);
        [self showSettings];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"⬇️ 磨皮 -10%"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        CGFloat level = [defaults floatForKey:kSettingKeySmooth];
        level = MAX(0.0, level - 0.1);
        [defaults setFloat:level forKey:kSettingKeySmooth];
        [defaults synchronize];
        wvbLog(@"smooth -10%% -> %.1f", level);
        [self showSettings];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"❌ 关闭"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    if (style == UIAlertControllerStyleActionSheet) {
        alert.popoverPresentationController.sourceView = self.floatButton;
        alert.popoverPresentationController.sourceRect = self.floatButton.bounds;
    }

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
