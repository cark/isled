;;; isled-auto-refresh.el --- Ledger notification lifecycle  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Assisted-by: Codex:GPT-6
;; Keywords: tools

;;; Commentary:

;; Own directory watches, coalescing timers and polling fallback in the ledger owner.
;; The interactive controller supplies snapshot refresh and header presentation.

;;; Code:

(require 'autorevert)
(require 'cl-lib)
(require 'filenotify)
(require 'seq)
(require 'isled-snapshot)

(defvar isled--root)
(defvar isled-session)
(defvar-local isled-session-owner-p nil
  "Non-nil in the private ledger notification buffer.")
(declare-function isled-session-watch "isled-session")
(declare-function isled--refresh "isled-browser" (automatic))
(declare-function isled--update-header-line "isled-browser" ())

(defcustom isled-auto-revert t
  "Whether project issue views refresh automatically.

When non-nil, each ledger watches its flat directory while any view exists.
If notifications cannot observe child-file changes, the shared ledger owner
uses Auto Revert polling and reports that fallback in its views."
  :type 'boolean
  :group 'isled)

(defconst isled--notification-delay 0.1
  "Idle seconds used to coalesce one burst of ledger notifications.")

(defvar-local isled--auto-refresh-warning nil
  "Visible reason why automatic refresh is using its polling fallback.")

(defvar-local isled--notification-watch nil
  "Filesystem notification descriptor for the current ledger directory.")

(defvar-local isled--notification-timer nil
  "Pending one-shot timer for a coalesced notification refresh.")

(defvar-local isled--notification-generation 0
  "Generation used to make canceled notification callbacks inert.")

(defun isled--buffer-stale-p (&optional _noconfirm)
  "Request fallback regeneration only while no notification watch is active."
  (when (and (or isled-session-owner-p (not (bound-and-true-p isled-session)))
             isled-auto-revert isled--root
             (not isled--notification-watch))
    ;; Retry notifications before each fallback poll.  One final regeneration
    ;; closes the race when a watch becomes available again.
    (isled--start-notifications)
    'fast))

(defun isled--configure-auto-refresh ()
  "Configure automatic refresh and return non-nil after starting a watch."
  (cond
   ((and (bound-and-true-p isled-session) (not isled-session-owner-p))
    (isled-session-watch))
   ((not isled-auto-revert)
    (isled--stop-auto-refresh)
    (setq isled--auto-refresh-warning nil)
    (isled--update-header-line)
    nil)
   (isled--notification-watch
    (when auto-revert-mode
      (auto-revert-mode -1))
    nil)
   (t
    (isled--start-notifications))))

(defun isled--start-notifications ()
  "Start the current ledger's directory watch, or enable polling fallback."
  (cond
   ((eq file-notify--library 'kqueue)
    (isled--enable-polling-fallback
     "kqueue cannot observe child-file content changes"))
   ((not file-notify--library)
    (isled--enable-polling-fallback
     "filesystem notifications are unavailable"))
   (t
    (condition-case error-data
        (let ((buffer (current-buffer)))
          ;; This also repairs cleanup for a source-loaded buffer created by an
          ;; older package version before the lifecycle hooks existed.
          (add-hook 'change-major-mode-hook
                    #'isled--stop-auto-refresh nil t)
          (add-hook 'kill-buffer-hook
                    #'isled--stop-auto-refresh nil t)
          (setq isled--notification-watch
                (file-notify-add-watch
                 (expand-file-name ".issues" isled--root)
                 '(change attribute-change)
                 (lambda (event)
                   (isled--handle-notification buffer event)))
                isled--auto-refresh-warning nil)
          (when auto-revert-mode
            (auto-revert-mode -1))
          (isled--update-header-line)
          t)
      (file-notify-error
       (isled--enable-polling-fallback
        (error-message-string error-data)))))))

(defun isled--enable-polling-fallback (reason)
  "Use Auto Revert polling and display REASON in the current view."
  (setq isled--auto-refresh-warning reason)
  (unless auto-revert-mode
    (auto-revert-mode 1))
  (isled--update-header-line)
  nil)

(defun isled--handle-notification (buffer event)
  "Handle filesystem EVENT for project issue BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (equal (car event) isled--notification-watch)
        (if (eq (cadr event) 'stopped)
            (progn
              (setq isled--notification-watch nil)
              (when (and isled-auto-revert
                         (isled--start-notifications))
                (isled--schedule-notification-refresh)))
          (when (and isled-auto-revert
                     (isled--relevant-notification-p event))
            (isled--schedule-notification-refresh)))))))

(defun isled--relevant-notification-p (event)
  "Return non-nil when EVENT concerns a non-hidden ledger entry."
  (seq-some
   (lambda (path)
     (and (stringp path)
          (not (string-prefix-p
                "." (file-name-nondirectory
                     (directory-file-name path))))))
   (nthcdr 2 event)))

(defun isled--schedule-notification-refresh ()
  "Replace any pending notification refresh with one idle callback."
  (when (timerp isled--notification-timer)
    (cancel-timer isled--notification-timer))
  (cl-incf isled--notification-generation)
  (let ((buffer (current-buffer))
        (descriptor isled--notification-watch)
        (generation isled--notification-generation))
    (setq isled--notification-timer
          (run-with-idle-timer
           isled--notification-delay nil
           #'isled--run-notification-refresh
           buffer descriptor generation))))

(defun isled--run-notification-refresh
    (buffer descriptor generation)
  "Refresh BUFFER if DESCRIPTOR and GENERATION still identify its watch."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and isled-auto-revert
                 (equal descriptor isled--notification-watch)
                 (= generation isled--notification-generation))
        (setq isled--notification-timer nil)
        (isled--refresh t)))))

(defun isled--stop-auto-refresh ()
  "Remove the current buffer's watch, timer, and polling fallback."
  (cl-incf isled--notification-generation)
  (when (timerp isled--notification-timer)
    (cancel-timer isled--notification-timer))
  (setq isled--notification-timer nil)
  (when-let ((descriptor isled--notification-watch))
    ;; Clear first so the synchronous `stopped' callback remains inert.
    (setq isled--notification-watch nil)
    (ignore-errors (file-notify-rm-watch descriptor)))
  (when auto-revert-mode
    (auto-revert-mode -1)))

(provide 'isled-auto-refresh)
;;; isled-auto-refresh.el ends here
