ARCHS = arm64 arm64e
TARGET = iphone:clang:26.5:15.0
INSTALL_TARGET_PROCESSES = WeChat

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WeChatVideoBeauty

WeChatVideoBeauty_FILES = Tweak.xm
WeChatVideoBeauty_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
WeChatVideoBeauty_FRAMEWORKS = UIKit AVFoundation CoreImage CoreMedia QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
