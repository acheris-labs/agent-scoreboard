APP := Scoreboard
BUILD_DIR := build
BUNDLE := $(BUILD_DIR)/$(APP).app
CONTENTS := $(BUNDLE)/Contents

# Developer ID signing + notarization for releases (CI passes these; local
# builds stay ad-hoc signed via `app`).
SIGN_ID ?=
NOTARY_PROFILE ?=
DMG := $(BUILD_DIR)/$(APP).dmg
ZIP := $(BUILD_DIR)/$(APP).zip

# The CLI ships inside the bundle so one artifact installs the whole product
# (the Homebrew cask symlinks it onto PATH). Compiled, not scripted: it runs
# on every Claude hook, and ~10ms of startup instead of ~250ms is the
# difference between hooking every tool call and not.
CLI := scoreboard-cli

.PHONY: all build app sign dmg zip release clean

all: app

build:
	swift build -c release

app: build
	rm -rf "$(BUNDLE)"
	mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	cp "$$(swift build -c release --show-bin-path)/$(APP)" "$(CONTENTS)/MacOS/$(APP)"
	cp Info.plist "$(CONTENTS)/Info.plist"
	printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	cp "$$(swift build -c release --show-bin-path)/$(CLI)" "$(CONTENTS)/Resources/scoreboard"
	codesign --force --sign - "$(BUNDLE)"
	@echo "Built $(BUNDLE)"

# Replace the ad-hoc signature with a hardened-runtime Developer ID one,
# which notarization requires.
#
# The embedded CLI is signed FIRST, then the bundle, which seals it. Order
# matters: signing only the bundle leaves the nested Mach-O unsigned and
# notarization rejects it ("not signed with a valid Developer ID
# certificate"). No --deep, which would re-sign the inner binary without
# these options.
sign: app
	@test -n "$(SIGN_ID)" || { echo "SIGN_ID is required"; exit 1; }
	@test -n "$(NOTARY_PROFILE)" || { echo "NOTARY_PROFILE is required"; exit 1; }
	codesign --force --options runtime --timestamp \
	  --sign "$(SIGN_ID)" "$(CONTENTS)/Resources/scoreboard"
	codesign --force --options runtime --timestamp --sign "$(SIGN_ID)" "$(BUNDLE)"
	codesign --verify --strict --deep "$(BUNDLE)"

# Notarize via a zip, then staple the ticket into the .app itself and re-zip
# so the archive the cask downloads carries the ticket. stapler works on the
# bundle, not the archive, which is why this zips twice.
zip: sign
	rm -f "$(ZIP)"
	ditto -c -k --keepParent "$(BUNDLE)" "$(ZIP)"
	xcrun notarytool submit "$(ZIP)" --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple "$(BUNDLE)"
	xcrun stapler validate "$(BUNDLE)"
	rm -f "$(ZIP)"
	ditto -c -k --keepParent "$(BUNDLE)" "$(ZIP)"
	@echo "Notarized $(ZIP)"

# DMG for humans who download from the releases page. Built from the already
# stapled bundle, then notarized and stapled in its own right.
dmg: zip
	hdiutil create -volname "$(APP)" -srcfolder "$(BUNDLE)" -ov -format UDZO "$(DMG)"
	xcrun notarytool submit "$(DMG)" --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple "$(DMG)"
	xcrun stapler validate "$(DMG)"
	@echo "Notarized $(DMG)"

# Everything a release publishes: stapled zip (cask) + stapled DMG (humans).
release: dmg

clean:
	rm -rf .build "$(BUILD_DIR)"
