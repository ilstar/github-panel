# Tasks live in mise (see mise.toml and mise-tasks/). This file only forwards
# `make <task>` to `mise run <task>`, passing variables such as VERSION=1.4.0
# through the environment.

.EXPORT_ALL_VARIABLES:
.DEFAULT_GOAL := build

%:
	@mise run $@

Makefile: ;
