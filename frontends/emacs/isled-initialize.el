;;; isled-initialize.el --- Explicit ledger initialization -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Assisted-by: Codex:GPT-6
;; Keywords: tools

;;; Commentary:
;; Run explicitly requested initialization asynchronously.  Never redirect an
;; owner who moved away while the command was running, and never retry a write.

;;; Code:
(require 'isled-process)

(defvar isled-initialize--pending (make-hash-table :test #'equal)
  "Locations with an initialization command still running.")

(defun isled-initialize (location open)
  "Initialize LOCATION once, then call OPEN if the invoking view is unchanged."
  (when (gethash location isled-initialize--pending)
    (user-error "Ledger creation is already running for %s" location))
  (let ((window (selected-window)) (buffer (current-buffer))
        (position (point)) (tick (buffer-chars-modified-tick)))
    (puthash location t isled-initialize--pending)
    (condition-case failure
        (isled-process-command
         location (list "--root" location "init") nil
         (lambda (result)
           (remhash location isled-initialize--pending)
           (if (not (eql 0 (isled-command-result-status result)))
               (message "Isled creation failed in %s: %s" location
                        (isled-snapshot--failure-message result))
             (message "Isled ledger initialized in %s" location)
             (when (and (buffer-live-p buffer) (window-live-p window)
                        (eq window (selected-window)) (eq buffer (window-buffer window))
                        (= position (window-point window))
                        (= tick (buffer-chars-modified-tick buffer)))
               (with-current-buffer buffer
                 (condition-case error
                     (funcall open)
                   (error (message "Isled created; opening failed: %s"
                                   (error-message-string error)))))))))
      (error
       (remhash location isled-initialize--pending)
       (signal (car failure) (cdr failure))))))

(provide 'isled-initialize)
;;; isled-initialize.el ends here
