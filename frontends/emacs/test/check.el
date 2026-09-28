;;; check.el --- Validate the isled Emacs frontend  -*- lexical-binding: t; -*-

;;; Commentary:

;; One callable validation entry point for agents and maintainers.  This file
;; runs in a fresh headless Emacs and never loads the user's configuration.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'package)
(require 'seq)

(defconst isled-check--test-directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing the frontend validation entry point.")

(defun isled-check-run (&optional program package-lint-root dependency-roots phase)
  "Validate the frontend with PROGRAM, PACKAGE-LINT-ROOT and DEPENDENCY-ROOTS.

PROGRAM is the executable used by the integration test.  PACKAGE-LINT-ROOT is
an optional package directory or Nix package root supplying Package-lint.
DEPENDENCY-ROOTS optionally supply Markdown mode and Transient directories.
Otherwise the explicitly configured package/load paths supply dependencies.
PHASE is nil for all checks, static for compilation/lint, or tests for ERT."
  (let* ((test-directory isled-check--test-directory)
         (source-directory
          (file-name-directory (directory-file-name test-directory)))
         (repository-root (expand-file-name "../../.." test-directory))
         (program (or program
                      (expand-file-name (concat "target/debug/isled"
                                                (if (eq system-type 'windows-nt)
                                                    ".exe" ""))
                                        repository-root)))
         (load-path (append (list source-directory test-directory) load-path))
         (load-prefer-newer t)
         (source-files
          (mapcar (lambda (name) (expand-file-name name source-directory))
                  '("isled.el"
                    "isled-release.el"
                    "isled-archive.el"
                    "isled-download.el"
                    "isled-executable.el"
                    "isled-install.el"
                    "isled-bundle.el"
                    "isled-installation-view.el"
                    "isled-installation.el"
                    "isled-cli.el"
                    "isled-snapshot.el"
                    "isled-graph-model.el"
                    "isled-graph-drawing.el"
                    "isled-graph-glyphs.el"
                    "isled-graph-gutter.el"
                    "isled-graph.el"
                    "isled-view.el"
                    "isled-presentation.el"
                    "isled-rows.el"
                    "isled-fold.el"
                    "isled-sections.el"
                    "isled-header.el"
                    "isled-warnings.el"
                    "isled-jump.el"
                    "isled-auto-refresh.el"
                    "isled-frontend.el"
                    "isled-process.el"
                    "isled-sequence.el"
                    "isled-data.el"
                    "isled-windows.el"
                    "isled-viewport.el"
                    "isled-session.el"
                    "isled-navigation.el"
                    "isled-source.el"
                    "isled-file-routing.el"
                    "isled-file-visit.el"
                    "isled-filter-query.el"
                    "isled-filter-completion.el"
                    "isled-filter-display.el"
                    "isled-filter-preview.el"
                    "isled-filter-inline.el"
                    "isled-filter-picker.el"
                    "isled-filter-minibuffer.el"
                    "isled-filter.el"
                    "isled-expansion.el"
                    "isled-loading.el"
                    "isled-context.el"
                    "isled-initialize.el"
                    "isled-buffers.el"
                    "isled-entry.el"
                    "isled-browser.el"
                    "isled-editor-model.el"
                    "isled-editor-form.el"
                    "isled-editor-completion.el"
                    "isled-editor-feedback.el"
                    "isled-editor.el")))
         (main-file (expand-file-name "isled.el" source-directory))
         (elisp-files
          (directory-files-recursively source-directory (rx ".el" eos)))
         (destination (make-temp-file "isled-byte-compile-" t))
         (package-alist (copy-tree package-alist))
         (byte-compile-error-on-warn t)
         (byte-compile-dest-file-function
          (lambda (source)
            (expand-file-name
             (concat (file-name-base source) ".elc") destination))))
    (unwind-protect
        (progn
          (unless (eq phase 'tests)
            (when package-lint-root
              (add-to-list 'load-path
                           (isled-check--package-directory package-lint-root)))
            (dolist (root dependency-roots)
              (add-to-list 'load-path (isled-check--package-directory root)))
            (require 'package-lint)
            (dolist (library '("markdown-mode" "transient"))
              (let ((file (locate-library library)))
                (unless file (error "Missing validation dependency: %s" library))
                (package-load-descriptor (file-name-directory file))))
            (dolist (file elisp-files)
              (with-temp-buffer
                (insert-file-contents file)
                (check-parens)))
            (dolist (file source-files)
              (unless (byte-compile-file file)
                (error "Byte compilation failed: %s" file))
              (checkdoc-file file)
              (with-temp-buffer
                  (insert-file-contents file)
                  (setq buffer-file-name file)
                  (emacs-lisp-mode)
                  (set-buffer-modified-p nil)
                  (unwind-protect
                      (let ((package-lint-main-file
                             (unless (equal file main-file) main-file)))
                        (when-let ((findings (package-lint-buffer)))
                          (error "Package lint failed for %s: %S"
                                 file findings)))
                    (set-buffer-modified-p nil)))))
          (if (eq phase 'static)
              (list :checked-files (length elisp-files) :phase phase)
            (progn
              (dolist (file source-files)
                (load file nil t))
              (dolist (test (ert-select-tests "^isled-" t))
                (ert-delete-test (ert-test-name test)))
              (load (expand-file-name "isled-download-test.el" test-directory) nil t)
              (load (expand-file-name "isled-executable-test.el" test-directory) nil t)
              (load (expand-file-name "isled-install-test.el" test-directory) nil t)
              (load (expand-file-name "isled-installation-view-test.el" test-directory) nil t)
              (load (expand-file-name "isled-snapshot-test.el"
                                      test-directory)
                    nil t)
              (load (expand-file-name "isled-view-test.el"
                                      test-directory)
                    nil t)
              (load (expand-file-name "isled-sections-test.el"
                                      test-directory)
                    nil t)
              (load (expand-file-name "isled-appearance-test.el"
                                      test-directory)
                    nil t)
              (load (expand-file-name "isled-auto-refresh-test.el" test-directory)
                    nil t)
              (load (expand-file-name "isled-auto-refresh-integration-test.el" test-directory)
                    nil t)
              (load (expand-file-name "isled-test.el" test-directory)
                    nil t)
              (load (expand-file-name "isled-recovery-test.el" test-directory)
                    nil t)
              (load (expand-file-name "isled-filter-test.el" test-directory)
                    nil t)
              (load (expand-file-name "isled-header-test.el" test-directory)
                    nil t)
              (load (expand-file-name "isled-loading-fixture.el" test-directory) nil t)
              (load (expand-file-name "isled-loading-test.el" test-directory) nil t)
              (load (expand-file-name "isled-graph-glyphs-test.el" test-directory) nil t)
              (load (expand-file-name "isled-graph-test.el" test-directory) nil t)
              (load (expand-file-name "isled-graph-drawing-test.el" test-directory) nil t)
              (load (expand-file-name "isled-navigation-test.el" test-directory) nil t)
          (load (expand-file-name "isled-warnings-test.el" test-directory) nil t)
          (load (expand-file-name "isled-jump-test.el" test-directory) nil t)
              (load (expand-file-name "isled-filter-interaction-test.el" test-directory) nil t)
              (load (expand-file-name "isled-filter-interfaces-test.el" test-directory) nil t)
              (load (expand-file-name "isled-filter-preview-test.el" test-directory) nil t)
              (load (expand-file-name "isled-expansion-test.el" test-directory) nil t)
              (load (expand-file-name "isled-sequence-test.el" test-directory) nil t)
              (load (expand-file-name "isled-row-update-test.el" test-directory) nil t)
              (load (expand-file-name "isled-fold-test.el" test-directory) nil t)
              (load (expand-file-name "isled-data-test.el" test-directory) nil t)
              (load (expand-file-name "isled-session-test.el" test-directory) nil t)
              (load (expand-file-name "isled-buffers-test.el" test-directory) nil t)
              (load (expand-file-name "isled-project-test.el" test-directory) nil t)
              (load (expand-file-name "isled-entry-test.el" test-directory) nil t)
              (load (expand-file-name "isled-editor-test.el" test-directory) nil t)
              (load (expand-file-name "isled-keymap-test.el" test-directory) nil t)
              (load (expand-file-name "isled-source-test.el" test-directory) nil t)
              (load (expand-file-name "isled-file-routing-test.el" test-directory) nil t)
              (load (expand-file-name "isled-file-visit-test.el" test-directory) nil t)
              (load (expand-file-name "isled-windows-test.el" test-directory) nil t)
              (load (expand-file-name "isled-viewport-test.el" test-directory) nil t)
              (let* ((isled-process-function #'isled-test-process)
                     (isled-test-program program)
                     (isled-use-development-cli t)
                     (stats (ert-run-tests-batch "^isled-"))
                     (unexpected (ert-stats-completed-unexpected stats)))
                (unless (zerop unexpected)
                  (error "%d isled ERT tests were unexpected" unexpected))
                (list :checked-files (length elisp-files)
                      :ert-tests (ert-stats-total stats)
                      :unexpected unexpected
                      :package-lint (not (eq phase 'tests))
                      :integration-program program)))))
      (delete-directory destination t))))

(defun isled-check--package-directory (root)
  "Return the package directory for direct package or Nix package ROOT."
  (if (directory-files root nil (rx "-pkg.el" eos))
      root
    (let ((directories
         (seq-filter
          #'file-directory-p
          (directory-files
           (expand-file-name "share/emacs/site-lisp/elpa" root)
           t (rx bos (not "."))))))
    (unless (= (length directories) 1)
      (error "Expected one ELPA package under %s, found %d"
             root (length directories)))
      (car directories))))

(provide 'isled-check)
;;; check.el ends here
