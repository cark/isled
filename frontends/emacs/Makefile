PACKAGE := isled
VERSION := 0.31.1
ARCHIVE := dist/$(PACKAGE)-$(VERSION).tar
FILES := isled-pkg.el isled-graph-model.el isled-graph-drawing.el isled-graph-glyphs.el isled-graph-gutter.el isled-graph.el isled-browser.el isled-snapshot.el isled-view.el isled-presentation.el isled-rows.el isled-fold.el isled-sections.el isled-header.el isled-warnings.el isled-jump.el isled-auto-refresh.el isled-frontend.el isled-process.el isled-sequence.el isled-data.el isled-windows.el isled-viewport.el isled-session.el isled-navigation.el isled-source.el isled-file-routing.el isled-file-visit.el isled-filter-query.el isled-filter-completion.el isled-filter-preview.el isled-filter-display.el isled-filter-inline.el isled-filter-picker.el isled-filter-minibuffer.el isled-filter.el isled-expansion.el isled-loading.el isled-buffers.el isled-context.el isled-initialize.el isled-entry.el isled-editor-model.el isled-editor-form.el isled-editor-completion.el isled-editor-feedback.el isled-editor.el isled.el README.md user-guide.md CONTRIBUTING.md images/hierarchy.gif images/filtering.gif
ISLED_EMACS ?= emacs
ISLED_CHECK_PHASE ?= all
ISLED_CHECK_PROGRAM ?=
export ISLED_CHECK_PHASE ISLED_CHECK_PROGRAM

.PHONY: check package
check:
	"$(ISLED_EMACS)" -Q --batch --load test/run-check.el

package: $(ARCHIVE)

$(ARCHIVE): $(FILES) ../../LICENSE ../../scripts/package-emacs.py
	python3 ../../scripts/package-emacs.py
