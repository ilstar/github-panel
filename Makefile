PROJECT := GithubPanel.xcodeproj
SCHEME := GithubPanel
CONFIGURATION := Debug
DERIVED_DATA := build/DerivedData
APP_NAME := GithubPanel
APP = $(CURDIR)/$(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/$(APP_NAME).app
VERSION ?= 1.0
DIST_DIR := $(CURDIR)/build/dist
DMG_STAGING := $(DIST_DIR)/dmg-staging
DMG_NAME := $(APP_NAME)-$(VERSION).dmg
DMG_PATH := $(DIST_DIR)/$(DMG_NAME)
APP_ZIP_PATH := $(DIST_DIR)/$(APP_NAME)-$(VERSION).zip
RELEASE_TAG ?= v$(VERSION)
RELEASE_TITLE ?= $(APP_NAME) $(VERSION)
RELEASE_NOTES ?= Release $(VERSION)
GH_RELEASE_FLAGS ?=
DEVELOPER_ID_APPLICATION ?= $(GITHUB_PANEL_DEVELOPER_ID_APPLICATION)
NOTARY_PROFILE ?= $(GITHUB_PANEL_NOTARY_PROFILE)

-include .env
-include .env.local

XCODEBUILD_SIGNING_OVERRIDES :=
ifneq ($(strip $(GITHUB_PANEL_DEVELOPMENT_TEAM)),)
XCODEBUILD_SIGNING_OVERRIDES += DEVELOPMENT_TEAM="$(GITHUB_PANEL_DEVELOPMENT_TEAM)"
XCODEBUILD_SIGNING_OVERRIDES += CODE_SIGN_IDENTITY="$(GITHUB_PANEL_CODE_SIGN_IDENTITY)"
XCODEBUILD_SIGNING_OVERRIDES += CODE_SIGN_STYLE=Automatic
endif

.PHONY: build test test-release-targets open run mock mock-empty clean dmg notarized-dmg require-distribution-signing release github-release build-and-open

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
	@grep -q 'notarytool submit' "$(CURDIR)/build/test/release-dry-run.txt"
	@grep -q 'stapler staple' "$(CURDIR)/build/test/release-dry-run.txt"
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
	@echo "This DMG is for local testing. Use 'make notarized-dmg VERSION=$(VERSION)' for sharing outside this Mac."

notarized-dmg: CONFIGURATION := Release
notarized-dmg: require-distribution-signing build
	codesign --force --deep --options runtime --timestamp --sign "$(DEVELOPER_ID_APPLICATION)" "$(APP)"
	codesign --verify --deep --strict --verbose=4 "$(APP)"
	@rm -rf "$(DMG_STAGING)" "$(DMG_PATH)" "$(APP_ZIP_PATH)"
	@mkdir -p "$(DIST_DIR)"
	ditto -c -k --keepParent "$(APP)" "$(APP_ZIP_PATH)"
	xcrun notarytool submit "$(APP_ZIP_PATH)" --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple "$(APP)"
	xcrun stapler validate "$(APP)"
	spctl --assess --type execute --verbose=4 "$(APP)"
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
	codesign --force --timestamp --sign "$(DEVELOPER_ID_APPLICATION)" "$(DMG_PATH)"
	xcrun notarytool submit "$(DMG_PATH)" --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple "$(DMG_PATH)"
	xcrun stapler validate "$(DMG_PATH)"
	spctl --assess --type open --context context:primary-signature --verbose=4 "$(DMG_PATH)"
	@echo "Created notarized DMG at $(DMG_PATH)"

require-distribution-signing:
	@test -n "$(DEVELOPER_ID_APPLICATION)" || (echo "Set GITHUB_PANEL_DEVELOPER_ID_APPLICATION in .env.local, for example: Developer ID Application: Your Name (TEAMID)"; exit 1)
	@test -n "$(NOTARY_PROFILE)" || (echo "Set GITHUB_PANEL_NOTARY_PROFILE in .env.local after running: xcrun notarytool store-credentials <profile-name>"; exit 1)

release: github-release

github-release: notarized-dmg
	@command -v gh >/dev/null || (echo "GitHub CLI is required. Install gh and run gh auth login."; exit 1)
	@if gh release view "$(RELEASE_TAG)" >/dev/null 2>&1; then \
		echo "Uploading $(DMG_PATH) to existing GitHub release $(RELEASE_TAG)"; \
		gh release upload "$(RELEASE_TAG)" "$(DMG_PATH)" --clobber; \
	else \
		echo "Creating GitHub release $(RELEASE_TAG) with $(DMG_PATH)"; \
		gh release create "$(RELEASE_TAG)" "$(DMG_PATH)" --title "$(RELEASE_TITLE)" --notes "$(RELEASE_NOTES)" $(GH_RELEASE_FLAGS); \
	fi

build-and-open: build open
