APP = build/Jev Voice.app
BINARY = .build/release/JevVoice
VERSION := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
ZIP = build/Jev-Voice-$(VERSION).zip
CUA_DRIVER_VERSION = 0.28.2
CUA_DRIVER_URL = https://github.com/trycua/cua/releases/download/cua-driver-rs-v$(CUA_DRIVER_VERSION)/cua-driver-rs-$(CUA_DRIVER_VERSION)-darwin-universal.tar.gz
CUA_DRIVER_SHA256 = e273181b26709c88b1d809474deb3c592b4efae3530b11d76318f1887fc3fbb1
CUA_DRIVER_ARCHIVE = build/cua/cua-driver.tar.gz
CUA_DRIVER_BINARY = build/cua/cua-driver

.PHONY: build fetch-cua app run test dist clean icon

build:
	swift build -c release

fetch-cua:
	mkdir -p build/cua
	curl -L --fail --silent --show-error "$(CUA_DRIVER_URL)" -o "$(CUA_DRIVER_ARCHIVE)"
	echo "$(CUA_DRIVER_SHA256)  $(CUA_DRIVER_ARCHIVE)" | shasum -a 256 -c -
	tar -xzf "$(CUA_DRIVER_ARCHIVE)" -C build/cua
	find build/cua -type f -name cua-driver ! -path "$(CUA_DRIVER_BINARY)" -exec cp {} "$(CUA_DRIVER_BINARY)" \;
	test -x "$(CUA_DRIVER_BINARY)"
	chmod +x "$(CUA_DRIVER_BINARY)"

app: build fetch-cua
	mkdir -p "$(APP)/Contents/MacOS"
	cp "$(BINARY)" "$(APP)/Contents/MacOS/JevVoice"
	cp Info.plist "$(APP)/Contents/Info.plist"
	mkdir -p "$(APP)/Contents/Resources"
	cp Resources/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"
	mkdir -p "$(APP)/Contents/Helpers"
	cp "$(CUA_DRIVER_BINARY)" "$(APP)/Contents/Helpers/cua-driver"
	chmod +x "$(APP)/Contents/Helpers/cua-driver"
	codesign --force --sign - "$(APP)/Contents/Helpers/cua-driver"
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
