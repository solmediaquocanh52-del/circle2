THEOS_PACKAGE_SCHEME ?= rootless
TARGET := iphone:clang:latest:14.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = CircleSwitcherPrefs

CircleSwitcherPrefs_FILES = CSRootListController.m
CircleSwitcherPrefs_FRAMEWORKS = UIKit QuartzCore
CircleSwitcherPrefs_PRIVATE_FRAMEWORKS = Preferences
CircleSwitcherPrefs_INSTALL_PATH = /Library/PreferenceBundles
CircleSwitcherPrefs_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-error

include $(THEOS_MAKE_PATH)/bundle.mk
