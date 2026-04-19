PROJECT := GithubPanel.xcodeproj
SCHEME := GithubPanel
CONFIGURATION := Debug
DERIVED_DATA := build/DerivedData
APP := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/GithubPanel.app

-include .env
-include .env.local

.PHONY: build test open run mock clean build-and-open check-local-signing test-local-signed build-local-signed build-and-open-local-signed

build:
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-derivedDataPath $(DERIVED_DATA) \
		build

check-local-signing:
	@test -n "$(GITHUB_PANEL_DEVELOPMENT_TEAM)" || (echo "Set GITHUB_PANEL_DEVELOPMENT_TEAM in .env.local for local signed builds."; exit 1)

build-local-signed: check-local-signing
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-derivedDataPath $(DERIVED_DATA) \
		DEVELOPMENT_TEAM="$(GITHUB_PANEL_DEVELOPMENT_TEAM)" \
		CODE_SIGN_IDENTITY="$(GITHUB_PANEL_CODE_SIGN_IDENTITY)" \
		CODE_SIGN_STYLE=Automatic \
		build

test:
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-derivedDataPath $(DERIVED_DATA) \
		test

test-local-signed: check-local-signing
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-derivedDataPath $(DERIVED_DATA) \
		DEVELOPMENT_TEAM="$(GITHUB_PANEL_DEVELOPMENT_TEAM)" \
		CODE_SIGN_IDENTITY="$(GITHUB_PANEL_CODE_SIGN_IDENTITY)" \
		CODE_SIGN_STYLE=Automatic \
		test

open:
	open -n $(APP)

run:
	$(APP)/Contents/MacOS/GithubPanel

mock:
	open -n $(APP) --args --mock-github-prs

clean:
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-derivedDataPath $(DERIVED_DATA) \
		clean

build-and-open: build open

build-and-open-local-signed: build-local-signed open
