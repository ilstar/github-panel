PROJECT := GithubPanel.xcodeproj
SCHEME := GithubPanel
CONFIGURATION := Debug
DERIVED_DATA := build/DerivedData
APP_NAME := GithubPanel
APP = $(CURDIR)/$(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/$(APP_NAME).app
VERSION ?= 1.2.0
DIST_DIR := $(CURDIR)/build/dist
DMG_STAGING := $(DIST_DIR)/dmg-staging
DMG_NAME := $(APP_NAME)-$(VERSION).dmg
DMG_PATH := $(DIST_DIR)/$(DMG_NAME)
RELEASE_TAG ?= v$(VERSION)
RELEASE_TITLE ?= $(APP_NAME) $(VERSION)
RELEASE_NOTES ?= Release $(VERSION)
GH_RELEASE_FLAGS ?=

-include .env
-include .env.local

XCODEBUILD_SIGNING_OVERRIDES :=
ifneq ($(strip $(GITHUB_PANEL_DEVELOPMENT_TEAM)),)
XCODEBUILD_SIGNING_OVERRIDES += DEVELOPMENT_TEAM="$(GITHUB_PANEL_DEVELOPMENT_TEAM)"
XCODEBUILD_SIGNING_OVERRIDES += CODE_SIGN_IDENTITY="$(GITHUB_PANEL_CODE_SIGN_IDENTITY)"
XCODEBUILD_SIGNING_OVERRIDES += CODE_SIGN_STYLE=Automatic
endif

.PHONY: build test test-release-targets open run mock mock-empty clean dmg release github-release build-and-open

build:
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-derivedDataPath $(DERIVED_DATA) \
		$(XCODEBUILD_SIGNING_OVERRIDES) \
		build

test: test-release-targets
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-derivedDataPath $(DERIVED_DATA) \
		$(XCODEBUILD_SIGNING_OVERRIDES) \
		test

test-release-targets:
	@mkdir -p "$(CURDIR)/build/test"
	@$(MAKE) --no-print-directory -n dmg VERSION=9.9.9 > "$(CURDIR)/build/test/dmg-dry-run.txt"
	@grep -q 'hdiutil create' "$(CURDIR)/build/test/dmg-dry-run.txt"
	@grep -q 'GithubPanel-9.9.9.dmg' "$(CURDIR)/build/test/dmg-dry-run.txt"
	@$(MAKE) --no-print-directory -n release VERSION=9.9.9 RELEASE_NOTES="Dry run" > "$(CURDIR)/build/test/release-dry-run.txt"
	@grep -q 'gh release' "$(CURDIR)/build/test/release-dry-run.txt"
	@grep -q 'v9.9.9' "$(CURDIR)/build/test/release-dry-run.txt"

open:
	open -n $(APP)

run:
	$(APP)/Contents/MacOS/GithubPanel

mock:
	open -n $(APP) --args --mock-github-prs

mock-empty:
	open -n $(APP) --args --mock-empty-github-prs

clean:
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-derivedDataPath $(DERIVED_DATA) \
		clean

dmg: CONFIGURATION := Release
dmg: build
	@rm -rf "$(DMG_STAGING)" "$(DMG_PATH)"
	@mkdir -p "$(DMG_STAGING)" "$(DIST_DIR)"
	cp -R "$(APP)" "$(DMG_STAGING)/"
	ln -s /Applications "$(DMG_STAGING)/Applications"
	hdiutil create \
		-volname "$(APP_NAME) $(VERSION)" \
		-srcfolder "$(DMG_STAGING)" \
		-ov \
		-format UDZO \
		"$(DMG_PATH)"
	@echo "Created $(DMG_PATH)"

release: github-release

github-release: dmg
	@command -v gh >/dev/null || (echo "GitHub CLI is required. Install gh and run gh auth login."; exit 1)
	@if gh release view "$(RELEASE_TAG)" >/dev/null 2>&1; then \
		echo "Uploading $(DMG_PATH) to existing GitHub release $(RELEASE_TAG)"; \
		gh release upload "$(RELEASE_TAG)" "$(DMG_PATH)" --clobber; \
	else \
		echo "Creating GitHub release $(RELEASE_TAG) with $(DMG_PATH)"; \
		gh release create "$(RELEASE_TAG)" "$(DMG_PATH)" --title "$(RELEASE_TITLE)" --notes "$(RELEASE_NOTES)" $(GH_RELEASE_FLAGS); \
	fi

build-and-open: build open
