# Plainsong build entry points (agent.md §15).
# Requires: Xcode 16+, Homebrew. Run `make bootstrap` once after cloning.

PACKAGES := MarkdownCore EditorKit PreviewKit WorkspaceKit
SWIFT_FORMAT_PATHS := App AppTests Packages PerformanceTests PlainsongUITests Scripts
# SwiftFormat 0.62 enabled these wrapping rules by default. Keep the repository's
# existing 0.61 layout until a deliberate repo-wide migration, without breaking
# older SwiftFormat versions that do not recognize the rule names.
SWIFTFORMAT_COMPAT_FLAGS := $(shell swiftformat --rules 2>/dev/null | grep -q wrapIfStatementBodies && echo --disable wrapIfStatementBodies,wrapIfExpressionBodies)

.PHONY: bootstrap generate build run test test-f2-tooling format lint preview-bundle release clean

bootstrap:
	brew install xcodegen swiftformat swiftlint node
	cd preview-src && npm ci

generate:
	xcodegen generate

build: generate
	xcodebuild -project Plainsong.xcodeproj -scheme Plainsong -configuration Debug build

test: generate
	$(MAKE) test-f2-tooling
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

test-f2-tooling:
	/usr/bin/env PYTHONPATH=Scripts /usr/bin/python3 -m unittest discover -s Scripts/editor_find_f2_evidence_tests -t Scripts -p 'test_*.py' -v
	Scripts/check-editor-find-f2-tooling-inventory.py
	Scripts/check-editor-find-f2-retained-evidence.py $(CURDIR)/docs/evidence/editor-find-f2-c871ddf-retained-pack --allow-partial --expected-inventory-sha256 23d3ec514e1a99f65093dede22af190dece22a936d56e999c2bf0740b5bb50bd

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
