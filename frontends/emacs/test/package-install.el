;;; package-install.el --- Check the constructed package  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run in fresh emacs -Q --batch.  ISLED_PACKAGE_ARCHIVE selects the tar;
;; ISLED_CHECK_PACKAGE_DIR supplies already installed dependencies.  This check
;; installs only into a temporary directory and performs no downloads.

;;; Code:

(require 'cl-lib)
(require 'package)

(let* ((archive (or (getenv "ISLED_PACKAGE_ARCHIVE") (error "Missing package archive")))
       (dependencies (or (getenv "ISLED_CHECK_PACKAGE_DIR") (error "Missing isolated dependencies")))
       (package-user-dir (make-temp-file "isled-package-install-" t))
       (package-directory-list (list (expand-file-name dependencies)))
       (package-check-signature nil)
       (package-native-compile nil))
  (unwind-protect
      (cl-letf (((symbol-function 'url-retrieve-synchronously)
                 (lambda (&rest _) (error "Package check attempted a download"))))
        (package-initialize)
        (package-install-file (expand-file-name archive))
        (let* ((descriptor (cadr (assq 'isled package-alist)))
               (directory (package-desc-dir descriptor))
               (version (package-version-join (package-desc-version descriptor))))
          (unless (file-in-directory-p directory package-user-dir)
            (error "Package escaped isolated installation directory"))
          (require 'isled)
          (unless (and (equal version (symbol-value 'isled-required-cli-version))
                       (file-in-directory-p (locate-library "isled") directory)
                       (file-exists-p (expand-file-name "isled.elc" directory)))
            (error "Wrong installed package identity or missing bytecode"))
          (message "Installed and loaded constructed Isled %s package" version)))
    (delete-directory package-user-dir t)))

;;; package-install.el ends here
