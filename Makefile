# Optional: ARCH=arm64 or ARCH=x86_64 for a slice-specific build (e.g. CI artifacts).
# Default: native single-arch binary at build/audiobridge
ifneq ($(strip $(ARCH)),)
  BUILD_DIR := build/$(ARCH)
  ARCHFLAG := -arch $(ARCH)
else
  BUILD_DIR := build
  ARCHFLAG :=
endif

TARGET := $(BUILD_DIR)/audiobridge

SRC := src/main.m src/ABDeviceQuery.m src/ABSystemDefaultIO.m src/ABPassThroughEngine.m src/ABStdoutPCMWriter.m
OBJ := $(addprefix $(BUILD_DIR)/,$(notdir $(SRC:.m=.o)))

CFLAGS := -fobjc-arc -O2 -Wall -Wextra -mmacosx-version-min=12.0 $(ARCHFLAG)
OBJCFLAGS := $(CFLAGS)
LDFLAGS := -mmacosx-version-min=12.0 $(ARCHFLAG) -framework Foundation -framework AVFoundation -framework CoreAudio -framework AudioToolbox

all: $(TARGET)

$(TARGET): $(OBJ) | $(BUILD_DIR)
	$(CC) $(LDFLAGS) -o $@ $^

$(BUILD_DIR)/%.o: src/%.m | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(OBJCFLAGS) -c -o $@ $<

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

clean:
	rm -rf $(BUILD_DIR)

.PHONY: clean all all-arch

# Build both Apple silicon and Intel slices (from an Apple host with Xcode SDK; used in CI).
all-arch: clean
	$(MAKE) ARCH=arm64 all
	$(MAKE) ARCH=x86_64 all
