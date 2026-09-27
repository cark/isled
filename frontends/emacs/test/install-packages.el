;;; install-packages.el --- Isolated check dependencies -*- lexical-binding: t; -*-

;;; Commentary:

;; Run explicitly with emacs -Q --batch.  This installs stable archive packages
;; only into ISLED_CHECK_PACKAGE_DIR, never the user's normal package directory.

;;; Code:

(require 'package)

;; Preserve the original download/signature error instead of package.el's
;; generic "Failed to download archive" message in unattended checks.
(setq debug-on-error t)

(when-let ((program (getenv "ISLED_CHECK_GPG")))
  (setq epg-gpg-program program))

(let ((directory (getenv "ISLED_CHECK_PACKAGE_DIR")))
  (unless (and directory (not (equal directory "")))
    (error "Set ISLED_CHECK_PACKAGE_DIR to an isolated dependency directory"))
  (setq package-user-dir (expand-file-name directory)
        package-directory-list nil
        package-install-upgrade-built-in t
        package-native-compile nil
        package-archives '(("gnu" . "https://elpa.gnu.org/packages/")
                           ("nongnu" . "https://elpa.nongnu.org/nongnu/"))))

(package-initialize)
(condition-case failure
    (package-refresh-contents)
  (error
   (when-let ((details (get-buffer "*Error*")))
     (princ (with-current-buffer details (buffer-string))))
   (signal (car failure) (cdr failure))))
(dolist (name '(markdown-mode transient package-lint))
  (package-install name))

;; Archive contents can advance independently; retain the resolved versions in
;; each run's log, including transitive dependencies.
(dolist (entry package-alist)
  (let ((descriptor (cadr entry)))
    (message "Check dependency: %s %s" (car entry)
             (package-version-join (package-desc-version descriptor)))))

;;; install-packages.el ends here
