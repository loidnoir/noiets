DERIVED := build
APP := $(DERIVED)/Build/Products/Debug/Noiets.app

.PHONY: gen build test run clean

gen:
	xcodegen generate

build: gen
	xcodebuild -project Noiets.xcodeproj -scheme Noiets -configuration Debug -derivedDataPath $(DERIVED) -destination 'platform=macOS' build

test:
	cd Packages/NoietsKit && swift test

run: build
	open $(APP)

clean:
	rm -rf $(DERIVED) Packages/NoietsKit/.build
