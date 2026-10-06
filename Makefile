.PHONY: build install run check clean reset-perms icon icon-ai

## Build Insight.app into dist/ and ad-hoc codesign it.
build:
	@./scripts/build_app.sh

## Build, then replace /Applications/Insight.app.
install:
	@./scripts/build_app.sh --install

## Build, install and launch.
run: install
	@open -a /Applications/Insight.app

## Run the checker. Uses a real local socket for the SSE tests rather than a URLProtocol
## stub, because byte reassembly is the part most likely to be wrong.
check:
	@swift run insight-check

## Debug build + demo panel, no API key needed.
demo:
	@swift build
	@./.build/debug/Insight --demo

## Debug build + settings window.
settings:
	@swift build
	@./.build/debug/Insight --settings

## Ad-hoc re-signing changes the code signature, which can invalidate the Accessibility and
## Screen Recording grants. Run this if the hotkeys or screenshot stop working after a rebuild.
reset-perms:
	@./scripts/build_app.sh --reset-perms

## Procedural fallback icon, no API key required.
icon:
	@swift scripts/make_icon.swift /tmp/AppIcon.iconset
	@iconutil -c icns /tmp/AppIcon.iconset -o Resources/AppIcon.icns
	@echo Resources/AppIcon.icns

## Regenerate the icon from an image model, then re-cut it to Apple's icon grid.
## Reads OPENROUTER_API_KEY from the environment — never from argv or a file in the repo.
icon-ai:
	@python3 scripts/gen_icon_ai.py Resources "$(PROMPT)" google/gemini-3.1-flash-image AppIcon-source
	@swift scripts/make_icon_from_ai.swift Resources/AppIcon-source.png /tmp/AppIcon.iconset
	@iconutil -c icns /tmp/AppIcon.iconset -o Resources/AppIcon.icns
	@rm -rf /tmp/AppIcon.iconset
	@echo Resources/AppIcon.icns

clean:
	@rm -rf dist .build