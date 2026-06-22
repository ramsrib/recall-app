APP_NAME := Recall App
APP := build/$(APP_NAME).app
DEST := /Applications/$(APP_NAME).app

.PHONY: build run app open install clean

build: ## Compile the SwiftPM target
	swift build

run: ## Run the app straight from SwiftPM (dev loop)
	swift run

app: ## Package build/Recall App.app with the bundle id
	./scripts/package-app.sh release

open: app ## Package then launch the .app
	open "$(APP)"

install: app ## Build, package, and install to /Applications
	@pkill -9 -x RecallApp 2>/dev/null || true
	@pkill -9 -f "$(APP_NAME).app" 2>/dev/null || true
	@rm -rf "$(DEST)"
	@ditto "$(APP)" "$(DEST)"
	@echo "✓ installed → $(DEST)"

clean: ## Remove build artifacts
	rm -rf .build build
