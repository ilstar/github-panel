# Repository Instructions

- By default, whenever starting work on a new change or feature, use a new branch and create a pull request.
- When creating a pull request, use `.github/pull_request_template.md` as the PR body template and fill out every section.
- Every time there are code changes:
  - Add or update the relevant test code as part of the change.
  - Run `make test` before building the app.
  - Rebuild the app and open it for the user after tests pass.
