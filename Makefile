APP_NAME := CasRec
BUILD_DIR := .build
APP_BUNDLE := $(APP_NAME).app
CONTENTS := $(APP_BUNDLE)/Contents
MACOS_DIR := $(CONTENTS)/MacOS
RESOURCES_DIR := $(CONTENTS)/Resources

# Swift Testing ships inside the Command Line Tools, but only a full Xcode tells SwiftPM
# where to find it, so plain `swift test` fails to compile (no module) and, if given only
# the framework path, fails to launch (no interop dylib on the rpath). XCTest is not in the
# Command Line Tools at all, which is why the suite is written against Swift Testing.
# This machine has no Xcode by design — see DESIGN.md §8.
DEVELOPER_DIR := /Library/Developer/CommandLineTools/Library/Developer
ifneq ($(wildcard $(DEVELOPER_DIR)),)
TEST_FLAGS := -Xswiftc -F -Xswiftc "$(DEVELOPER_DIR)/Frameworks" \
	-Xlinker -rpath -Xlinker "$(DEVELOPER_DIR)/Frameworks" \
	-Xlinker -rpath -Xlinker "$(DEVELOPER_DIR)/usr/lib"
endif

# Ad-hoc signing ("-") changes the cdhash every build, which invalidates the
# screen-recording TCC grant on each rebuild (DESIGN.md §8). "CasRec Release" is a
# local self-signed code-signing certificate; a certificate-backed signature
# keeps the designated requirement stable so the grant survives rebuilds.
CODESIGN_IDENTITY ?= CasRec Release
ENTITLEMENTS := Resources/CasRec.entitlements

# 期待する designated requirement の leaf hash。リリース署名の取り違えを防ぐ。
# 証明書を作り直したらこの値も更新する(tasks/oss-distribution-spec.md §2.1)。
EXPECTED_LEAF := 4feed5cfc27c13bd9711823f1edd9a4ee2a96b44

VERSION ?= $(shell git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')
BUILD_NUMBER ?= $(shell git rev-list --count HEAD)

.PHONY: build test bundle run clean release

build:
	swift build

test:
	swift test $(TEST_FLAGS)

# The bundle is rebuilt from scratch every time. Overwriting in place would leave
# files from earlier builds inside CasRec.app, and `codesign --force` then seals
# them into the signature: `--verify --deep --strict` passes and the leftovers
# ship in the release ZIP undetected.
bundle:
	swift build -c release
	rm -rf "$(APP_BUNDLE)"
	mkdir -p "$(MACOS_DIR)" "$(RESOURCES_DIR)"
	cp "$(BUILD_DIR)/release/$(APP_NAME)" "$(MACOS_DIR)/$(APP_NAME)"
	cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	cp Resources/AppIcon.icns "$(RESOURCES_DIR)/AppIcon.icns"
	@if [ -n "$(VERSION)" ]; then \
		plutil -replace CFBundleShortVersionString -string "$(VERSION)" "$(CONTENTS)/Info.plist"; \
		plutil -replace CFBundleVersion -string "$(BUILD_NUMBER)" "$(CONTENTS)/Info.plist"; \
	fi
	codesign --force --options runtime --timestamp \
		--entitlements "$(ENTITLEMENTS)" \
		-s "$(CODESIGN_IDENTITY)" "$(APP_BUNDLE)"

run: bundle
	open "$(APP_BUNDLE)"

release:
	@if [ -z "$(VERSION)" ]; then \
		echo "ERROR: VERSION is required. Use: make release VERSION=x.y.z"; \
		exit 1; \
	fi
	@if [ "$(CODESIGN_IDENTITY)" = "-" ]; then \
		echo "ERROR: CODESIGN_IDENTITY=- is not allowed for releases."; \
		exit 1; \
	fi
	$(MAKE) bundle VERSION="$(VERSION)" BUILD_NUMBER="$(BUILD_NUMBER)" CODESIGN_IDENTITY="$(CODESIGN_IDENTITY)"
	codesign --verify --deep --strict --verbose=2 "$(APP_BUNDLE)"
	@if ! codesign -d -r- "$(APP_BUNDLE)" 2>&1 | grep -q "$(EXPECTED_LEAF)"; then \
		echo "ERROR: designated requirement does not contain expected leaf $(EXPECTED_LEAF)."; \
		exit 1; \
	fi
	mkdir -p dist
	rm -f "dist/CasRec-$(VERSION).zip" "dist/checksums.txt"
	ditto -c -k --keepParent "$(APP_BUNDLE)" "dist/CasRec-$(VERSION).zip"
	cd dist && shasum -a 256 "CasRec-$(VERSION).zip" > checksums.txt
	@echo "Generated release artifacts:"
	@echo "  dist/CasRec-$(VERSION).zip"
	@echo "  dist/checksums.txt"
	@cat dist/checksums.txt

clean:
	rm -rf "$(BUILD_DIR)" "$(APP_BUNDLE)" dist
