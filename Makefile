APP_NAME := CasRec
BUILD_DIR := .build
APP_BUNDLE := $(APP_NAME).app
CONTENTS := $(APP_BUNDLE)/Contents
MACOS_DIR := $(CONTENTS)/MacOS

.PHONY: build bundle run clean

build:
	swift build

bundle:
	swift build -c release
	mkdir -p "$(MACOS_DIR)"
	cp "$(BUILD_DIR)/release/$(APP_NAME)" "$(MACOS_DIR)/$(APP_NAME)"
	cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	codesign --force -s - "$(APP_BUNDLE)"

run: bundle
	open "$(APP_BUNDLE)"

clean:
	rm -rf "$(BUILD_DIR)" "$(APP_BUNDLE)"
