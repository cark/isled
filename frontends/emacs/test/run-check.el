;;; run-check.el --- Isolated contributor validation entry -*- lexical-binding: t; -*-

;;; Commentary:

;; Load with emacs -Q --batch -l frontends/emacs/test/run-check.el.
;; Dependencies come from explicit package/load paths or the optional Nix shell.

;;; Code:

(require 'package)
(require 'subr-x)

(defun isled-check-env (name)
  "Return nonempty environment variable NAME, or nil."
  (let ((value (getenv name)))
    (and value (not (string-empty-p value)) value)))

(when-let ((directory (isled-check-env "ISLED_CHECK_PACKAGE_DIR")))
  (setq package-user-dir (expand-file-name directory)
        package-directory-list nil)
  (package-initialize))

(when-let ((paths (isled-check-env "ISLED_CHECK_LOAD_PATH")))
  (dolist (directory (reverse (split-string paths (regexp-quote path-separator) t)))
    (add-to-list 'load-path (expand-file-name directory))))

(let* ((directory (file-name-directory (or load-file-name buffer-file-name)))
       (phase (isled-check-env "ISLED_CHECK_PHASE"))
       (roots (delq nil (mapcar #'isled-check-env
                               '("ISLED_MARKDOWN_MODE_ROOT" "ISLED_TRANSIENT_ROOT")))))
  (unless (member phase '(nil "all" "static" "tests"))
    (error "Invalid ISLED_CHECK_PHASE: %s" phase))
  (load (expand-file-name "check.el" directory) nil t)
  ;; Dependency roots also apply to a tests-only run.
  (dolist (root roots)
    (add-to-list 'load-path (isled-check--package-directory root)))
  (prin1 (isled-check-run
          (isled-check-env "ISLED_CHECK_PROGRAM")
          (isled-check-env "ISLED_PACKAGE_LINT_ROOT") roots
          (cond ((equal phase "static") 'static)
                ((equal phase "tests") 'tests))))
  (terpri))

;;; run-check.el ends here
