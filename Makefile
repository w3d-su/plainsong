# Plainsong build entry points (agent.md §15).
# Requires: Xcode 16+, Homebrew. Run `make bootstrap` once after cloning.

PACKAGES := MarkdownCore EditorKit PreviewKit WorkspaceKit
SWIFT_FORMAT_PATHS := App AppTests Packages PerformanceTests Scripts

.PHONY: bootstrap generate build run test format lint preview-bundle clean

bootstrap:
	brew install xcodegen swiftformat swiftlint node
	cd preview-src && npm ci

generate:
	xcodegen generate

build: generate
	xcodebuild -project Plainsong.xcodeproj -scheme Plainsong -configuration Debug build

test: generate
	@set -e; for pkg in $(PACKAGES); do \
		echo "==> swift test: $$pkg"; \
		(cd Packages/$$pkg && swift test); \
	done
# TEST_RUNNER_ vars are forwarded by xcodebuild into the xctest process env,
# which does not inherit the shell env; without this, PerformanceTests'
# isContinuousIntegration check never sees CI and hosted-runner WebKit timing
# variance fails budgets that are informational-only on CI (risk R15).
	TEST_RUNNER_CI="$${CI:-}" xcodebuild -project Plainsong.xcodeproj -scheme Plainsong -configuration Debug test
	cd preview-src && npm test

preview-bundle:
	cd preview-src && npm run build

format:
	swiftformat $(SWIFT_FORMAT_PATHS)
	swiftlint --fix --quiet

lint:
	swiftformat $(SWIFT_FORMAT_PATHS) --lint
	swiftlint

clean:
	rm -rf Plainsong.xcodeproj
	@for pkg in $(PACKAGES); do rm -rf Packages/$$pkg/.build; done
