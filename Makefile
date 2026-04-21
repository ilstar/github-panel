PROJECT := GithubPanel.xcodeproj
SCHEME := GithubPanel
CONFIGURATION := Debug
RELEASE_CONFIGURATION := Release
DERIVED_DATA := build/DerivedData
APP := $(CURDIR)/$(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/GithubPanel.app
RELEASE_DERIVED_DATA := build/ReleaseDerivedData
RELEASE_APP := $(RELEASE_DERIVED_DATA)/Build/Products/$(RELEASE_CONFIGURATION)/GithubPanel.app
RELEASE_OUTPUT_DIR := build/Release
RELEASE_ZIP := $(RELEASE_OUTPUT_DIR)/GithubPanel.zip
NOTARIZED_ZIP := $(RELEASE_OUTPUT_DIR)/GithubPanel-notarized.zip

-include .env
-include .env.local

GITHUB_PANEL_CODE_SIGN_IDENTITY ?= Apple Development
GITHUB_PANEL_RELEASE_CODE_SIGN_IDENTITY ?= Developer ID Application
GITHUB_PANEL_RELEASE_DEVELOPMENT_TEAM ?= $(GITHUB_PANEL_DEVELOPMENT_TEAM)

XCODEBUILD_SIGNING_OVERRIDES :=
ifneq ($(strip $(GITHUB_PANEL_DEVELOPMENT_TEAM)),)
XCODEBUILD_SIGNING_OVERRIDES += DEVELOPMENT_TEAM="$(GITHUB_PANEL_DEVELOPMENT_TEAM)"
XCODEBUILD_SIGNING_OVERRIDES += CODE_SIGN_IDENTITY="$(GITHUB_PANEL_CODE_SIGN_IDENTITY)"
XCODEBUILD_SIGNING_OVERRIDES += CODE_SIGN_STYLE=Automatic
endif

XCODEBUILD_RELEASE_SIGNING_OVERRIDES :=
ifneq ($(strip $(GITHUB_PANEL_RELEASE_DEVELOPMENT_TEAM)),)
XCODEBUILD_RELEASE_SIGNING_OVERRIDES += DEVELOPMENT_TEAM="$(GITHUB_PANEL_RELEASE_DEVELOPMENT_TEAM)"
XCODEBUILD_RELEASE_SIGNING_OVERRIDES += CODE_SIGN_IDENTITY="$(GITHUB_PANEL_RELEASE_CODE_SIGN_IDENTITY)"
XCODEBUILD_RELEASE_SIGNING_OVERRIDES += CODE_SIGN_STYLE=Manual
endif

.PHONY: build test open run mock mock-empty clean build-and-open check-release-signing check-notary-config release notary-store-credentials notarize

build:
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-derivedDataPath $(DERIVED_DATA) \
		$(XCODEBUILD_SIGNING_OVERRIDES) \
		build

test:
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-derivedDataPath $(DERIVED_DATA) \
		$(XCODEBUILD_SIGNING_OVERRIDES) \
		test

open:
	open -n $(APP)

run:
	$(APP)/Contents/MacOS/GithubPanel

mock:
	open -n $(APP) --args --mock-github-prs

mock-empty:
	open -n $(APP) --args --mock-empty-github-prs

check-release-signing:
	@test -n "$(GITHUB_PANEL_RELEASE_DEVELOPMENT_TEAM)" || (echo "Set GITHUB_PANEL_RELEASE_DEVELOPMENT_TEAM or GITHUB_PANEL_DEVELOPMENT_TEAM in .env.local for release builds."; exit 1)

release: check-release-signing
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(RELEASE_CONFIGURATION) \
		-derivedDataPath $(RELEASE_DERIVED_DATA) \
		$(XCODEBUILD_RELEASE_SIGNING_OVERRIDES) \
		build
	rm -rf "$(RELEASE_OUTPUT_DIR)"
	mkdir -p "$(RELEASE_OUTPUT_DIR)"
	rm -f "$(RELEASE_ZIP)"
	codesign --verify --deep --strict --verbose=2 "$(RELEASE_APP)"
	ditto -c -k --keepParent "$(RELEASE_APP)" "$(RELEASE_ZIP)"

check-notary-config: check-release-signing
	@test -n "$(GITHUB_PANEL_NOTARY_KEYCHAIN_PROFILE)" || (echo "Set GITHUB_PANEL_NOTARY_KEYCHAIN_PROFILE in .env.local for notarization."; exit 1)

notary-store-credentials: check-release-signing
	@test -n "$(GITHUB_PANEL_NOTARY_KEYCHAIN_PROFILE)" || (echo "Set GITHUB_PANEL_NOTARY_KEYCHAIN_PROFILE in .env.local before storing notary credentials."; exit 1)
	@test -n "$(GITHUB_PANEL_NOTARY_APPLE_ID)" || (echo "Set GITHUB_PANEL_NOTARY_APPLE_ID in .env.local before storing notary credentials."; exit 1)
	xcrun notarytool store-credentials "$(GITHUB_PANEL_NOTARY_KEYCHAIN_PROFILE)" \
		--apple-id "$(GITHUB_PANEL_NOTARY_APPLE_ID)" \
		--team-id "$(GITHUB_PANEL_RELEASE_DEVELOPMENT_TEAM)"

notarize: check-notary-config release
	xcrun notarytool submit "$(RELEASE_ZIP)" \
		--keychain-profile "$(GITHUB_PANEL_NOTARY_KEYCHAIN_PROFILE)" \
		--wait
	xcrun stapler staple "$(RELEASE_APP)"
	xcrun stapler validate "$(RELEASE_APP)"
	spctl -a -vvv "$(RELEASE_APP)"
	rm -f "$(NOTARIZED_ZIP)"
	ditto -c -k --keepParent "$(RELEASE_APP)" "$(NOTARIZED_ZIP)"

clean:
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-derivedDataPath $(DERIVED_DATA) \
		clean

build-and-open: build open
