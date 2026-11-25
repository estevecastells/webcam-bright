.PHONY: build install uninstall log help

build:      ## Build build/WebcamBright.app and build/uvcctl
	scripts/install.sh build

install:    ## Build and install the background helper (LaunchAgent, no sudo)
	scripts/install.sh

uninstall:  ## Stop and remove the background helper
	scripts/install.sh uninstall

log:        ## Follow the helper's log
	tail -f ~/Library/Logs/webcam-bright.log

help:
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'
