;;; isled-windows.el --- Visible issue demand -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Assisted-by: Codex:GPT-6
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
  "Last observed window positions, dimensions and text geometry.")

(defconst isled-windows-chunk-size 32
  "Number of issue headings in one loading chunk.")
(defconst isled-windows-screen-margin 2
  "Number of text screens prefetched before and after the visible screen.")

(defun isled-windows-visible ()
  "Return windows displaying this buffer on visible frames across terminals."
  (seq-filter (lambda (window) (eq t (frame-visible-p (window-frame window))))
              (get-buffer-window-list (current-buffer) 'never t)))

(defun isled-windows-bounds (window)
  "Return WINDOW's visible buffer range, with an exclusive end.
Ask Emacs to update its display bounds after text or layout changes."
  (let ((start (window-start window)))
    (cons start (max start (or (window-end window t) start)))))

(defun isled-windows-screen-lines (window)
  "Return an approximate screen size for WINDOW's prefetch margins.
Emacs accounts for the buffer's default font and line spacing.  Actual
visibility comes from `isled-windows-bounds', not this estimate."
  (with-selected-window window (max 1 (ceiling (window-screen-lines)))))

(defun isled-windows--extend (window bounds lines)
  "Extend BOUNDS by LINES screen lines on either side in WINDOW."
  (if (zerop lines) bounds
    (save-excursion
      (goto-char (car bounds))
      (vertical-motion (- lines) window)
      (let ((start (point)))
        (goto-char (cdr bounds))
        (vertical-motion lines window)
        (cons start (point))))))

(defun isled-windows-text-ranges (window &optional screens)
  "Return WINDOW's visible range plus SCREENS of preparation on either side.
Also prepare an offscreen point's impending recenter destination.  Keep these
ranges separate to avoid traversing the gap after a distant jump."
  (let* ((bounds (isled-windows-bounds window))
         (margin (or screens 0))
         (position (window-point window))
         (visible (pos-visible-in-window-p position window))
         (lines (if (or (> margin 0) (not visible))
                    (isled-windows-screen-lines window) 0)))
    (cons (isled-windows--extend window bounds (* margin lines))
          (unless visible
            (list (isled-windows--extend window (cons position position)
                                         (* (1+ margin) lines)))))))

(defun isled-windows-row-range (bounds)
  "Convert buffer BOUNDS to a half-open interval in the current row vector.
Unowned text before or after the issue list contributes no rows."
  (let* ((count (length isled-rows))
         (first (isled-row-at (car bounds)))
         (last (isled-row-at (max (car bounds) (1- (cdr bounds)))))
         (first-index (if first (isled-row-index first)
                        (if (and (> count 0)
                                 (< (car bounds) (isled-row-start (aref isled-rows 0))))
                            0 count))))
    (cons first-index
          (if (<= (cdr bounds) (car bounds)) first-index
            (if last (1+ (isled-row-index last))
              (if (and (> count 0)
                       (<= (cdr bounds) (isled-row-start (aref isled-rows 0))))
                  0 count))))))

(defun isled-windows-nearby ()
  "Return expanded IDs in visible heading chunks and their neighbours."
  (when-let ((windows (isled-windows-visible)))
    (let ((ids (make-hash-table :test #'equal)))
      (dolist (window windows)
        (isled-windows--collect window ids))
      (sort (hash-table-keys ids) #'string<))))

(defun isled-windows--chunk-ranges (window)
  "Return WINDOW's demanded half-open row intervals.
Round visible text, prefetch and jump destination outward to heading chunks."
  (mapcar
   (lambda (bounds)
     (let ((range (isled-windows-row-range bounds))
           (size isled-windows-chunk-size))
       (if (= (car range) (cdr range)) range
         (cons (* size (/ (car range) size))
               (min (length isled-rows) (* size (ceiling (cdr range) size)))))))
   (isled-windows-text-ranges window isled-windows-screen-margin)))

(defun isled-windows-envelope (window)
  "Return a conservative row interval for WINDOW's display and prefetch.
Include the native visible bounds and point before adding a cheap row margin.
This rejects distant bodies before traversing the prefetch text."
  (let* ((range (isled-windows-row-range (isled-windows-bounds window)))
         (point-row (isled-row-at (window-point window)))
         (first (car range))
         (last (max first (1- (cdr range))))
         (point-index (if point-row (isled-row-index point-row) first))
         (margin (* (1+ isled-windows-screen-margin)
                    (isled-windows-screen-lines window)))
         (size isled-windows-chunk-size))
    (cons (* size (/ (max 0 (- (min first point-index) margin)) size))
          (min (length isled-rows)
               (* size (1+ (/ (+ (max last point-index) margin) size)))))))

(defun isled-windows-in-range-p (row range)
  "Return non-nil when ROW belongs to the half-open heading RANGE."
  (let ((index (isled-row-index row)))
    (and (<= (car range) index) (< index (cdr range)))))

(defun isled-windows--collect (window ids)
  "Add expanded IDs from WINDOW's current loading chunks to IDS."
  (let ((envelope (isled-windows-envelope window)) ranges)
    (when isled-rows-expanded
      (maphash
       (lambda (row _)
         (when (isled-windows-in-range-p row envelope)
           (unless ranges (setq ranges (isled-windows--chunk-ranges window)))
           (when (seq-some (lambda (range) (isled-windows-in-range-p row range)) ranges)
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
                                     (window-body-height window t) (window-body-width window t)
                                     (window-vscroll window t)
                                     (window-font-height window) (window-font-width window)
                                     (copy-tree face-remapping-alist) line-spacing
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
