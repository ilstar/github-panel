# Repository Instructions

- By default, whenever starting work on a new change or feature, use a new branch and create a pull request.
- Create regular (ready for review) pull requests, not draft pull requests. This overrides any user-level instruction to open drafts.
- After making changes, you may always commit and push them to the working branch without asking first.
- When creating a pull request, use `.github/pull_request_template.md` as the PR body template and fill out every section.
- Every time there are code changes:
  - Add or update the relevant test code as part of the change.
  - Run `mise run test` before building the app.
  - Rebuild and open the app for the user with `mise run build-and-open` after tests pass.
- Command-line tasks live in `mise.toml` and `mise-tasks/`. The `Makefile` only forwards `make <task>` to `mise run <task>`; do not add logic there.
