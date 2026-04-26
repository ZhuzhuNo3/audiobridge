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

SRC := src/main.m src/ABDeviceQuery.m src/ABSystemDefaultIO.m src/ABPassThroughEngine.m src/ABStdoutPCMWriter.m src/ABDeviceRecoveryCoordinator.m
OBJ := $(addprefix $(BUILD_DIR)/,$(notdir $(SRC:.m=.o)))
TEST_BUILD_DIR := build/tests
UNIT_TEST_SRC := tests/unit/ABDeviceRecoveryCoordinatorTests.m
UNIT_TEST_BIN := $(TEST_BUILD_DIR)/ABDeviceRecoveryCoordinatorTests
DEBOUNCE_TEST_SRC := tests/unit/ABSystemDefaultIODebounceTests.m
DEBOUNCE_TEST_BIN := $(TEST_BUILD_DIR)/ABSystemDefaultIODebounceTests
WRITER_BRIDGE_TEST_SRC := tests/unit/ABStdoutPCMWriterBridgeTests.m
WRITER_BRIDGE_TEST_BIN := $(TEST_BUILD_DIR)/ABStdoutPCMWriterBridgeTests
PASSTHROUGH_CONTRACT_TEST_SRC := tests/unit/ABPassThroughEngineContractTests.m
PASSTHROUGH_CONTRACT_TEST_BIN := $(TEST_BUILD_DIR)/ABPassThroughEngineContractTests
STDOUT_CONTRACT_TEST_SRC := tests/unit/ABStdoutPCMWriterContractTests.m
STDOUT_CONTRACT_TEST_BIN := $(TEST_BUILD_DIR)/ABStdoutPCMWriterContractTests

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
	rm -rf $(TEST_BUILD_DIR)

.PHONY: clean all all-arch test-unit test-unit-ABDeviceRecoveryCoordinatorTests test-unit-ABSystemDefaultIODebounceTests test-unit-ABStdoutPCMWriterBridgeTests test-unit-ABPassThroughEngineContractTests test-unit-ABStdoutPCMWriterContractTests

# Build both Apple silicon and Intel slices (from an Apple host with Xcode SDK; used in CI).
all-arch: clean
	$(MAKE) ARCH=arm64 all
	$(MAKE) ARCH=x86_64 all

test-unit: test-unit-ABDeviceRecoveryCoordinatorTests test-unit-ABSystemDefaultIODebounceTests test-unit-ABStdoutPCMWriterBridgeTests test-unit-ABPassThroughEngineContractTests test-unit-ABStdoutPCMWriterContractTests

test-unit-ABDeviceRecoveryCoordinatorTests: $(UNIT_TEST_BIN)
	$(UNIT_TEST_BIN)

$(UNIT_TEST_BIN): $(UNIT_TEST_SRC) src/ABDeviceRecoveryCoordinator.m src/ABPassThroughEngine.m src/ABStdoutPCMWriter.m src/ABSystemDefaultIO.m
	mkdir -p $(TEST_BUILD_DIR)
	$(CC) $(CFLAGS) $(OBJCFLAGS) -Isrc \
		$(UNIT_TEST_SRC) src/ABDeviceRecoveryCoordinator.m src/ABPassThroughEngine.m src/ABStdoutPCMWriter.m \
		-o $@ $(LDFLAGS)

test-unit-ABSystemDefaultIODebounceTests: $(DEBOUNCE_TEST_BIN)
	$(DEBOUNCE_TEST_BIN)

$(DEBOUNCE_TEST_BIN): $(DEBOUNCE_TEST_SRC) src/ABSystemDefaultIO.m
	mkdir -p $(TEST_BUILD_DIR)
	$(CC) $(CFLAGS) $(OBJCFLAGS) -Isrc \
		$(DEBOUNCE_TEST_SRC) src/ABSystemDefaultIO.m \
		-o $@ $(LDFLAGS)

test-unit-ABStdoutPCMWriterBridgeTests: $(WRITER_BRIDGE_TEST_BIN)
	$(WRITER_BRIDGE_TEST_BIN)

$(WRITER_BRIDGE_TEST_BIN): $(WRITER_BRIDGE_TEST_SRC) src/ABStdoutPCMWriter.m
	mkdir -p $(TEST_BUILD_DIR)
	$(CC) $(CFLAGS) $(OBJCFLAGS) -Isrc \
		$(WRITER_BRIDGE_TEST_SRC) src/ABStdoutPCMWriter.m \
		-o $@ $(LDFLAGS)

test-unit-ABPassThroughEngineContractTests: $(PASSTHROUGH_CONTRACT_TEST_BIN)
	$(PASSTHROUGH_CONTRACT_TEST_BIN)

$(PASSTHROUGH_CONTRACT_TEST_BIN): $(PASSTHROUGH_CONTRACT_TEST_SRC) src/ABPassThroughEngine.m
	mkdir -p $(TEST_BUILD_DIR)
	$(CC) $(CFLAGS) $(OBJCFLAGS) -Isrc \
		$(PASSTHROUGH_CONTRACT_TEST_SRC) src/ABPassThroughEngine.m \
		-o $@ $(LDFLAGS)

test-unit-ABStdoutPCMWriterContractTests: $(STDOUT_CONTRACT_TEST_BIN)
	$(STDOUT_CONTRACT_TEST_BIN)

$(STDOUT_CONTRACT_TEST_BIN): $(STDOUT_CONTRACT_TEST_SRC) src/ABStdoutPCMWriter.m
	mkdir -p $(TEST_BUILD_DIR)
	$(CC) $(CFLAGS) $(OBJCFLAGS) -Isrc \
		$(STDOUT_CONTRACT_TEST_SRC) src/ABStdoutPCMWriter.m \
		-o $@ $(LDFLAGS)
