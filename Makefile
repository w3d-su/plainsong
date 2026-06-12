# BlogEditor build entry points (agent.md §15).
# Requires: Xcode 16+, Homebrew. Run `make bootstrap` once after cloning.

PACKAGES := MarkdownCore EditorKit PreviewKit WorkspaceKit

.PHONY: bootstrap generate build run test format lint preview-bundle clean

bootstrap:
	brew install xcodegen swiftformat swiftlint node
	cd preview-src && npm ci

generate:
	xcodegen generate

build: generate
	xcodebuild -project BlogEditor.xcodeproj -scheme BlogEditor -configuration Debug build

test: generate
	@set -e; for pkg in $(PACKAGES); do \
		echo "==> swift test: $$pkg"; \
		(cd Packages/$$pkg && swift test); \
	done
	xcodebuild -project BlogEditor.xcodeproj -scheme BlogEditor -configuration Debug test
	cd preview-src && npm test

preview-bundle:
	cd preview-src && npm run build

format:
	swiftformat App AppTests Packages
	swiftlint --fix --quiet

lint:
	swiftformat App AppTests Packages --lint
	swiftlint

clean:
	rm -rf BlogEditor.xcodeproj
	@for pkg in $(PACKAGES); do rm -rf Packages/$$pkg/.build; done
