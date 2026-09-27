;;; package-recipes.el --- Isolated package installation checks -*- lexical-binding: t; -*-

;;; Commentary:

;; Invoked by scripts/check-package-recipes.py with owned directories and refs.
;; Never load this into an existing editor.  Logs and receipts stay in the fixture.

;;; Code:

(unless (and noninteractive (getenv "ISLED_RECIPE_CHECK_DIR"))
  (error "Run through scripts/check-package-recipes.py in an isolated batch Emacs"))

(require 'cl-lib)
(require 'json)
(require 'lisp-mnt)
(require 'package)

(setq debug-on-error t
      user-emacs-directory (file-name-as-directory
                            (expand-file-name "emacs" (getenv "ISLED_RECIPE_CHECK_DIR")))
      package-user-dir (expand-file-name "elpa" user-emacs-directory)
      package-directory-list nil
      package-native-compile nil
      native-comp-jit-compilation nil
      custom-file (expand-file-name "custom.el" user-emacs-directory))
(make-directory user-emacs-directory t)
(when (fboundp 'startup-redirect-eln-cache)
  (startup-redirect-eln-cache (expand-file-name "eln" user-emacs-directory)))
(load (expand-file-name "package-recipe-managers.el" (file-name-directory load-file-name)) nil t)

(defun isled-recipe-git (directory &rest arguments)
  "Run Git in DIRECTORY and return the output for ARGUMENTS."
  (with-temp-buffer
    (unless (zerop (apply #'call-process "git" nil t nil "-C" directory arguments))
      (error "Git failed: %s" (buffer-string)))
    (string-trim (buffer-string))))

(let* ((manager (getenv "ISLED_RECIPE_MANAGER"))
       (source (funcall (intern (concat "isled-recipe-" manager))))
       (revision (isled-recipe-git source "rev-parse" "HEAD"))
       (expected (getenv "ISLED_RECIPE_REVISION")))
  (unless (equal revision expected) (error "Recipe checked out %s, expected %s" revision expected))
  ;; Loading the installed package must not provision or execute the CLI.
  (cl-letf (((symbol-function 'url-retrieve) (lambda (&rest _) (error "Download during load")))
            ((symbol-function 'url-retrieve-synchronously) (lambda (&rest _) (error "Download during load")))
            ((symbol-function 'call-process) (lambda (&rest _) (error "Process during load")))
            ((symbol-function 'make-process) (lambda (&rest _) (error "Process during load"))))
    (require 'isled)
    (require 'isled-browser)
    (require 'isled-editor))
  (let* ((library (locate-library "isled"))
         (directory (file-name-directory library))
         (pin (symbol-value 'isled-required-cli-version))
         (expected-files (directory-files
                          (expand-file-name "frontends/emacs" (getenv "ISLED_RECIPE_ROOT"))
                          nil "\\`isled.*\\.el\\'")))
    (unless (and (file-in-directory-p library user-emacs-directory)
                 (string-suffix-p ".elc" library)
                 (equal pin (getenv "ISLED_RECIPE_CLI_PIN")))
      (error "Wrong installed library, bytecode or CLI pin: %s %s" library pin))
    (dolist (name expected-files)
      (unless (and (file-exists-p (expand-file-name name directory))
                   (file-exists-p (expand-file-name (concat name "c") directory)))
        (error "Recipe omitted library or bytecode for %s" name)))
    (dolist (dependency '((markdown-mode . "2.6") (transient . "0.8.0")))
      (let ((file (locate-library (symbol-name (car dependency)))))
        (unless file (error "Missing dependency %s" (car dependency)))
        (with-temp-buffer
          (insert-file-contents (concat (file-name-sans-extension file) ".el"))
          (let ((version (or (lm-header "package-version") (lm-header "version"))))
            (unless (and version (version<= (cdr dependency) version))
              (error "Old dependency %s: %s" (car dependency) version))
            (message "Installed dependency %s %s from %s" (car dependency) version file)))))
    (when (equal manager "melpa")
      (let ((version (package-version-join (package-desc-version (cadr (assq 'isled package-alist))))))
        (when (and (equal (getenv "ISLED_RECIPE_SELECTOR") "development")
                   (equal version pin))
          (error "MELPA did not assign its snapshot version"))
        (message "MELPA package %s independently pins CLI %s" version pin)))
    (with-temp-file (expand-file-name "receipt.json" (getenv "ISLED_RECIPE_CHECK_DIR"))
      (insert (json-encode
               `((manager . ,manager) (selector . ,(getenv "ISLED_RECIPE_SELECTOR"))
                 (revision . ,revision) (cli_pin . ,pin) (library . ,library)
                 (emacs . ,emacs-version)))))
    (message "Recipe acceptance passed: %s %s" manager (getenv "ISLED_RECIPE_SELECTOR"))))

;;; package-recipes.el ends here
