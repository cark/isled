;;; isled-windows.el --- Visible issue demand -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Keywords: tools

;;; Commentary:

;; Observe displaying windows before redisplay, including background frame
;; changes that do not run window-change or command hooks.  Cheap signatures
;; trigger bounded cached presentation when display state changes; data requests
;; dispatch asynchronously when needed.  Observation exists only while views use it.

;;; Code:

(require 'isled-sections)
(require 'seq)
(require 'isled-navigation)
(require 'isled-expansion)

(defvar isled-windows--buffers nil
  "Buffers registered for display-change notification.")
(defvar-local isled-windows--notify nil
  "Callback for changes to the current buffer's displaying windows.")
(defvar-local isled-windows--state nil
  "Last observed windows, points, starts and body heights.")

(defconst isled-windows-chunk-size 32
  "Number of issue headings in one loading chunk.")
(defconst isled-windows-screen-margin 2
  "Number of text screens prefetched before and after the visible screen.")

(defun isled-windows-visible ()
  "Return windows displaying this buffer on visible frames across terminals."
  (seq-filter (lambda (window) (eq t (frame-visible-p (window-frame window))))
              (get-buffer-window-list (current-buffer) 'never t)))

(defun isled-windows-nearby ()
  "Return expanded IDs in visible heading chunks and their neighbours."
  (when-let ((windows (isled-windows-visible)))
    (let ((ids (make-hash-table :test #'equal)))
      (dolist (window windows)
        (isled-windows--collect window ids))
      (sort (hash-table-keys ids) #'string<))))

(defun isled-windows--chunk-range (window)
  "Return WINDOW's demanded row interval, with an exclusive upper bound.
Round its visible screen and surrounding text screens outward to heading chunks."
  (save-excursion
    (let* ((height (window-body-height window))
           (visible (pos-visible-in-window-p (window-point window) window))
           (origin (if visible (window-start window) (window-point window)))
           (margin isled-windows-screen-margin)
           ;; Before recentering, allow a full screen above point as well as
           ;; the margin, covering all possible positions of point in its window.
           (first (progn
                    (goto-char origin)
                    (vertical-motion (- (* (+ margin (if visible 0 1)) height)) window)
                    (isled-row-at)))
           (last (progn
                   (goto-char origin)
                   (vertical-motion (* (1+ margin) height) window)
                   (isled-row-at)))
           (size isled-windows-chunk-size))
      (cons (* size (/ (if first (isled-row-index first) 0) size))
            (min (length isled-rows)
                 (* size (1+ (/ (if last (isled-row-index last)
                                  (max 0 (1- (length isled-rows)))) size))))))))

(defun isled-windows-envelope (window)
  "Return a conservative heading interval around WINDOW without text layout.
Every heading occupies at least one screen line.  Include both the current
start and point so a destination outside the old window is never excluded."
  (let* ((start (isled-row-at (window-start window)))
         (point-row (isled-row-at (window-point window)))
         (first (if start (isled-row-index start) 0))
         (point-index (if point-row (isled-row-index point-row) first))
         (margin (* (1+ isled-windows-screen-margin)
                    (window-body-height window)))
         (size isled-windows-chunk-size))
    (cons (* size (/ (max 0 (- (min first point-index) margin)) size))
          (min (length isled-rows)
               (* size (1+ (/ (+ (max first point-index) margin) size)))))))

(defun isled-windows-in-range-p (row range)
  "Return non-nil when ROW belongs to the half-open heading RANGE."
  (let ((index (isled-row-index row)))
    (and (<= (car range) index) (< index (cdr range)))))

(defun isled-windows--collect (window ids)
  "Add expanded IDs from WINDOW's current loading chunks to IDS."
  (let ((envelope (isled-windows-envelope window)) range)
    (when isled-rows-expanded
      (maphash
       (lambda (row _)
         (when (isled-windows-in-range-p row envelope)
           (unless range (setq range (isled-windows--chunk-range window)))
           (when (isled-windows-in-range-p row range)
             (puthash (isled-row-value row) t ids))))
       isled-rows-expanded))))

(defun isled-windows-track (notify)
  "Notify this buffer through NOTIFY when its displaying windows change."
  (setq isled-windows--notify notify)
  (unless (memq (current-buffer) isled-windows--buffers)
    (setq isled-windows--state 'unobserved)
    (push (current-buffer) isled-windows--buffers)
    (add-hook 'kill-buffer-hook #'isled-windows-stop nil t)
    (add-hook 'change-major-mode-hook #'isled-windows-stop nil t)
    ;; Once per redisplay, including when no issue buffer is selected.  Do not
    ;; reconcile or request data here; notification presents only cached ranges.
    (add-function :after pre-redisplay-function #'isled-windows--changed)))

(defun isled-windows--changed (&rest _ignored)
  "Notify registered buffers whose displaying window signatures changed."
  (dolist (buffer isled-windows--buffers)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (isled-navigation-prune)
        (isled-expansion-prune)
        (let ((state (mapcar (lambda (window)
                               (list window (window-point window) (window-start window)
                                     (window-body-height window) (window-body-width window)
                                     (buffer-chars-modified-tick)))
                             (isled-windows-visible))))
          (unless (equal state isled-windows--state)
            (setq isled-windows--state state)
            (funcall isled-windows--notify)))))))

(defun isled-windows-stop ()
  "Unregister this buffer and remove global observers after the last view."
  (setq isled-windows--buffers
        (delq (current-buffer) isled-windows--buffers)
        isled-windows--notify nil
        isled-windows--state nil)
  (remove-hook 'kill-buffer-hook #'isled-windows-stop t)
  (remove-hook 'change-major-mode-hook #'isled-windows-stop t)
  (unless isled-windows--buffers
    (remove-function pre-redisplay-function #'isled-windows--changed)))

(provide 'isled-windows)
;;; isled-windows.el ends here
