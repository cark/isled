;;; cli-install-staged.el --- Native staged installation acceptance -*- lexical-binding: t; -*-

;;; Commentary:
;; The Python runner serves verified release assets over loopback.  Only the
;; request destination changes; selection, verification and execution are real.
;; Each case gets a fresh editor and package directory.  No compiler is on PATH.

;;; Code:
(require 'cl-lib)
(require 'package)
(require 'url-http)

(unless (and noninteractive (getenv "ISLED_INSTALL_CHECK_DIR"))
  (error "Run this check only through check-cli-installer.py in fresh batch Emacs"))

(defun isled-install-check--wait (predicate)
  "Wait a bounded interval for PREDICATE, servicing normal process callbacks."
  (let ((deadline (+ (float-time) 130)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.05)))
  (unless (funcall predicate) (error "Staged installer callback timed out")))

(let* ((root (getenv "ISLED_INSTALL_CHECK_DIR"))
       (user-emacs-directory (expand-file-name "emacs/" root))
       (package-user-dir (expand-file-name "packages" user-emacs-directory))
       (package-directory-list (list (getenv "ISLED_CHECK_PACKAGE_DIR")))
       (package-check-signature nil) (package-native-compile nil)
       (custom-file (expand-file-name "custom.el" root))
       (exec-path nil)
       (mode (getenv "ISLED_INSTALL_CHECK_MODE"))
       (isolated (member mode '("decline" "missing" "cancel" "unsupported")))
       (offline (member mode '("offline" "rollback" "explicit" "mismatch")))
       (failure-pattern (cdr (assoc mode '(("decline" . "declined") ("missing" . "HTTP 404")
                                          ("cancel" . "cancel") ("corrupt" . "mismatch")
                                          ("interrupted" . ".") ("mismatch" . "Expected Isled")
                                          ("unsupported" . "No Isled binary")))))
       (retriever (symbol-function 'url-retrieve))
       (launcher (symbol-function 'make-process))
       (offers 0) (executions 0) requests holder)
  (when (cl-some #'executable-find '("isled" "cargo" "rustc"))
    (error "CLI or Rust compiler is visible in the clean acceptance environment"))
  ;; Package replacement must not remove the CLI or the consent it shares.
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
  (let* ((isled-program nil)
         (isled-cli-directory (expand-file-name (if isolated (concat "cli-" mode) "cli") user-emacs-directory))
         (old (expand-file-name (isled-release-executable (isled-release-current-target))
                                (isled-install-directory isled-cli-directory
                                                         (getenv "ISLED_INSTALL_BASE_VERSION")
                                                         (isled-release-current-target))))
         (old-hash (and (file-exists-p old) (secure-hash 'sha256 (isled-install--read old))))
         (consented (file-exists-p (expand-file-name "download-consent" isled-cli-directory))))
    (when (member mode '("explicit" "mismatch")) (setq isled-program old))
    (unwind-protect
        (progn
          ;; frontend waits for stdin, keeping the old Windows executable in use.
          (when (equal mode "upgrade")
            (setq holder (make-process :name "isled-held-old-cli" :buffer nil
                                       :command (list old "--root" root "frontend" "--stdin")
                                       :connection-type 'pipe :noquery t))
            (accept-process-output holder 0.05)
            (unless (process-live-p holder) (error "Previous CLI did not remain running")))
          (cl-letf (((symbol-function 'y-or-n-p)
                     (lambda (&rest _) (cl-incf offers) (not (equal mode "decline"))))
                    ((symbol-function 'make-process)
                     (lambda (&rest arguments)
                       (cl-incf executions)
                       (unless (file-name-absolute-p (car (plist-get arguments :command)))
                         (error "Setup attempted an external tool from PATH"))
                       (apply launcher arguments)))
                    ((symbol-function 'url-retrieve)
                     (lambda (url callback &rest arguments)
                       (when offline (error "Cached or explicit executable attempted a download"))
                       (unless (string-prefix-p "https://github.com/cark/isled/releases/download/" url)
                         (error "Unexpected production asset URL: %s" url))
                       (push url requests)
                       (apply retriever
                              (concat (getenv "ISLED_INSTALL_TEST_ORIGIN") "/" mode "/"
                                      (file-name-nondirectory url)) callback arguments))))
            (let ((noninteractive nil) program failure done)
              (let ((system-configuration (if (equal mode "unsupported") "unsupported" system-configuration)))
                (isled-cli-ensure (lambda (path error) (setq program path failure error done t))))
              (when (equal mode "cancel") (isled-cancel-setup))
              (isled-install-check--wait (lambda () done))
              (unless (= offers (if (or consented (equal mode "unsupported")) 0 1))
                (error "Unexpected consent count in %s: %s" mode offers))
              (if failure-pattern
                  (progn
                    (unless (and (null program) failure (string-match-p failure-pattern failure))
                      (error "Expected setup failure in %s, got %S %S" mode program failure))
                    (unless (or (equal mode "mismatch") (zerop executions))
                      (error "Failed setup executed a binary before integrity verification"))
                    (when isled-cli--pending (error "Failure left setup pending"))
                    (when (and (file-directory-p isled-cli-directory)
                               (directory-files isled-cli-directory nil "\\`\\.install-"))
                      (error "Failed setup left a partial installation")))
                (unless (and program (not failure)) (error "Provisioning failed: %S" failure))
                (unless (= (length requests) (if offline 0 3))
                  (error "Unexpected download count: %s" (length requests)))
                (unless (file-in-directory-p program isled-cli-directory) (error "CLI escaped managed storage"))
                (unless (file-exists-p (expand-file-name "LICENSE" (file-name-directory program)))
                  (error "Installed executable has no license"))
                (let ((ledger (expand-file-name (concat "ledger-" mode) root)) result)
                  (make-directory ledger t)
                  (isled-process-command ledger (list "--root" ledger "init") nil
                                         (lambda (value) (setq result value)))
                  (isled-install-check--wait (lambda () result))
                  (unless (zerop (isled-command-result-status result))
                    (error "Managed CLI command failed: %S" result))
                  (unless (isled-snapshot-p (isled-snapshot-load ledger)) (error "Cannot read managed snapshot"))))
              (when (and old-hash (not (equal old-hash (secure-hash 'sha256 (isled-install--read old)))))
                (error "Setup changed the previous executable"))
              (when (and holder (not (process-live-p holder)))
                (error "Upgrade interrupted the previous executable"))
              (message "Staged installer passed: %s, CLI %s, Emacs %s, %s"
                       mode isled-required-cli-version emacs-version system-configuration))))
      (when (and holder (process-live-p holder)) (delete-process holder)))))

;;; cli-install-staged.el ends here
