PROJECT := GithubPanel.xcodeproj
SCHEME := GithubPanel
CONFIGURATION := Debug
DERIVED_DATA := build/DerivedData
APP := $(CURDIR)/$(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/GithubPanel.app

-include .env
-include .env.local

XCODEBUILD_SIGNING_OVERRIDES :=
ifneq ($(strip $(GITHUB_PANEL_DEVELOPMENT_TEAM)),)
XCODEBUILD_SIGNING_OVERRIDES += DEVELOPMENT_TEAM="$(GITHUB_PANEL_DEVELOPMENT_TEAM)"
XCODEBUILD_SIGNING_OVERRIDES += CODE_SIGN_IDENTITY="$(GITHUB_PANEL_CODE_SIGN_IDENTITY)"
XCODEBUILD_SIGNING_OVERRIDES += CODE_SIGN_STYLE=Automatic
endif

.PHONY: build test open run mock mock-empty clean build-and-open

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

clean:
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-derivedDataPath $(DERIVED_DATA) \
		clean

build-and-open: build open
