;;; cli-install-staged.el --- Install the package and staged CLI -*- lexical-binding: t; -*-

;;; Commentary:
;; The Python runner serves verified assets over loopback.  Only the URL fetch
;; destination is substituted here; production origin, integrity, extraction,
;; version checking and command startup run unchanged.  No public release needed.

;;; Code:
(require 'cl-lib)
(require 'package)
(require 'url-http)

(unless (and noninteractive (getenv "ISLED_INSTALL_CHECK_DIR"))
  (error "Run this check only through check-cli-installer.py in fresh batch Emacs"))

(let* ((root (getenv "ISLED_INSTALL_CHECK_DIR"))
       (user-emacs-directory (expand-file-name "emacs/" root))
       (package-user-dir (expand-file-name "packages" user-emacs-directory))
       (package-directory-list (list (getenv "ISLED_CHECK_PACKAGE_DIR")))
       (package-check-signature nil) (package-native-compile nil)
       (custom-file (expand-file-name "custom.el" root))
       (offline (equal (getenv "ISLED_INSTALL_CHECK_MODE") "offline"))
       (retriever (symbol-function 'url-retrieve))
       (offers 0) requests)
  ;; Replace the package directory between processes: the managed CLI must survive.
  (when (file-exists-p package-user-dir) (delete-directory package-user-dir t))
  (make-directory user-emacs-directory t)
  (package-initialize)
  (cl-letf (((symbol-function 'url-retrieve) (lambda (&rest _) (error "Download during package load")))
            ((symbol-function 'make-process) (lambda (&rest _) (error "Process during package load"))))
    (package-install-file (getenv "ISLED_PACKAGE_ARCHIVE"))
    (require 'isled)
    (require 'isled-process))
  (unless (file-in-directory-p (locate-library "isled-cli") package-user-dir)
    (error "Installer is not in the constructed package"))
  (let ((isled-program nil)
        (isled-cli-directory (expand-file-name "cli" user-emacs-directory)))
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) (cl-incf offers) t))
              ((symbol-function 'url-retrieve)
               (lambda (url callback &rest arguments)
                 (when offline (error "Offline reuse attempted a download"))
                 (unless (string-prefix-p "https://github.com/cark/isled/releases/download/" url)
                   (error "Unexpected production asset URL: %s" url))
                 (push url requests)
                 (apply retriever
                        (concat (getenv "ISLED_INSTALL_TEST_ORIGIN") "/" (file-name-nondirectory url))
                        callback arguments))))
      (let ((noninteractive nil) program failure done)
        (isled-cli-ensure (lambda (path error) (setq program path failure error done t)))
        (let ((deadline (+ (float-time) 120)))
          (while (and (not done) (< (float-time) deadline)) (accept-process-output nil 0.05)))
        (unless (and done program (not failure)) (error "Provisioning failed: %S" failure))
        (unless (and (= offers (if offline 0 1)) (= (length requests) (if offline 0 3)))
          (error "Unexpected consent or fetch count: %s %s" offers (length requests)))
        (unless (file-in-directory-p program isled-cli-directory) (error "CLI escaped managed storage"))
        ;; Exercise real command startup with no explicit executable configured.
        (let ((ledger (expand-file-name (if offline "ledger-offline" "ledger") root)) result)
          (make-directory ledger t)
          (isled-process-command ledger (list "--root" ledger "init") nil
                                 (lambda (value) (setq result value)))
          (let ((deadline (+ (float-time) 10)))
            (while (and (not result) (< (float-time) deadline)) (accept-process-output nil 0.05)))
          (unless (and result (zerop (isled-command-result-status result)))
            (error "Managed CLI command failed: %S" result))
          (unless (isled-snapshot-p (isled-snapshot-load ledger)) (error "Cannot read managed CLI snapshot")))
        (message "Staged installer passed: %s, %s, Emacs %s" (if offline "offline cache reuse" "first use") program emacs-version)))))

;;; cli-install-staged.el ends here
