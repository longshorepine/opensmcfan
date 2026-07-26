SDK := $(shell xcrun --sdk macosx --show-sdk-path)
SWIFTC := swiftc
SWIFT_FLAGS := -sdk $(SDK) -O -framework IOKit

BUILD_DIR := .build
BIN := $(BUILD_DIR)/mysmc

# Source files by module
CSMC_HEADER := Sources/CSMCTypes/include/smc_types.h
SMCKIT_SRCS := $(wildcard Sources/SMCKit/*.swift)
CORE_SRCS   := $(wildcard Sources/MySMCCore/*.swift)
CLI_SRCS    := $(wildcard Sources/mysmc/*.swift)

ALL_SWIFT := $(SMCKIT_SRCS) $(CORE_SRCS) $(CLI_SRCS)

.PHONY: all clean install

all: $(BIN)

$(BIN): $(ALL_SWIFT) $(CSMC_HEADER)
	@mkdir -p $(BUILD_DIR)
	$(SWIFTC) $(SWIFT_FLAGS) \
		-import-objc-header $(CSMC_HEADER) \
		-module-name mysmc \
		$(ALL_SWIFT) \
		-o $(BIN)
	@echo "Built: $(BIN)"

clean:
	rm -rf $(BUILD_DIR)

install: $(BIN)
	cp $(BIN) /usr/local/bin/mysmc
	@echo "Installed: /usr/local/bin/mysmc"

run: $(BIN)
	sudo $(BIN) status
