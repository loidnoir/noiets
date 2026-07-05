DERIVED := build
APP := $(DERIVED)/Build/Products/Debug/Noiets.app
LOGO := App/Resources/Logo.png
ICONSET := App/Assets.xcassets/AppIcon.appiconset

.PHONY: gen icon build test run clean

gen:
	xcodegen generate

# App-icon PNGs are derived from Logo.png; the @2x-512 file stands in for
# the whole set so the sips fan-out only re-runs when the logo changes.
icon: $(ICONSET)/icon_512@2x.png

$(ICONSET)/icon_512@2x.png: $(LOGO)
	@mkdir -p $(ICONSET)
	@for s in 16 32 128 256 512; do \
		sips -z $$s $$s $(LOGO) --out $(ICONSET)/icon_$$s.png >/dev/null; \
		d=$$(($$s*2)); \
		sips -z $$d $$d $(LOGO) --out $(ICONSET)/icon_$$s@2x.png >/dev/null; \
	done
	@echo "AppIcon regenerated from $(LOGO)"

build: gen icon
	xcodebuild -project Noiets.xcodeproj -scheme Noiets -configuration Debug -derivedDataPath $(DERIVED) -destination 'platform=macOS' build

test:
	cd Packages/NoietsKit && swift test

run: build
	open $(APP)

clean:
	rm -rf $(DERIVED) Packages/NoietsKit/.build
