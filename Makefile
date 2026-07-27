SDK       := $(shell xcrun --sdk macosx --show-sdk-path)
SWIFTC    := swiftc
SWIFT_FLAGS := -sdk $(SDK) -O -framework IOKit

BUILD_DIR := .build
DIST_DIR  := .dist
VERSION   := $(shell git describe --tags --always 2>/dev/null || echo "dev")

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

AGENT_PLIST := Resources/com.mysmc.app.plist
AGENT_DST   := /Library/LaunchAgents/com.mysmc.app.plist
LABEL       := com.mysmc.app

.PHONY: all cli app clean install run run-app \
        install-agent uninstall-agent package

all: cli app

# ── CLI ──────────────────────────────────────────────────────────────────────
cli: $(CLI_BIN)

$(CLI_BIN): $(COMMON_SRCS) $(CLI_SRCS) $(CSMC_HEADER)
	@mkdir -p $(BUILD_DIR)
	$(SWIFTC) $(SWIFT_FLAGS) \
		-import-objc-header $(CSMC_HEADER) \
		-module-name mysmc \
		$(COMMON_SRCS) $(CLI_SRCS) \
		-o $(CLI_BIN)
	@echo "Built: $(CLI_BIN)"

# ── GUI App ──────────────────────────────────────────────────────────────────
# Security framework is required for AuthorizationExecuteWithPrivileges
# (privilege elevation at first launch).
app: $(APP_BIN)

$(APP_BIN): $(COMMON_SRCS) $(APP_SRCS) $(CSMC_HEADER) Resources/Info.plist Resources/AppIcon.icns
	@mkdir -p $(APP_DIR)/MacOS $(APP_DIR)/Resources
	$(SWIFTC) $(SWIFT_FLAGS) -framework AppKit -framework Security \
		-import-objc-header $(CSMC_HEADER) \
		-module-name MySMC \
		$(COMMON_SRCS) $(APP_SRCS) \
		-o $(APP_BIN)
	@cp Resources/Info.plist $(APP_DIR)/
	@cp Resources/AppIcon.icns $(APP_DIR)/Resources/
	@echo "Built: $(BUILD_DIR)/MySMC.app"

# ── Run ──────────────────────────────────────────────────────────────────────
run: cli
	sudo $(CLI_BIN) status

# Direct binary invocation — 'sudo open' spawns via launchd as the user (no root).
run-app: app
	sudo $(APP_BIN)

# ── Install CLI ──────────────────────────────────────────────────────────────
install: cli
	cp $(CLI_BIN) /usr/local/bin/mysmc
	@echo "Installed: /usr/local/bin/mysmc"

# ── LaunchAgent (auto-start as root on login) ────────────────────────────────
# Installs a /Library/LaunchAgents plist that launches MySMC as root
# whenever the user logs in — no sudo required at launch after this.
install-agent: app
	@[ "$$EUID" = "0" ] || (echo "Run as root: sudo make install-agent" && exit 1)
	@echo "Installing MySMC.app → /Applications/MySMC.app"
	@rm -rf /Applications/MySMC.app
	@cp -R $(BUILD_DIR)/MySMC.app /Applications/MySMC.app
	@chown -R root:wheel /Applications/MySMC.app
	@chmod -R 755 /Applications/MySMC.app
	@echo "Installing LaunchAgent → $(AGENT_DST)"
	@cp $(AGENT_PLIST) $(AGENT_DST)
	@chown root:wheel $(AGENT_DST)
	@chmod 644 $(AGENT_DST)
	@CONSOLE_UID=$$(stat -f '%u' /dev/console 2>/dev/null || id -u); \
	 launchctl bootstrap "gui/$$CONSOLE_UID" $(AGENT_DST) 2>/dev/null \
	   || launchctl load $(AGENT_DST) 2>/dev/null || true
	@echo "Done — MySMC will now start automatically on login."

uninstall-agent:
	@[ "$$EUID" = "0" ] || (echo "Run as root: sudo make uninstall-agent" && exit 1)
	@CONSOLE_UID=$$(stat -f '%u' /dev/console 2>/dev/null || id -u); \
	 launchctl bootout "gui/$$CONSOLE_UID" $(AGENT_DST) 2>/dev/null \
	   || launchctl unload $(AGENT_DST) 2>/dev/null || true
	@rm -f $(AGENT_DST)
	@pkill -f "MySMC.app/Contents/MacOS/MySMC" 2>/dev/null || true
	@rm -rf /Applications/MySMC.app
	@echo "MySMC uninstalled."

# ── Package (DMG) ────────────────────────────────────────────────────────────
# Creates .dist/MySMC-<version>.dmg containing the app + install scripts.
package: all
	@echo "Packaging MySMC $(VERSION)..."
	@rm -rf $(DIST_DIR)/staging
	@mkdir -p $(DIST_DIR)/staging
	@cp -R $(BUILD_DIR)/MySMC.app $(DIST_DIR)/staging/
	@cp scripts/install.sh $(DIST_DIR)/staging/
	@cp scripts/uninstall.sh $(DIST_DIR)/staging/
	@chmod +x $(DIST_DIR)/staging/install.sh $(DIST_DIR)/staging/uninstall.sh
	@hdiutil create \
		-volname "MySMC $(VERSION)" \
		-srcfolder $(DIST_DIR)/staging \
		-ov -format UDZO \
		$(DIST_DIR)/MySMC-$(VERSION).dmg
	@rm -rf $(DIST_DIR)/staging
	@echo "Packaged: $(DIST_DIR)/MySMC-$(VERSION).dmg"

# ── Clean ────────────────────────────────────────────────────────────────────
clean:
	rm -rf $(BUILD_DIR) $(DIST_DIR)
