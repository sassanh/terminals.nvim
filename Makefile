TESTS_INIT=tests/minimal_init.lua
TESTS_DIR=tests/
PLENARY_DIR?=vendor/plenary.nvim

.PHONY: test deps

deps:
	@if [ ! -d "$(PLENARY_DIR)/.git" ]; then \
		git clone --depth 1 https://github.com/nvim-lua/plenary.nvim "$(PLENARY_DIR)"; \
	fi

test: deps
	@PLENARY_DIR="$(CURDIR)/$(PLENARY_DIR)" nvim \
		--headless \
		--noplugin \
		-u ${TESTS_INIT} \
		-c "PlenaryBustedDirectory ${TESTS_DIR} { minimal_init = '${TESTS_INIT}' }" \
		-c "qa!"