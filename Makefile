DERIVED := build
APP := $(DERIVED)/Build/Products/Debug/Noiets.app
LOGO := App/Resources/Logo.png
ICONSET := App/Assets.xcassets/AppIcon.appiconset
ICON := App/AppIcon.icon

.PHONY: gen icon build test run clean

gen:
	xcodegen generate

# All app-icon artifacts are derived from Logo.png and committed (the release
# workflow builds straight from the repo without running these rules):
#  - AppIcon.icon: Icon Composer document; without it macOS 26 shows the icon
#    shrunken on a system plate instead of edge-to-edge in the squircle.
#  - appiconset PNGs: legacy fallback (icns for Finder/Dock pre-26 contexts);
#    the @2x-512 file stands in for the whole sips fan-out.
icon: $(ICON)/icon.json $(ICONSET)/icon_512@2x.png

$(ICON)/icon.json: $(LOGO) Scripts/GenAppIcon.swift
	swift Scripts/GenAppIcon.swift $(LOGO) $(ICON)

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
