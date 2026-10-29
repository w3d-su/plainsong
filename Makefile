# Plainsong build entry points (agent.md §15).
# Requires: Xcode 16+, Homebrew. Run `make bootstrap` once after cloning.

XCODE_RESULT_BUNDLE ?=
XCODE_DERIVED_DATA ?=
XCODE_ARTIFACT_DIR ?=
XCODE_TEST_TARGETS ?=

PACKAGES := MarkdownCore EditorKit PreviewKit WorkspaceKit
PORTABLE_PACKAGES := SyntaxKit WorkspaceCore
# IOSAcceptanceTests is lane 11's dir and does not exist yet; wildcard keeps the
# list valid before it lands and picks it up automatically once it does.
SWIFT_FORMAT_PATHS := App AppTests AppIOS AppIOSTests Packages PerformanceTests PlainsongUITests Scripts $(wildcard IOSAcceptanceTests)
# SwiftFormat 0.62 enabled these wrapping rules by default. Keep the repository's
# existing 0.61 layout until a deliberate repo-wide migration, without breaking
# older SwiftFormat versions that do not recognize the rule names.
SWIFTFORMAT_COMPAT_FLAGS := $(shell swiftformat --rules 2>/dev/null | grep -q wrapIfStatementBodies && echo --disable wrapIfStatementBodies,wrapIfExpressionBodies)
# CI installs exactly this SwiftFormat release (.github/workflows/ci.yml). Local
# Homebrew installs cannot pin, so `make lint`/`make format` only warn on drift;
# treat CI as authoritative when local and CI lint results disagree.
SWIFTFORMAT_VERSION := 0.62.1

.PHONY: bootstrap generate build run test test-packages test-hosted test-preview test-f2-tooling format lint preview-bundle release clean swiftformat-version-check

swiftformat-version-check:
	@actual="$$(swiftformat --version 2>/dev/null || echo missing)"; \
	if [ "$$actual" != "$(SWIFTFORMAT_VERSION)" ]; then \
		echo "warning: local swiftformat is $$actual; CI pins $(SWIFTFORMAT_VERSION), so lint results may differ from CI" >&2; \
	fi

bootstrap:
	brew install xcodegen swiftformat swiftlint node
	cd preview-src && npm ci

generate:
	xcodegen generate

build: generate
	xcodebuild -project Plainsong.xcodeproj -scheme Plainsong -configuration Debug $(if $(XCODE_DERIVED_DATA),-derivedDataPath "$(XCODE_DERIVED_DATA)") build

# CI runs these three groups as parallel jobs (.github/workflows/ci.yml); locally
# `make test` still runs all of them in sequence.
test: test-packages test-hosted test-preview

# generate: the sandbox checks sign their probes with the XcodeGen-generated
# App/Plainsong.entitlements.
test-packages: generate
	$(MAKE) test-f2-tooling
	python3 Scripts/test-preview-webview-layering.py
	Scripts/check-sparkle-layering.sh
	@set -e; for pkg in $(PACKAGES); do \
		echo "==> swift test: $$pkg"; \
		(cd Packages/$$pkg && swift test); \
	done
	$(MAKE) test-portable-core
	Scripts/check-export-sandbox-root.sh
	Scripts/check-single-file-save-sandbox.sh

# XCODE_TEST_TARGETS="PlainsongTests" (space-separated bundle names) runs a subset.
test-hosted: generate
# TEST_RUNNER_ vars are forwarded by xcodebuild into the xctest process env,
# which does not inherit the shell env; without this, PerformanceTests'
# isContinuousIntegration check never sees CI and hosted-runner WebKit timing
# variance fails budgets that are informational-only on CI (risk R15).
	TEST_RUNNER_CI="$${CI:-}" XCODE_RESULT_BUNDLE="$(XCODE_RESULT_BUNDLE)" \
	    XCODE_DERIVED_DATA="$(XCODE_DERIVED_DATA)" XCODE_ARTIFACT_DIR="$(XCODE_ARTIFACT_DIR)" \
	    XCODE_TEST_TARGETS="$(XCODE_TEST_TARGETS)" \
	    Scripts/run-hosted-tests.sh

test-preview:
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

format: swiftformat-version-check
	swiftformat $(SWIFT_FORMAT_PATHS) $(SWIFTFORMAT_COMPAT_FLAGS)
	swiftlint --fix --quiet

lint: swiftformat-version-check
	python3 Scripts/check-preview-webview-layering.py
	swiftformat $(SWIFT_FORMAT_PATHS) --lint $(SWIFTFORMAT_COMPAT_FLAGS)
	swiftlint

clean:
	rm -rf Plainsong.xcodeproj
	@for pkg in $(PACKAGES); do rm -rf Packages/$$pkg/.build; done

# C0-only bootstrap (kept so the PR #157 reproduction commands stay valid);
# superseded by the fixed ios-* entries below.
.PHONY: ios-c0-build ios-c0-test
ios-c0-build:
	Scripts/ios/c0.sh build

ios-c0-test:
	Scripts/ios/c0.sh test

# ── iOS lane-12 entries (docs/ios/build-and-ipa.md) ──────────────────────────
# Fixed, isolated entry points: every runner holds the shared lock
# (/private/tmp/plainsong-xcodebuild-test.lock) for its whole run and writes
# evidence under IOS_OUTPUT_ROOT. These never run from `make build`/`test`/
# `release`, and iOS-only packages never join the Mac `swift test` loop above.
#
#   make ios-build   [IOS_DESTINATION='platform=iOS Simulator,id=<uuid>']
#   make ios-test    IOS_DESTINATION='platform=iOS Simulator,id=<installed-uuid>'
#   make ios-preview IOS_DESTINATION='platform=iOS Simulator,id=<installed-uuid>'
#   make ios-acceptance IOS_DESTINATION='platform=iOS Simulator,id=<installed-uuid>'
#   make ios-acceptance-components
#   make ios-archive [IOS_OUTPUT_ROOT=/private/tmp/plainsong-ios-release]
#   make ios-ipa     [IOS_OUTPUT_ROOT=/private/tmp/plainsong-ios-release]
# ios-acceptance checks the production Files/Open launch UI only. It is not part of
# `make test` or `make ios-test`. ios-acceptance-components is the Mac
# package suite and is also outside those loops.
IOS_OUTPUT_ROOT ?= /private/tmp/plainsong-ios-release

.PHONY: ios-build ios-test ios-preview ios-acceptance ios-acceptance-components ios-archive ios-ipa
ios-build:
	Scripts/ios/run-ios-build.sh "$(IOS_OUTPUT_ROOT)"

ios-test:
	Scripts/ios/run-ios-tests.sh "$(IOS_OUTPUT_ROOT)"

ios-preview:
	IOS_SCHEME=IOSPreview Scripts/ios/run-ios-tests.sh "$(IOS_OUTPUT_ROOT)"

ios-acceptance:
	IOS_SCHEME=IOSAcceptance Scripts/ios/run-ios-tests.sh "$(IOS_OUTPUT_ROOT)"

ios-acceptance-components:
	Scripts/ios/run-ios-acceptance-components.sh "$(IOS_OUTPUT_ROOT)"

ios-archive:
	Scripts/ios/run-ios-archive.sh "$(IOS_OUTPUT_ROOT)"

ios-ipa:
	Scripts/ios/run-ios-ipa.sh "$(IOS_OUTPUT_ROOT)"

.PHONY: test-portable-core
test-portable-core:
	@set -e; for pkg in $(PORTABLE_PACKAGES); do \
		echo "==> portable swift test: $$pkg"; \
		(cd Packages/$$pkg && swift test); \
	done

.PHONY: test-ios-tooling
test-ios-tooling:
	PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -m unittest discover -s Scripts/ios/tests -p 'test_*.py' -v
