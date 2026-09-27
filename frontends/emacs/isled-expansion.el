;;; isled-expansion.el --- Window fitting after expansion -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Assisted-by: Codex:GPT-6
;; Keywords: tools

;;; Commentary:
;; Fit explicitly opened rows without moving point.  Missing bodies get one
;; guarded retry through normal delivery, never a separate timer or request.
;; If fitting scrolls a window, retain its original viewport until the same
;; issue is folded or the interaction is invalidated.

;;; Code:
(require 'isled-rows)
(require 'isled-navigation)

(cl-defstruct isled-expansion--origin
  id original-start original-hscroll original-vscroll
  point start hscroll vscroll height width changed)
(defvar-local isled-expansion--pending nil
  "Window-keyed expansion intents awaiting body delivery or folding.")
(defvar isled-expansion--inhibit-prune nil
  "Non-nil while fitting performs its own redisplay.")

(defun isled-expansion--fit (row window)
  "Reveal as much of ROW as possible in WINDOW without moving its point."
  (with-selected-window window
    (save-excursion
      (let ((original (point))
            (start (window-start window))
            (last (max (isled-row-start row)
                       (1- (isled-row-end row)))))
        (unless (and (pos-visible-in-window-p (isled-row-start row) window)
                     (pos-visible-in-window-p last window))
          ;; Let Emacs account for wrapping and display heights.  The row's
          ;; bottom gives the smallest forward scroll; point caps oversized rows.
          (goto-char last)
          (recenter -1)
          (let ((bottom-start (window-start window)))
            (goto-char original)
            (vertical-motion 0 window)
            (set-window-start window
                              (min (point)
                                   (max bottom-start
                                        (min start (isled-row-start row)))) t)))))))

(defun isled-expansion--viewport (window)
  "Return WINDOW's scroll position."
  (list (window-start window) (window-hscroll window) (window-vscroll window t)))

(defun isled-expansion--update-guard (origin window)
  "Update ORIGIN to the current guarded state of WINDOW."
  (set-marker (isled-expansion--origin-point origin) (window-point window))
  (set-marker (isled-expansion--origin-start origin) (window-start window))
  (setf (isled-expansion--origin-hscroll origin) (window-hscroll window)
        (isled-expansion--origin-vscroll origin) (window-vscroll window t)
        (isled-expansion--origin-height origin) (window-body-height window t)
        (isled-expansion--origin-width origin) (window-body-width window t)))

(defun isled-expansion--fit-origin (origin row window)
  "Fit ROW in WINDOW and update ORIGIN without replacing its first viewport."
  (let ((before (isled-expansion--viewport window)))
    (let ((isled-expansion--inhibit-prune t))
      (isled-expansion--fit row window)
      ;; `scroll-margin' and related display settings may normalize the start
      ;; only when Emacs redisplays.  Capture that settled viewport so the
      ;; observer does not mistake fitting's own scroll for user movement.
      (redisplay t))
    (unless (equal before (isled-expansion--viewport window))
      (setf (isled-expansion--origin-changed origin) t))
    (isled-expansion--update-guard origin window)))

(defun isled-expansion--valid-p (origin row window)
  "Return whether ORIGIN still guards ROW in WINDOW."
  (and (window-live-p window)
       (eq (window-buffer window) (current-buffer))
       row (not (isled-row-hidden row))
       (equal (isled-expansion--origin-id origin)
              (isled-row-value row))
       (= (window-point window) (isled-expansion--origin-point origin))
       (= (window-start window) (isled-expansion--origin-start origin))
       (= (window-hscroll window) (isled-expansion--origin-hscroll origin))
       (= (window-vscroll window t) (isled-expansion--origin-vscroll origin))
       (= (window-body-height window t) (isled-expansion--origin-height origin))
       (= (window-body-width window t) (isled-expansion--origin-width origin))))

(defun isled-expansion--point-visible-p (window)
  "Return whether WINDOW's point is within its text-screen bounds."
  (with-current-buffer (window-buffer window)
    (save-excursion
      (let ((position (window-point window))
            (start (window-start window)))
        (goto-char start)
        (vertical-motion (window-body-height window) window)
        (and (>= position start) (< position (point)))))))

(defun isled-expansion--discard (window)
  "Release WINDOW's pending intent and its markers."
  (when-let* ((origin (alist-get window isled-expansion--pending)))
    (set-marker (isled-expansion--origin-original-start origin) nil)
    (set-marker (isled-expansion--origin-point origin) nil)
    (set-marker (isled-expansion--origin-start origin) nil)
    (setq isled-expansion--pending
          (assq-delete-all window isled-expansion--pending)))
  (unless isled-expansion--pending
    (remove-hook 'post-command-hook #'isled-expansion-prune t)))

(defun isled-expansion-clear ()
  "Release every pending fitting intent when this view stops."
  (dolist (entry (copy-sequence isled-expansion--pending))
    (isled-expansion--discard (car entry))))

(defun isled-expansion-prune ()
  "Cancel fitting state after movement, resizing, folding or view removal."
  (unless isled-expansion--inhibit-prune
    (dolist (entry (copy-sequence isled-expansion--pending))
      (let* ((window (car entry)) (origin (cdr entry))
             (row (and isled-rows-index
                       (gethash (isled-expansion--origin-id origin)
                                isled-rows-index))))
        (unless (isled-expansion--valid-p origin row window)
          (isled-expansion--discard window))))))

(defun isled-expansion-request ()
  "Fit the explicitly opened row at point, retrying if its body is missing."
  (let* ((window (or isled-navigation--window (selected-window)))
         (row (isled-row-at)))
    (when (and row (not (isled-row-hidden row))
               (eq (window-buffer window) (current-buffer)))
      (let ((origin (alist-get window isled-expansion--pending))
            (awaiting (not (isled-issue-content
                            (isled-row-issue row)))))
        (unless (and origin (isled-expansion--valid-p origin row window))
          (isled-expansion--discard window)
          (setq origin
                (make-isled-expansion--origin
                 :id (isled-row-value row)
                 :original-start (copy-marker (window-start window))
                 :original-hscroll (window-hscroll window)
                 :original-vscroll (window-vscroll window t)
                 :point (copy-marker (window-point window))
                 :start (copy-marker (window-start window))))
          (push (cons window origin) isled-expansion--pending))
        (isled-expansion--fit-origin origin row window)
        (if (or awaiting (isled-expansion--origin-changed origin))
            (progn
              (add-hook 'post-command-hook #'isled-expansion-prune nil t)
              (add-hook 'kill-buffer-hook #'isled-expansion-clear nil t)
              (add-hook 'change-major-mode-hook #'isled-expansion-clear nil t))
          (isled-expansion--discard window))))))

(defun isled-expansion-complete ()
  "Finish surviving fitting intents after synchronous body presentation.
Prune intents before presentation changes text positions."
  (dolist (entry (copy-sequence isled-expansion--pending))
    (let* ((window (car entry))
           (origin (cdr entry))
           (row (and isled-rows-index
                     (gethash (isled-expansion--origin-id origin)
                              isled-rows-index))))
      (cond
       ((or (not row) (isled-row-hidden row))
        (isled-expansion--discard window))
       ((isled-issue-content (isled-row-issue row))
        (if (and (window-live-p window)
                 (eq (window-buffer window) (current-buffer))
                 (= (window-point window) (isled-expansion--origin-point origin))
                 (= (window-body-height window t)
                    (isled-expansion--origin-height origin))
                 (= (window-body-width window t)
                    (isled-expansion--origin-width origin)))
            (progn
              (isled-expansion--fit-origin origin row window)
              (unless (isled-expansion--origin-changed origin)
                (isled-expansion--discard window)))
          (isled-expansion--discard window)))))))

(defun isled-expansion-collapse (row collapse)
  "Run COLLAPSE for ROW, restoring a still-valid pre-fit viewport."
  (let* ((window (or isled-navigation--window (selected-window)))
         (origin (alist-get window isled-expansion--pending))
         (restore (and origin
                       (isled-expansion--origin-changed origin)
                       (isled-expansion--valid-p origin row window)
                       (list (marker-position
                              (isled-expansion--origin-original-start origin))
                             (isled-expansion--origin-original-hscroll origin)
                             (isled-expansion--origin-original-vscroll origin)))))
    (isled-expansion--discard window)
    (funcall collapse)
    (when (and restore (window-live-p window)
               (eq (window-buffer window) (current-buffer)))
      (set-window-hscroll window (nth 1 restore))
      (set-window-vscroll window (nth 2 restore) t)
      (set-window-start window (car restore) t)
      (unless (isled-expansion--point-visible-p window)
        (with-selected-window window
          (goto-char (window-point window))
          (recenter))))))

(provide 'isled-expansion)
;;; isled-expansion.el ends here
