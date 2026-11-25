.PHONY: build check install uninstall run log screenshots icon clean help

build:        ## Build build/WebcamBright.app and build/uvcctl
	scripts/build-app.sh

check:        ## Lever and settings checks (no camera needed)
	cd app && swift run -c debug KitChecks

install: build ## Install the menu bar app into /Applications and open it
	scripts/install.sh

uninstall:    ## Quit and remove the app and its login item
	scripts/install.sh uninstall

run: build    ## Open the app from build/ without installing it
	open build/WebcamBright.app

log:          ## Follow the log
	tail -f ~/Library/Logs/webcam-bright.log

screenshots:  ## Render the README's panel images from the real views
	cd app && swift run -c debug RenderScreenshots ../docs/images

icon:         ## Redraw the app icon
	mkdir -p build && swiftc -o build/make-icon scripts/make-icon.swift && build/make-icon app/Resources/AppIcon.icns

clean:
	rm -rf build app/.build

help:
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-13s %s\n", $$1, $$2}'
