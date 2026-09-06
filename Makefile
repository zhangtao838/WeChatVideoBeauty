export ARCHS = arm64 arm64e
export TARGET = iphone:clang:latest:15.0
# RootHide (Dopamine-roothide / Relaxin 等) 默认方案。
# 构建普通 rootless 版本:
#   make package THEOS_PACKAGE_SCHEME=rootless
export THEOS_PACKAGE_SCHEME ?= roothide
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WeChatVideoBeauty

WeChatVideoBeauty_FILES = Tweak.xm
WeChatVideoBeauty_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable
WeChatVideoBeauty_FRAMEWORKS = UIKit AVFoundation CoreImage CoreMedia QuartzCore
WeChatVideoBeauty_CODESIGN_FLAGS = -SEntitlements.plist

include $(THEOS_MAKE_PATH)/tweak.mk
