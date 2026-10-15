# Local checks. `make` runs lint and the unit tests; it's the gate before merging.
SHELL_FILES = $(shell shfmt -f bin lib install.sh test 2>/dev/null)
BASH_FILES = $(filter-out %.bats,$(SHELL_FILES))

.PHONY: all lint test
all: lint test

lint:
	for f in $(BASH_FILES); do bash -n "$$f" || exit 1; done
	shellcheck $(SHELL_FILES)
	shfmt -i 2 -ci -bn -d $(SHELL_FILES)

test:
	bats --jobs 4 test/unit
