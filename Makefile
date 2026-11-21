TARGET := iphone:clang:latest:15.0
ARCHS := arm64 arm64e

INSTALL_TARGET_PROCESSES := SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AttribClean

AttribClean_FILES = \
    Sources/Tweak.xm \
    Sources/ACPrefs.m \
    Sources/ACIdentity.m \
    Sources/ACCleaner.m \
    Sources/ACLog.m

AttribClean_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function
AttribClean_FRAMEWORKS = Foundation UIKit Security
AttribClean_WEAK_FRAMEWORKS = AdSupport AppTrackingTransparency
AttribClean_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += prefsapp
include $(THEOS_MAKE_PATH)/aggregate.mk

after-install::
	@if [ -x "$$(command -v sbreload)" ]; then sbreload >/dev/null 2>&1 || true; fi
