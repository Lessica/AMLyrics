TARGET := iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES = Music

include $(THEOS)/makefiles/common.mk

TWEAK_NAME += AMLyrics

AMLyrics_FILES += AMLyrics.xm
AMLyrics_CFLAGS += -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
