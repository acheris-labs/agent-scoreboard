APP := Scoreboard
BUILD_DIR := build
BUNDLE := $(BUILD_DIR)/$(APP).app
CONTENTS := $(BUNDLE)/Contents

.PHONY: all build app clean

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

clean:
	rm -rf .build "$(BUILD_DIR)"
