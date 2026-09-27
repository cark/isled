;;; isled-process.el --- Asynchronous request process  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Assisted-by: Codex:GPT-6
;; Keywords: tools

;;; Commentary:

;; Run one bounded frontend request without blocking Emacs.  A running command
;; is allowed to finish so its normal filesystem lock cleanup always runs.

;;; Code:

(require 'isled-snapshot)

(defvar isled-process-function #'isled-process-start
  "Function called with directory, request JSON, and a result callback.")

(defun isled-process-start (directory request callback)
  "Run REQUEST JSON in DIRECTORY and deliver the command result to CALLBACK."
  (isled-process-command directory (list "--root" directory "frontend" "--stdin")
                         request callback))

(defun isled-process-command (directory arguments input callback)
  "Run ARGUMENTS in DIRECTORY with INPUT, delivering its result to CALLBACK."
  (let ((origin (current-buffer)))
    (isled-cli-ensure
     (lambda (program failure)
       (if failure
           (funcall callback (isled-command-result-create :status 1 :stdout "" :stderr failure))
         (if (not (buffer-live-p origin))
             (funcall callback (isled-command-result-create :status 1 :stdout "" :stderr "Isled command buffer was closed"))
           (with-current-buffer origin
             (condition-case problem
                 (isled-process--launch program directory arguments input callback)
               (error (funcall callback (isled-command-result-create
                                        :status 1 :stdout "" :stderr (error-message-string problem))))))))))))

(defun isled-process--launch (program directory arguments input callback)
  "Run verified PROGRAM with ARGUMENTS and INPUT in DIRECTORY for CALLBACK."
  (let ((stdout (generate-new-buffer " *isled-output*"))
        (stderr (generate-new-buffer " *isled-errors*"))
        (default-directory (file-name-as-directory (expand-file-name directory)))
        process)
    (condition-case failure
        (progn
          (setq process
                (make-process
                 :name "isled-request" :buffer stdout :stderr stderr
                 :command (cons program arguments)
                 :connection-type 'pipe :coding 'utf-8-unix :noquery t
                 :sentinel
                 (lambda (child _event)
                   (when (memq (process-status child) '(exit signal))
                     (unwind-protect
                         (funcall callback
                                  (isled-command-result-create
                                   :status (process-exit-status child)
                                   :stdout (with-current-buffer stdout (buffer-string))
                                   :stderr (with-current-buffer stderr (buffer-string))))
                       (kill-buffer stdout)
                       (kill-buffer stderr))))))
          (when input (process-send-string process input))
          (process-send-eof process))
      (error
       ;; If startup failed there is no child holding the ledger lock.
       (unless process
         (kill-buffer stdout)
         (kill-buffer stderr))
       (signal (car failure) (cdr failure))))))

(provide 'isled-process)
;;; isled-process.el ends here
