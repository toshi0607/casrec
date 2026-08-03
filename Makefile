APP_NAME := CasRec
BUILD_DIR := .build
APP_BUNDLE := $(APP_NAME).app
CONTENTS := $(APP_BUNDLE)/Contents
MACOS_DIR := $(CONTENTS)/MacOS

# Swift Testing ships inside the Command Line Tools, but only a full Xcode tells SwiftPM
# where to find it, so plain `swift test` fails to compile (no module) and, if given only
# the framework path, fails to launch (no interop dylib on the rpath). XCTest is not in the
# Command Line Tools at all, which is why the suite is written against Swift Testing.
# This machine has no Xcode by design — see DESIGN.md §8.
DEVELOPER_DIR := /Library/Developer/CommandLineTools/Library/Developer
TEST_FLAGS := -Xswiftc -F -Xswiftc "$(DEVELOPER_DIR)/Frameworks" \
	-Xlinker -rpath -Xlinker "$(DEVELOPER_DIR)/Frameworks" \
	-Xlinker -rpath -Xlinker "$(DEVELOPER_DIR)/usr/lib"

.PHONY: build test bundle run clean

build:
	swift build

test:
	swift test $(TEST_FLAGS)

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
