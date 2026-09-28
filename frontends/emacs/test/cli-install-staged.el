;;; cli-install-staged.el --- Native staged installation acceptance -*- lexical-binding: t; -*-

;;; Commentary:
;; The Python runner selects staged loopback or public HTTPS delivery.  Selection,
;; verification and execution are real in either case.
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

(defun isled-install-check--paths (program root command)
  "Run PROGRAM's installation COMMAND for ROOT and await its path report."
  (let (done paths failure)
    (isled-installation-run program root command
                            (lambda (result problem) (setq paths result failure problem done t)))
    (isled-install-check--wait (lambda () done))
    (when failure (error "%s" failure))
    paths))

(let* ((root (getenv "ISLED_INSTALL_CHECK_DIR"))
       (user-emacs-directory (expand-file-name "emacs/" root))
       (package-user-dir (expand-file-name "packages" user-emacs-directory))
       (package-directory-list (list (getenv "ISLED_CHECK_PACKAGE_DIR")))
       (package-check-signature nil) (package-native-compile nil)
       (custom-file (expand-file-name "custom.el" root))
       (exec-path nil)
       (mode (getenv "ISLED_INSTALL_CHECK_MODE"))
       (isolated (member mode '("missing" "cancel" "unsupported")))
       (offline (member mode '("offline" "rollback" "explicit" "mismatch")))
       (failure-pattern (cdr (assoc mode '(("missing" . "HTTP 404")
                                          ("cancel" . "cancel") ("corrupt" . "mismatch")
                                          ("interrupted" . ".") ("mismatch" . "Expected Isled")
                                          ("unsupported" . "No Isled binary")))))
       (retriever (symbol-function 'url-retrieve))
       (launcher (symbol-function 'make-process))
       (executions 0) requests holder)
  (when (cl-some #'executable-find '("isled" "cargo" "rustc"))
    (error "CLI or Rust compiler is visible in the clean acceptance environment"))
  ;; Package replacement must not remove the shared CLI installation.
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
                                                         (getenv "ISLED_INSTALL_BASE_VERSION"))))
         (old-hash (and (file-exists-p old) (secure-hash 'sha256 (isled-install--read old)))))
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
                     (lambda (&rest _) (error "CLI setup requested confirmation")))
                    ((symbol-function 'make-process)
                     (lambda (&rest arguments)
                       (cl-incf executions)
                       (unless (file-name-absolute-p (car (plist-get arguments :command)))
                         (error "Setup attempted an external tool from PATH"))
                       (apply launcher arguments)))
                    ((symbol-function 'url-retrieve)
                     (lambda (url callback &rest arguments)
                       (when offline (error "Cached or explicit executable attempted a download"))
                       (let* ((origin (getenv "ISLED_INSTALL_TEST_ORIGIN"))
                              (staged (and origin (not (string-empty-p origin))))
                              (asset (string-prefix-p "https://github.com/cark/isled/releases/download/" url)))
                         (when (and staged (not asset)) (error "Unexpected staged asset URL"))
                         ;; Count asset requests, not the redirects validated by
                         ;; the production downloader before it calls us.
                         (when asset (push url requests))
                         (apply retriever
                                (if staged
                                    (concat origin "/" mode "/" (file-name-nondirectory url))
                                  url)
                                callback arguments)))))
            (let (program failure done)
              (let ((system-configuration (if (equal mode "unsupported") "unsupported" system-configuration)))
                (isled-cli-ensure (lambda (path error) (setq program path failure error done t))))
              (when (equal mode "cancel") (isled-cancel-setup))
              (isled-install-check--wait (lambda () done))
              (when (file-exists-p (expand-file-name "download-consent" isled-cli-directory))
                (error "Automatic setup wrote a consent file"))
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
                (unless isled-program
                  (let* ((paths (isled-install-check--paths program isled-cli-directory "installation"))
                         (skill (alist-get 'skill paths)))
                    (unless (equal (alist-get 'version paths) isled-required-cli-version)
                      (error "Current bundle does not match the activated frontend"))
                    (dolist (name '("SKILL.md" "references/mutations.md" "references/recovery.md"))
                      (unless (file-regular-p (expand-file-name name skill))
                        (error "Installed bundle is missing skill file %s" name)))
                    (when (get-buffer "*Isled installation*") (kill-buffer "*Isled installation*"))
                    (isled-show-installation)
                    (isled-install-check--wait (lambda () (get-buffer "*Isled installation*")))
                    (with-current-buffer "*Isled installation*"
                      (dolist (key '(executable skill skill_file path_directory))
                        (unless (string-match-p (regexp-quote (alist-get key paths)) (buffer-string))
                          (error "Copyable installation buffer omits %s" key))))))
                (when (equal mode "upgrade")
                  ;; A standalone rollback cannot redirect this running frontend.
                  (isled-install-check--paths old isled-cli-directory "install")
                  (let (again problem ready)
                    (isled-cli-ensure (lambda (path failure) (setq again path problem failure ready t)))
                    (isled-install-check--wait (lambda () ready))
                    (unless (and (not problem) (equal again program))
                      (error "Changing current redirected the frontend")))
                  (unless (equal (alist-get 'version (isled-install-check--paths program isled-cli-directory "installation"))
                                 (getenv "ISLED_INSTALL_BASE_VERSION"))
                    (error "Ordinary frontend reuse changed the standalone selection"))
                  (isled-install-check--paths program isled-cli-directory "install"))
                (let ((coding-system-for-write 'utf-8-unix))
                  (with-temp-file (expand-file-name "program" root) (insert program "\n")))
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
