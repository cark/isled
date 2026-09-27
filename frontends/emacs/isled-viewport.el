;;; isled-viewport.el --- Bounded body presentation  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Assisted-by: Codex:GPT-6
;; Keywords: tools

;;; Commentary:

;; Format retained bodies around displaying windows after their anchors are
;; restored.  Applied layout properties remain in the buffer when offscreen so
;; scrolling does not repeatedly reflow text or re-run Markdown formatting.

;;; Code:

(require 'isled-windows)
(declare-function isled--window-anchors "isled-browser" (&optional preferred-id))
(declare-function isled--restore-window-anchors "isled-browser" (anchors))

(defvar-local isled-viewport--motion nil
  "Visible windows with their last row index and direction of travel.")

(defun isled-viewport--observe (window)
  "Return WINDOW's current row index and retained direction of travel."
  (let* ((row (isled-row-at (window-point window)))
         (index (if row (isled-row-index row) 0))
         (previous (assq window isled-viewport--motion))
         (direction (if (and previous (/= index (cadr previous)))
                        (if (> index (cadr previous)) 1 -1)
                      (or (nth 2 previous) 1))))
    (list window index direction)))

(defun isled-viewport--priority (row)
  "Score ROW by proximity, favouring each window's direction of travel."
  (let ((score most-positive-fixnum))
    (dolist (motion isled-viewport--motion)
      (let* ((distance (- (isled-row-index row) (cadr motion)))
             (cost (* (abs distance) (if (< (* distance (nth 2 motion)) 0) 2 1))))
        (setq score (min score cost))))
    score))

(defun isled-viewport--needed (windows &optional ahead)
  "Return materialized visible rows of WINDOWS, including margins when AHEAD."
  (let ((needed (make-hash-table :test #'eq)))
    (dolist (window windows)
      (isled-viewport--collect window needed ahead))
    needed))

(defun isled-viewport--collect (window needed &optional ahead)
  "Add visible rows of WINDOW to NEEDED, with extra margins when AHEAD."
  (let* ((height (window-body-height window))
         ;; Redisplay can recenter an off-screen point after this notification.
         ;; Prepare its destination, not the window start left by the old view.
         (visible (pos-visible-in-window-p (window-point window) window))
         (origin (if visible (window-start window) (window-point window)))
         (above (+ (if ahead isled-windows-screen-margin 0) (if visible 0 1)))
         (first (save-excursion
                  (goto-char origin)
                  (vertical-motion (- (ceiling (* above height))) window)
                  (isled-row-at)))
         (last (save-excursion
                 (goto-char origin)
                 (vertical-motion (ceiling (* (if ahead (1+ isled-windows-screen-margin) 1) height)) window)
                 (isled-row-at))))
    (when last
      (cl-loop for index from (if first (isled-row-index first) 0)
               to (isled-row-index last)
               for row = (aref isled-rows index)
               when (and (isled-row-materialized row)
                         (or (not (isled-row-hidden row))
                             (and (isled-row-fold row)
                                  (overlay-get (isled-row-fold row) 'isled-preview))))
               do (puthash row t needed)))))

(defun isled-viewport-work-p ()
  "Return non-nil if an expanded body near a visible window may need formatting.
Search previews format their chosen body directly through the fold callback."
  (when isled-rows-expanded
    (let ((ranges (mapcar #'isled-windows-envelope
                         (isled-windows-visible))))
      (catch 'needed
        (maphash
         (lambda (row _)
           (when (and (isled-row-materialized row)
                      (not (isled-row-rich row))
                      (isled-issue-content (isled-row-issue row))
                      (seq-some (lambda (range)
                                  (isled-windows-in-range-p row range)) ranges))
             (throw 'needed t)))
         isled-rows-expanded)
        nil))))

(defun isled-viewport-update ()
  "Apply newly needed body presentation while preserving each window's anchor."
  (isled-graph-gutter-update)
  (let ((windows (isled-windows-visible)))
    (setq isled-viewport--motion (mapcar #'isled-viewport--observe windows))
    (when (and windows (isled-viewport-work-p))
      (let ((anchors (isled--window-anchors)))
        ;; Hidden Markdown can bring another body into range.  Each successful
        ;; pass formats previously plain rows, so this reaches a fixed point.
        (while (isled-viewport--format-needed windows)
          (isled--restore-window-anchors anchors))))))

(defun isled-viewport--format-needed (windows)
  "Format newly needed rows around WINDOWS and report whether any changed."
  (let (changed)
    (maphash (lambda (row _)
               (when (isled-sections-format row) (setq changed t)))
             (isled-viewport--needed windows))
    changed))

(defun isled-viewport-prefetch ()
  "Format at most one extra nearby body and report whether more remain.
Visible rows are handled synchronously by `isled-viewport-update'."
  (when-let ((windows (and (isled-viewport-work-p)
                           (isled-windows-visible))))
    (let ((needed (isled-viewport--needed windows t)) candidate)
      (maphash (lambda (row _)
                 (when (and (not (isled-row-rich row))
                            (isled-issue-content (isled-row-issue row))
                            (or (not candidate)
                                (< (isled-viewport--priority row) (isled-viewport--priority candidate))))
                   (setq candidate row)))
               needed)
      (when candidate
        (let ((anchors (isled--window-anchors)))
          (isled-sections-format candidate)
          (isled--restore-window-anchors anchors)
          ;; Changed wrapping can expose another row.  Recheck once at the next
          ;; deadline rather than formatting the whole prefetched batch now.
          t)))))

(provide 'isled-viewport)
;;; isled-viewport.el ends here
