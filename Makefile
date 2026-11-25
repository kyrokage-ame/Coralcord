TARGET = iphone:clang:15.6:15.0
ARCHS = arm64
PACKAGE_FORMAT = ipa
include $(THEOS)/makefiles/common.mk
APPLICATION_NAME = Coralcord
Coralcord_FILES = $(wildcard Sources/Cordial/*.swift) Sources/Cordial/CoralcordDAVEBridge.mm
Coralcord_FRAMEWORKS = UIKit Security AVFoundation Network UserNotifications
Coralcord_CFLAGS += -DDAVE_STATIC -I$(THEOS_PROJECT_DIR)/Vendor/libdave/include
Coralcord_CXXFLAGS += -std=c++17 -DDAVE_STATIC -I$(THEOS_PROJECT_DIR)/Vendor/libdave/include
Coralcord_LDFLAGS += -Wl,-force_load,$(THEOS_PROJECT_DIR)/Vendor/opus/lib/libopus-ios-arm64.a
DAVE_LIB_DIR = $(THEOS_PROJECT_DIR)/Vendor/libdave/lib/arm64
Coralcord_LDFLAGS += $(DAVE_LIB_DIR)/libdave.a
Coralcord_LDFLAGS += $(DAVE_LIB_DIR)/libmlspp.a
Coralcord_LDFLAGS += $(DAVE_LIB_DIR)/libhpke.a
Coralcord_LDFLAGS += $(DAVE_LIB_DIR)/libtls_syntax.a
Coralcord_LDFLAGS += $(DAVE_LIB_DIR)/libbytes.a
Coralcord_LDFLAGS += $(DAVE_LIB_DIR)/libcrypto.a
Coralcord_LDFLAGS += -lc++ -lz
Coralcord_SWIFT_VERSION = 5
Coralcord_SWIFT_BRIDGING_HEADER = Sources/Cordial/Coralcord-Bridging-Header.h
Coralcord_RESOURCE_DIRS = Resources

.PHONY: ensure-opus ensure-dave
before-all:: ensure-opus ensure-dave
ensure-opus:
	@if [ ! -f "$(THEOS_PROJECT_DIR)/Vendor/opus/lib/libopus-ios-arm64.a" ]; then \
		"$(THEOS_PROJECT_DIR)/scripts/build-opus-ios.sh"; \
	fi
ensure-dave:
	@for lib in libdave.a libmlspp.a libhpke.a libtls_syntax.a libbytes.a libcrypto.a; do \
		if [ ! -f "$(THEOS_PROJECT_DIR)/Vendor/libdave/lib/arm64/$$lib" ]; then \
			echo "Missing Vendor/libdave/lib/arm64/$$lib; run scripts/build-libdave-ios.sh" >&2; exit 1; \
		fi; \
	done

include $(THEOS_MAKE_PATH)/application.mk
