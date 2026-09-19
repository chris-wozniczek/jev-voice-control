APP = build/Jev Voice.app
BINARY = .build/release/JevVoice
VERSION := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
ZIP = build/Jev-Voice-$(VERSION).zip

.PHONY: build app run test dist clean icon

build:
	swift build -c release

app: build
	mkdir -p "$(APP)/Contents/MacOS"
	cp "$(BINARY)" "$(APP)/Contents/MacOS/JevVoice"
	cp Info.plist "$(APP)/Contents/Info.plist"
	mkdir -p "$(APP)/Contents/Resources"
	cp Resources/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"
	codesign --force --deep --sign - "$(APP)"

run: app
	open "$(APP)"

test:
	swift test

# Zip suitable for a GitHub release asset / Homebrew cask (ditto preserves signatures).
dist: app
	rm -f "$(ZIP)"
	ditto -c -k --keepParent "$(APP)" "$(ZIP)"
	shasum -a 256 "$(ZIP)"

# Regenerates Resources/AppIcon.icns from scripts/make-icon.swift.
icon:
	rm -rf build/AppIcon.iconset
	swift scripts/make-icon.swift build/AppIcon.iconset
	iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns

clean:
	rm -rf build .build
