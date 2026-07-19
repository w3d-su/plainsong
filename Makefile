# Plainsong build entry points (agent.md §15).
# Requires: Xcode 16+, Homebrew. Run `make bootstrap` once after cloning.

PACKAGES := MarkdownCore EditorKit PreviewKit WorkspaceKit
SWIFT_FORMAT_PATHS := App AppTests Packages PerformanceTests Scripts
# SwiftFormat 0.62 enabled these wrapping rules by default. Keep the repository's
# existing 0.61 layout until a deliberate repo-wide migration, without breaking
# older SwiftFormat versions that do not recognize the rule names.
SWIFTFORMAT_COMPAT_FLAGS := $(shell swiftformat --rules 2>/dev/null | grep -q wrapIfStatementBodies && echo --disable wrapIfStatementBodies,wrapIfExpressionBodies)

.PHONY: bootstrap generate build run test format lint preview-bundle release clean

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

# Signed/notarized DMG (docs/release-engineering-plan.md P1-P3).
# Requires PLAINSONG_SIGNING_IDENTITY and notary credentials; see Scripts/release.sh.
release:
	Scripts/release.sh

format:
	swiftformat $(SWIFT_FORMAT_PATHS) $(SWIFTFORMAT_COMPAT_FLAGS)
	swiftlint --fix --quiet

lint:
	swiftformat $(SWIFT_FORMAT_PATHS) --lint $(SWIFTFORMAT_COMPAT_FLAGS)
	swiftlint

clean:
	rm -rf Plainsong.xcodeproj
	@for pkg in $(PACKAGES); do rm -rf Packages/$$pkg/.build; done
