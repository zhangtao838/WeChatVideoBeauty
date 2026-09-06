# WeChatVideoBeauty

**微信视频通话镜像 + 基础美颜插件**

- ✅ 视频通话镜像（前置摄像头画面不翻转）
- ✅ 基础美颜（美白 + 磨皮，强度可调）
- ✅ 悬浮按钮，视频通话中随时调节
- ✅ 只注入微信，不影响其他应用
- ✅ 文件日志输出到 /tmp/wvb.log，方便调试

**适配：** iOS 15.0 ~ 26.x，rootless / RootHide，微信最新版

---

## 安装

1. 把仓库所有文件上传到 GitHub
2. GitHub Actions 自动编译 deb（2-3分钟）
3. 下载 Artifacts 里的 deb
4. Filza 安装 deb，杀微信重开

## 调试日志

安装后打开微信，进行任意操作，然后用以下方式查看日志：

### 手机查看
```bash
# NewTerm 或任何终端
cat /tmp/wvb.log
```

### 电脑查看
```bash
idevicesyslog | grep WeChatVideoBeauty
```

### 日志说明
- 蓝色圆形悬浮按钮不显示 → 看 `setupFloatButton` 相关日志
- 镜像不生效 → 看 `setVideoMirrored` 相关日志
- 美颜不生效 → 看 `setSampleBufferDelegate` 相关日志

---

## 文件说明

```
WeChatVideoBeauty/
├── .github/workflows/build.yml   # GitHub Actions 自动编译
├── .gitignore
├── Makefile                       # Theos 编译配置
├── control                        # deb 包信息
├── Entitlements.plist             # 代码签名权限
├── postinst                       # 安装后脚本（杀掉微信）
├── postrm                         # 卸载后清理日志
├── README.md
├── Tweak.xm                       # 核心代码
└── WeChatVideoBeauty.plist        # 注入配置（只注入微信）
```
