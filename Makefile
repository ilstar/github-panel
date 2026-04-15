PROJECT := GithubPanel.xcodeproj
SCHEME := GithubPanel
CONFIGURATION := Debug
DERIVED_DATA := build/DerivedData
APP := $(CURDIR)/$(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/GithubPanel.app

.PHONY: build test open run mock mock-empty clean build-and-open

build:
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-derivedDataPath $(DERIVED_DATA) \
		build

test:
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-derivedDataPath $(DERIVED_DATA) \
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
