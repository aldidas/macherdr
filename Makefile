.PHONY: gen build run test kit-test uiux-test clean release install

CODE_SIGN_IDENTITY ?= Apple Development: Aldi Daswanto (XLV8A6N6B2)

gen:
	xcodegen generate

build: gen
	xcodebuild -project MacHerdr.xcodeproj -scheme MacHerdr -configuration Debug -derivedDataPath build build CODE_SIGN_IDENTITY="$(CODE_SIGN_IDENTITY)" CODE_SIGN_STYLE=Manual -skipPackagePluginValidation | tail -5

# Optimised build, ad-hoc signed. The project enables the hardened runtime, whose
# library validation refuses the bundled Sparkle/Tailcat frameworks when the app
# has no Team ID (dyld: "different Team IDs"), so the tree is re-signed without
# the runtime option — fine for a locally built copy, not for distribution.
release: gen
	xcodebuild -project MacHerdr.xcodeproj -scheme MacHerdr -configuration Release -derivedDataPath build build CODE_SIGN_IDENTITY="$(CODE_SIGN_IDENTITY)" CODE_SIGN_STYLE=Manual -skipPackagePluginValidation | tail -5
	codesign --force --deep --sign "$(CODE_SIGN_IDENTITY)" build/Build/Products/Release/MacHerdr.app

# Replace /Applications/MacHerdr.app with the local Release build (backs up the
# previous copy next to it once, as MacHerdr.previous.app).
install: release
	pkill -x MacHerdr || true
	sleep 1
	if [ -d /Applications/MacHerdr.app ] && [ ! -d /Applications/MacHerdr.previous.app ]; then ditto /Applications/MacHerdr.app /Applications/MacHerdr.previous.app; fi
	rm -rf /Applications/MacHerdr.app
	ditto build/Build/Products/Release/MacHerdr.app /Applications/MacHerdr.app
	open /Applications/MacHerdr.app

# `open` only activates an already-running app, so a rebuilt binary would never
# be exercised. Quit the previous Debug instance first (the /Applications copy is untouched).
run: build
	pkill -f 'build/Build/Products/Debug/MacHerdr.app/Contents/MacOS/MacHerdr' || true
	sleep 1
	open build/Build/Products/Debug/MacHerdr.app

# MacHerdr UI/UX tests (MacHerdrTests, hosted in the app): sidebar behavior through the real SidebarView.
UIUX_TEST = xcodebuild test \
	-project MacHerdr.xcodeproj \
	-scheme MacHerdr \
	-configuration Debug \
	-derivedDataPath build \
	-destination 'platform=macOS,arch=arm64' \
	CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual \
	-skipPackagePluginValidation

uiux-test: gen
	$(UIUX_TEST)

kit-test:
	cd Packages/HerdrKit && swift test

test: kit-test

clean:
	rm -rf build MacHerdr.xcodeproj Packages/HerdrKit/.build
