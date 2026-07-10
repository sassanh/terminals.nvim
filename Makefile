TESTS_INIT=tests/minimal_init.lua
TESTS_DIR=tests/

.PHONY: test deps

deps:
	@if [ ! -d vendor/plenary.nvim/.git ]; then \
		git clone --depth 1 https://github.com/nvim-lua/plenary.nvim vendor/plenary.nvim; \
	fi

test: deps
	@nvim \
		--headless \
		--noplugin \
		-u ${TESTS_INIT} \
		-c "PlenaryBustedDirectory ${TESTS_DIR} { minimal_init = '${TESTS_INIT}' }" \
		-c "qa!"