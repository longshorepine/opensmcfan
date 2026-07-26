SDK := $(shell xcrun --sdk macosx --show-sdk-path)
SWIFTC := swiftc
SWIFT_FLAGS := -sdk $(SDK) -O -framework IOKit

BUILD_DIR := .build

# Source files
CSMC_HEADER := Sources/CSMCTypes/include/smc_types.h
SMCKIT_SRCS := $(wildcard Sources/SMCKit/*.swift)
CORE_SRCS   := $(wildcard Sources/MySMCCore/*.swift)
COMMON_SRCS := $(SMCKIT_SRCS) $(CORE_SRCS)

# CLI target
CLI_SRCS := $(wildcard Sources/mysmc/*.swift)
CLI_BIN  := $(BUILD_DIR)/mysmc

# GUI app target
APP_SRCS := $(wildcard Sources/App/*.swift)
APP_DIR  := $(BUILD_DIR)/MySMC.app/Contents
APP_BIN  := $(APP_DIR)/MacOS/MySMC

.PHONY: all cli app clean install run

all: cli app

# ── CLI ──────────────────────────────────────────────
cli: $(CLI_BIN)

$(CLI_BIN): $(COMMON_SRCS) $(CLI_SRCS) $(CSMC_HEADER)
	@mkdir -p $(BUILD_DIR)
	$(SWIFTC) $(SWIFT_FLAGS) \
		-import-objc-header $(CSMC_HEADER) \
		-module-name mysmc \
		$(COMMON_SRCS) $(CLI_SRCS) \
		-o $(CLI_BIN)
	@echo "Built: $(CLI_BIN)"

# ── GUI App ──────────────────────────────────────────
app: $(APP_BIN)

$(APP_BIN): $(COMMON_SRCS) $(APP_SRCS) $(CSMC_HEADER) Resources/Info.plist
	@mkdir -p $(APP_DIR)/MacOS $(APP_DIR)/Resources
	$(SWIFTC) $(SWIFT_FLAGS) -framework AppKit \
		-import-objc-header $(CSMC_HEADER) \
		-module-name MySMC \
		$(COMMON_SRCS) $(APP_SRCS) \
		-o $(APP_BIN)
	@cp Resources/Info.plist $(APP_DIR)/
	@echo "Built: $(BUILD_DIR)/MySMC.app"

# ── Utilities ────────────────────────────────────────
clean:
	rm -rf $(BUILD_DIR)

install: cli
	cp $(CLI_BIN) /usr/local/bin/mysmc
	@echo "Installed: /usr/local/bin/mysmc"

install-app: app
	cp -R $(BUILD_DIR)/MySMC.app /Applications/MySMC.app
	@echo "Installed: /Applications/MySMC.app"

run: cli
	sudo $(CLI_BIN) status

# 'sudo open' does NOT give the launched app root — launchd re-spawns as the user.
# Run the binary directly so the process inherits the sudo privilege.
run-app: app
	sudo $(APP_BIN)
