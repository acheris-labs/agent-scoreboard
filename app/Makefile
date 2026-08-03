APP := Scoreboard
BUILD_DIR := build
BUNDLE := $(BUILD_DIR)/$(APP).app
CONTENTS := $(BUNDLE)/Contents

# Developer ID signing + notarization for releases (CI passes these; local
# builds stay ad-hoc signed via `app`).
SIGN_ID ?=
NOTARY_PROFILE ?=
DMG := $(BUILD_DIR)/$(APP).dmg

.PHONY: all build app dmg clean

all: app

build:
	swift build -c release

app: build
	rm -rf "$(BUNDLE)"
	mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	cp "$$(swift build -c release --show-bin-path)/$(APP)" "$(CONTENTS)/MacOS/$(APP)"
	cp Info.plist "$(CONTENTS)/Info.plist"
	printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	codesign --force --sign - "$(BUNDLE)"
	@echo "Built $(BUNDLE)"

# Hardened-runtime Developer ID signature (required for notarization), then
# notarize + staple the DMG so Gatekeeper accepts it offline.
dmg: app
	@test -n "$(SIGN_ID)" || { echo "SIGN_ID is required"; exit 1; }
	@test -n "$(NOTARY_PROFILE)" || { echo "NOTARY_PROFILE is required"; exit 1; }
	codesign --force --options runtime --timestamp --sign "$(SIGN_ID)" "$(BUNDLE)"
	codesign --verify --strict --deep "$(BUNDLE)"
	hdiutil create -volname "$(APP)" -srcfolder "$(BUNDLE)" -ov -format UDZO "$(DMG)"
	xcrun notarytool submit "$(DMG)" --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple "$(DMG)"
	xcrun stapler validate "$(DMG)"
	@echo "Notarized $(DMG)"

clean:
	rm -rf .build "$(BUILD_DIR)"
