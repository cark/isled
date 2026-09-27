;;; isled-executable.el --- Verify executable identity -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Assisted-by: Codex:GPT-6
;; Keywords: tools

;;; Commentary:
;; Check --version asynchronously, reusing evidence only while the file is unchanged.

;;; Code:
(require 'cl-lib)
(require 'subr-x)

(defvar isled-executable--verified (make-hash-table :test #'equal)
  "Previously verified executable signatures in this Emacs process.")

(defun isled-executable--signature (program version development)
  "Return PROGRAM's current identity key for VERSION and DEVELOPMENT."
  (let ((attributes (file-attributes (file-truename program) 'integer)))
    (unless (and attributes (not (file-directory-p program)) (file-executable-p program))
      (error "Isled executable is missing or not executable: %s" program))
    (list program version development (file-truename program)
          (file-attribute-size attributes) (file-attribute-modification-time attributes)
          (file-attribute-status-change-time attributes))))

(defun isled-executable-verified-p (program version development)
  "Return non-nil if unchanged PROGRAM was verified for VERSION and DEVELOPMENT."
  (gethash (isled-executable--signature program version development) isled-executable--verified))

(defun isled-executable-verify (program version development callback)
  "Check PROGRAM reports VERSION, allowing its -dev build only with DEVELOPMENT.
Call CALLBACK with PROGRAM and nil, or nil and an error message.  Return a
cancellation function; verification times out without affecting ledger commands."
  (let ((signature (isled-executable--signature program version development)))
    (if (gethash signature isled-executable--verified)
        (progn (funcall callback program nil) #'ignore)
      (let ((output (generate-new-buffer " *isled-version*")) process timer finished)
        (cl-labels
            ((finish (failure)
               (unless finished
                 (setq finished t)
                 (when timer (cancel-timer timer))
                 (when process
                   (set-process-sentinel process #'ignore)
                   (when (process-live-p process) (delete-process process)))
                 (kill-buffer output)
                 (unless failure (puthash signature t isled-executable--verified))
                 (funcall callback (unless failure program) failure))))
          (condition-case failure
              (progn
                (setq process
                      (make-process
                       :name "isled-version" :buffer output :stderr output
                       :command (list program "--version") :connection-type 'pipe
                       :coding 'utf-8-unix :noquery t
                       :sentinel
                       (lambda (child _event)
                         (when (and (not finished) (memq (process-status child) '(exit signal)))
                           (condition-case problem
                               (let ((text (with-current-buffer output (string-trim (buffer-string)))))
                                 (unless (and (zerop (process-exit-status child))
                                              (or (equal text (concat "isled " version))
                                                  (and development (equal text (concat "isled " version "-dev")))))
                                   (error "Expected Isled %s%s from %s, got %S; update the executable or explicit configuration"
                                          version (if development " (or same-version -dev)" "") program text))
                                 (unless (equal signature (isled-executable--signature program version development))
                                   (error "Isled executable changed during verification; retry"))
                                 (when (string-suffix-p "-dev" text)
                                   (message "Using explicitly configured Isled development CLI: %s" program))
                                 (finish nil))
                             (error (finish (error-message-string problem))))))))
                (setq timer (run-at-time 10 nil (lambda () (finish "Isled --version timed out; check the configured executable")))))
            ((error quit) (finish (error-message-string failure))))
          (lambda () (finish "Isled setup cancelled; invoke the command again to retry")))))))

(provide 'isled-executable)
;;; isled-executable.el ends here
