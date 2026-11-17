TARGET := iphone:clang:latest:14.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CircleSwitcher
CircleSwitcher_FILES = Tweak.x
CircleSwitcher_CFLAGS = -fobjc-arc -O3 -Wno-deprecated-declarations -Wno-error
CircleSwitcher_FRAMEWORKS = UIKit QuartzCore Metal AudioToolbox

SUBPROJECTS += prefs

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/aggregate.mk
