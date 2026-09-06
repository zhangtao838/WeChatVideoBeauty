export ARCHS = arm64 arm64e
export TARGET = iphone:clang:latest:15.0
# RootHide 方案（Dopamine-roothide / Relaxin 等）
export THEOS_PACKAGE_SCHEME ?= roothide
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WeChatVideoBeauty

WeChatVideoBeauty_FILES = Tweak.xm
WeChatVideoBeauty_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable
WeChatVideoBeauty_FRAMEWORKS = UIKit AVFoundation CoreImage CoreMedia QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
