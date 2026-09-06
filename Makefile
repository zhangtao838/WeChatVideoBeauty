export ARCHS = arm64 arm64e
export TARGET = iphone:clang:latest:15.0
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WeChatVideoBeauty

WeChatVideoBeauty_FILES = Tweak.xm
WeChatVideoBeauty_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable
WeChatVideoBeauty_FRAMEWORKS = UIKit AVFoundation CoreImage CoreMedia QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
