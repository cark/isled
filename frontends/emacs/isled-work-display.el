;;; isled-work-display.el --- Live work time in visible headings -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Assisted-by: Codex:GPT-6
;; Keywords: tools

;;; Commentary:
;; Display overlays keep clock ticks independent of heading text, row positions,
;; change detection and data loading.  Only visible running headings need a timer.

;;; Code:
(require 'cl-lib)
(require 'isled-windows)
(require 'isled-work-data)

(defvar-local isled-work-display--overlays nil
  "Visible running rows mapped to their display overlays.")
(defvar-local isled-work-display--timer nil
  "One-shot timer for the next visible clock update.")

(defun isled-work-display--visible ()
  "Return the set of running rows whose headings intersect visible windows."
  (let ((rows (make-hash-table :test #'eq)))
    (dolist (window (isled-windows-visible))
      (let* ((bounds (isled-windows-bounds window))
             (start (car bounds))
             (range (isled-windows-row-range bounds)))
        (cl-loop for index from (car range) below (cdr range)
                 for row = (aref isled-rows index)
                 for work = (isled-issue-work (isled-row-issue row))
                 when (and (> (isled-row-heading-end row) start)
                           work (isled-work-data-running-since work))
                 do (puthash row t rows))))
    rows))

(defun isled-work-display--paint (row now)
  "Display ROW's elapsed work time at NOW and return its overlay."
  (when-let* ((start (text-property-any (isled-row-start row)
                                       (isled-row-heading-end row)
                                       'isled-work-label t))
              (end (next-single-property-change start 'isled-work-label nil
                                                (isled-row-heading-end row))))
    (let* ((overlay (or (and isled-work-display--overlays
                             (gethash row isled-work-display--overlays))
                        (make-overlay start end nil t)))
           (label (propertize
                   (isled-work-data-label (isled-issue-work (isled-row-issue row)) now)
                   'face 'isled-issue-work-face)))
      (move-overlay overlay start end)
      (overlay-put overlay 'evaporate t)
      (unless (equal label (overlay-get overlay 'display))
        (overlay-put overlay 'display label))
      overlay)))

(defun isled-work-display-update ()
  "Reconcile visible clock labels and scheduling without fetching or editing data."
  (let ((visible (isled-work-display--visible))
        (next (make-hash-table :test #'eq))
        (now (current-time)))
    (maphash (lambda (row _)
               (when-let ((overlay (isled-work-display--paint row now)))
                 (puthash row overlay next)))
             visible)
    (when isled-work-display--overlays
      (maphash (lambda (row overlay)
                 (unless (gethash row next) (delete-overlay overlay)))
               isled-work-display--overlays))
    (setq isled-work-display--overlays next)
    (if (zerop (hash-table-count next))
        (isled-work-display-stop)
      (add-hook 'kill-buffer-hook #'isled-work-display-stop nil t)
      (add-hook 'change-major-mode-hook #'isled-work-display-stop nil t)
      (unless isled-work-display--timer
        ;; One-shot scheduling avoids replaying missed ticks after sleep or a
        ;; busy command.  The owner requested roughly one-second feedback.
        (setq isled-work-display--timer
              (run-at-time 1 nil #'isled-work-display--tick (current-buffer)))))))

(defun isled-work-display--tick (buffer)
  "Update BUFFER's visible clocks from the current time after a timer fires."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq isled-work-display--timer nil)
      (isled-work-display-update))))

(defun isled-work-display-stop ()
  "Release this view's clock timer and display overlays."
  (when (timerp isled-work-display--timer)
    (cancel-timer isled-work-display--timer))
  (when isled-work-display--overlays
    (maphash (lambda (_row overlay) (delete-overlay overlay))
             isled-work-display--overlays))
  (setq isled-work-display--timer nil isled-work-display--overlays nil)
  (remove-hook 'kill-buffer-hook #'isled-work-display-stop t)
  (remove-hook 'change-major-mode-hook #'isled-work-display-stop t))

(provide 'isled-work-display)
;;; isled-work-display.el ends here
