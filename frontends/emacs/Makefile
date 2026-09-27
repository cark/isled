ISLED_EMACS ?= emacs
ISLED_CHECK_PHASE ?= all
ISLED_CHECK_PROGRAM ?=
export ISLED_CHECK_PHASE ISLED_CHECK_PROGRAM

.PHONY: check package
check:
	"$(ISLED_EMACS)" -Q --batch --load test/run-check.el

package:
	python3 ../../scripts/package-emacs.py
