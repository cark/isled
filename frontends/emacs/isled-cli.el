;;; isled-cli.el --- Resolve the compatible CLI on first use -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Assisted-by: Codex:GPT-6
;; Keywords: tools

;;; Commentary:
;; Package managers install Lisp.  This module owns consent and shared first-use
;; readiness for managed releases and explicitly configured executables.

;;; Code:
(require 'isled-install)

(defgroup isled nil "Browse local isled ledgers." :group 'tools :prefix "isled-")

(defcustom isled-program nil
  "Explicit Isled executable, or nil to manage the pinned release automatically.
A command name is resolved through PATH.  Explicit executables are checked,
never replaced or bypassed by automatic downloads."
  :type '(choice (const :tag "Managed release" nil) file) :group 'isled)

(defcustom isled-use-development-cli nil
  "Allow an explicitly configured same-version -dev CLI from this checkout.
This is for contributors.  It never relaxes the required version or enables
building from source automatically."
  :type 'boolean :group 'isled)

(defcustom isled-cli-directory nil
  "Installation directory, or nil for the CLI's platform user-data default.
Explicit locations are respected.  The previous default cache remains available
for old frontend versions; new releases use the shared executable/skill layout."
  :type '(choice (const :tag "Platform default" nil) directory) :group 'isled)

(defvar isled-required-cli-version)
(defvar isled-cli--pending nil "The active shared CLI readiness request, if any.")
(defvar isled-cli--activated (make-hash-table :test #'equal)
  "Exact executables already selected by this editor session.")

(cl-defstruct (isled-cli--job (:constructor isled-cli--job-create))
  "One shared readiness request and its waiting command callbacks."
  key callbacks cancel)

(defun isled-cli--finish (job program failure)
  "Complete JOB once, delivering PROGRAM or FAILURE to every waiting command."
  (when (eq job isled-cli--pending)
    (setq isled-cli--pending nil)
    (dolist (callback (nreverse (isled-cli--job-callbacks job)))
      (condition-case problem (funcall callback program failure)
        (error (message "Isled command callback failed: %s" (error-message-string problem)))))))

(defun isled-cli--consent (root version)
  "Ensure persistent managed-download consent under ROOT for VERSION."
  (let ((file (expand-file-name "download-consent" root))
        (text "Download pinned Isled releases from cark/isled on GitHub.\n"))
    (unless (and (file-exists-p file) (equal (isled-install--read file) text))
      (when (or noninteractive
                (not (y-or-n-p (format "Download Isled %s from GitHub now and matching CLI updates on future use? " version))))
        (user-error "Isled download declined; invoke the command again to retry, or set isled-program"))
      (make-directory root t)
      (set-file-modes root #o700)
      (isled-install--write file text))))

(defun isled-cli--prepare (job version program development root)
  "Prepare JOB for VERSION using PROGRAM/DEVELOPMENT or managed ROOT."
  (let ((callback (lambda (path failure)
                    (when (and path (not program)) (puthash path t isled-cli--activated))
                    (isled-cli--finish job path failure))))
    (setf (isled-cli--job-cancel job)
          (if program
              (let ((path (if (file-name-directory program) (expand-file-name program)
                            (executable-find program))))
                (unless (and path (not (file-remote-p path)))
                  (error "Cannot find local Isled executable %s; check isled-program" program))
                (isled-executable-verify path version development callback))
            (let* ((target (isled-release-current-target))
                   (cached (isled-install-cached root version target)))
              (if cached (isled-cli--cached cached root version callback)
                (unless (and (fboundp 'zlib-available-p) (zlib-available-p)
                             (gnutls-available-p))
                  (error "Managed Isled downloads need Emacs with built-in TLS and zlib support; alternatively set isled-program"))
                (isled-cli--consent (if isled-cli-directory root
                                      (locate-user-emacs-file "isled/cli/")) version)
                (isled-install root version target callback)))))))

(defun isled-cli--cached (program root version callback)
  "Verify cached PROGRAM for VERSION and activate it under ROOT once per session.
Deliver its exact path to CALLBACK; other installations cannot redirect it."
  (let (verification-cancel installation-cancel finished)
    (setq verification-cancel
          (isled-executable-verify
           program version nil
           (lambda (path failure)
             (unless finished
               (if (or failure (gethash program isled-cli--activated))
                   (progn (setq finished t) (funcall callback path failure))
                 (setq installation-cancel
                       (isled-installation-run
                        program root "install"
                        (lambda (_paths problem)
                          (unless finished
                            (setq finished t)
                            (funcall callback (unless problem program) problem))) version)))))))
    (lambda ()
      (unless finished
        (setq finished t)
        (when-let ((cancel (or installation-cancel verification-cancel))) (funcall cancel))
        (funcall callback nil "Isled setup cancelled; retry setup")))))

(defun isled-cli-ensure (callback)
  "Resolve the pinned CLI and call CALLBACK with PROGRAM and nil, or nil and error.
Concurrent commands share one setup.  No download happens merely by loading
this library.  Explicit executables always take precedence."
  (require 'isled)
  (condition-case failure
      (let* ((version (isled-release-validate-version isled-required-cli-version))
             (program isled-program) (development isled-use-development-cli)
             (root (unless program (isled-installation-known-root isled-cli-directory)))
             (key (list version program development root
                        (and program (not (file-name-absolute-p program)) default-directory))))
        (cond
         ((and isled-cli--pending (equal key (isled-cli--job-key isled-cli--pending)))
          (push callback (isled-cli--job-callbacks isled-cli--pending)))
         (isled-cli--pending
          (funcall callback nil "Another Isled CLI setup is running; cancel it or wait, then retry"))
         (t
          (let ((job (isled-cli--job-create :key key :callbacks (list callback))))
            (setq isled-cli--pending job)
            (condition-case failure
                (progn
                  (when (and root (not program)
                             (or (file-remote-p root) (file-symlink-p (directory-file-name root))))
                    (error "Isled CLI storage must be a local, non-symlink directory"))
                  (isled-cli--prepare job version program development root))
              ((error quit) (isled-cli--finish job nil (error-message-string failure))))))))
    ((error quit) (funcall callback nil (error-message-string failure)))))

(defun isled-cli-resolve ()
  "Wait for the pinned CLI for a synchronous caller, allowing quit to cancel setup."
  (let (done program failure)
    (unwind-protect
        (progn
          (isled-cli-ensure (lambda (path problem) (setq program path failure problem done t)))
          (while (not done) (accept-process-output nil 0.05))
          (when failure (user-error "%s" failure))
          program)
      (unless done (isled-cancel-setup)))))

;;;###autoload
(defun isled-cancel-setup ()
  "Cancel pending CLI setup, preserving all installed versions and ledger data."
  (interactive)
  (when-let ((job isled-cli--pending))
    (when-let ((cancel (isled-cli--job-cancel job))) (funcall cancel))
    (isled-cli--finish job nil "Isled setup cancelled; invoke the command again to retry")))

;;;###autoload
(defun isled-setup-cli ()
  "Prepare the compatible CLI, or retry a failed setup."
  (interactive)
  (clrhash isled-cli--activated)
  (isled-cli-ensure (lambda (program failure)
                      (if failure (message "Isled setup failed: %s" failure)
                        (if isled-program (message "Explicit Isled CLI ready: %s" program)
                          (isled-show-installation))))))

;;;###autoload
(defun isled-show-installation ()
  "Show copyable current executable and skill paths without downloading."
  (interactive)
  (require 'isled)
  (when isled-program
    (user-error "Explicit executable: %s; its package or source checkout supplies the skill" isled-program))
  (let* ((root (isled-installation-known-root isled-cli-directory))
         (program (isled-install-cached root isled-required-cli-version (isled-release-current-target))))
    (unless program (user-error "Run M-x isled-setup-cli to install Isled first"))
    (isled-executable-verify
     program isled-required-cli-version nil
     (lambda (_path failure)
       (if failure (message "Isled installation: %s" failure)
         (isled-installation-run
          program root "installation"
          (lambda (paths problem)
            (if problem (message "Isled installation: %s" problem)
              (isled-installation-display paths program)))))))))

(provide 'isled-cli)
;;; isled-cli.el ends here
