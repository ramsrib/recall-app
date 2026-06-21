APP := build/Recall App.app

.PHONY: build run app open clean

build: ## Compile the SwiftPM target
	swift build

run: ## Run the app straight from SwiftPM (dev loop)
	swift run

app: ## Package build/Recall App.app with the bundle id
	./scripts/package-app.sh release

open: app ## Package then launch the .app
	open "$(APP)"

clean: ## Remove build artifacts
	rm -rf .build build
