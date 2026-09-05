# WeChatVideoBeauty

**微信视频通话镜像 + 基础美颜插件（v1.1）**

- ✅ 视频通话镜像（前置摄像头画面不翻转）
- ✅ 基础美颜（美白 + 磨皮，强度可调）
- ✅ 悬浮按钮，视频通话中随时调节
- ✅ 只注入微信，不影响其他应用

**适配：** iOS 15.0 ~ 26.x，rootless / RootHide，微信最新版

---

## 一、上传到 GitHub 自动编译

1. GitHub 新建仓库（如 `WeChatVideoBeauty`）
2. 把压缩包里**所有文件**（含 `.github` 文件夹）上传到仓库根目录
3. 等 Actions 编译完成（2~3 分钟）
4. 点进 workflow，下载 Artifacts 里的 deb
5. Filza 安装 deb，杀微信后台重开

---

## 二、使用方法

### 悬浮按钮
安装后微信界面会出现一个**蓝色圆形悬浮按钮**（✨图标），可以拖动到任意位置。

### 点击悬浮按钮弹出设置
| 选项 | 作用 |
|---|---|
| 视频镜像: 开/关 | 前置摄像头画面是否镜像翻转 |
| 视频美颜: 开/关 | 是否启美白磨皮 |
| 美白强度 ±10% | 调整美白程度 |
| 磨皮强度 ±10% | 调整磨皮程度 |

### 默认设置
- 镜像：**开启**
- 美颜：**关闭**（需要手动开）
- 美白：50%
- 磨皮：50%

---

## 三、v1.1 更新说明

- 修复编译错误：`AVCaptureInputPort` 没有 `device` 方法，改为通过 `port.input` 获取 `AVCaptureDeviceInput` 再取 `device`

---

## 四、查看调试日志

代码里加了详细日志，出问题先看日志。

### 手机端
安装 **OSLogger**，进程选 **WeChat**，关键词输入 `WeChatVideoBeauty`。

### 电脑端
```bash
idevicesyslog | findstr WeChatVideoBeauty
```

---

## 五、常见问题

### Q: 悬浮按钮不出现？
A: 看日志有没有 `WeChatVideoBeauty v1.1 LOADED`。如果没有，说明插件没注入成功。

### Q: 镜像不生效？
A: 看日志有没有 `setVideoMirrored forced to YES`。如果没有，检查镜像开关是否打开。

### Q: 美颜不生效？
A: 看日志有没有 `setSampleBufferDelegate called`。如果没有，说明微信版本可能用了非标准视频管线，美颜暂不支持。镜像功能仍然可用。

### Q: 视频通话卡顿？
A: 美颜是实时视频帧处理，会增加 CPU 负载。卡顿的话降低强度或关闭美颜。

---

## 六、文件说明

```
WeChatVideoBeauty/
├── .github/workflows/build.yml   # GitHub Actions 自动编译
├── .gitignore
├── Makefile                       # Theos 编译配置
├── control                        # deb 包信息
├── WeChatVideoBeauty.plist        # 注入配置（只注入微信）
├── Tweak.xm                       # 核心代码
└── README.md
```

**有问题把 `[WeChatVideoBeauty]` 开头的日志发我。**
