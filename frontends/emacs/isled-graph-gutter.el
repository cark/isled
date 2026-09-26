;;; isled-graph-gutter.el --- Bounded dependency gutter painting -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Keywords: tools

;;; Commentary:
;; Paint retained Rust lanes only around displaying windows.  Offscreen rows
;; share a constant-size spacing prefix, preserving wrapping without retaining
;; an issue-count times lane-count matrix of gutter strings.

;;; Code:
(require 'isled-graph-glyphs)
(require 'isled-presentation)
(require 'isled-rows)
(declare-function isled-windows-visible "isled-windows" ())

(defface isled-graph-gutter-face
  '((t :inherit (shadow fixed-pitch) :strike-through nil))
  "Face for dependency lanes, branches, crossings and issue nodes."
  :group 'isled)

(defvar-local isled-graph-gutter--painted nil "Rows owning concrete `isled-graph-glyphs` strings.")
(defvar-local isled-graph-gutter--rows nil "Row vector whose gutters are painted.")
(defvar-local isled-graph-gutter--blank nil "Shared width-preserving blank prefix.")
(defvar-local isled-graph-gutter--wrapping nil "Wrapping saved during gutter overflow.")

(defun isled-graph-gutter-overflow ()
  "Truncate lines when a graph prefix cannot fit in a displaying window.
Restore the previous wrapping setting once the gutter fits or graph mode ends."
  (let ((overflow
         (and isled-graph-direction isled-graph-layout
              (seq-some (lambda (window)
                          (>= (1+ (* 2 (isled-graph-plan-lanes (isled-graph-display-plan isled-graph-layout))))
                              (window-body-width window)))
                        (isled-windows-visible)))))
    (cond (overflow
           (unless isled-graph-gutter--wrapping
             (setq isled-graph-gutter--wrapping (list truncate-lines)))
           (setq truncate-lines t))
          (isled-graph-gutter--wrapping
           (setq truncate-lines (car isled-graph-gutter--wrapping)
                 isled-graph-gutter--wrapping nil)))))

(defun isled-graph-gutter--space ()
  "Return a constant-size prefix reserving the current graph width."
  (let ((width (1+ (* 2 (isled-graph-plan-lanes (isled-graph-display-plan isled-graph-layout))))))
    (unless (equal (get-text-property 0 'display (or isled-graph-gutter--blank " "))
                   `(space :width ,width))
      (setq isled-graph-gutter--blank
            (propertize " " 'display `(space :width ,width)
                        'face 'isled-graph-gutter-face)))
    isled-graph-gutter--blank))

(defun isled-graph-gutter--compose (gutter prefix)
  "Combine GUTTER with PREFIX, replacing any previously applied gutter."
  (let* ((base (if (and (stringp prefix) (> (length prefix) 0)
                       (get-text-property 0 'isled-graph-prefix prefix))
                  (get-text-property 0 'isled-graph-base prefix)
                prefix))
         (result (concat gutter base)))
    (add-text-properties 0 (length result)
                         (list 'isled-graph-prefix t 'isled-graph-base base) result)
    result))

(defun isled-graph-gutter--prefix (start end property gutter)
  "Prepend GUTTER to each PROPERTY span from START to END without changing text."
  (let ((position start))
    (while (< position end)
      (let* ((next (next-single-property-change position property nil end))
             (prefix (get-text-property position property)))
        (put-text-property position next property
                           (isled-graph-gutter--compose gutter prefix))
        (setq position next)))))

(defun isled-graph-gutter--heading (row heading)
  "Anchor ROW's HEADING to its visible heading overlay.
Unlike line prefixes, overlay strings survive redisplay after folded bodies."
  (let ((overlay (or (isled-row-heading-background row)
                      (setf (isled-row-heading-background row)
                            (make-overlay (isled-row-start row)
                                          (1- (isled-row-heading-end row)) nil t)))))
    (overlay-put overlay 'before-string
                 (isled-graph-gutter--compose heading (overlay-get overlay 'before-string)))
    (overlay-put overlay 'evaporate t)))

(defun isled-graph-gutter-routing (issue)
  "Reserve real routing lines for ISSUE before its foldable body.
Each line owns one placeholder character; bounded painting supplies its glyphs."
  (when (and isled-graph-direction isled-graph-layout)
    (let ((index (gethash (isled-issue-id issue) (isled-graph-plan-index isled-graph-layout))))
      (apply #'concat (make-list (isled-graph-glyphs-line-count isled-graph-layout index) " \n")))))

(defun isled-graph-gutter--routing (row connector blank)
  "Paint ROW's CONNECTOR lines or shared BLANK, continuing its expanded panel."
  (let ((lines (and connector (split-string connector "\n")))
        (panel (unless (isled-row-hidden row) (isled-sections--body-prefix))))
    (cl-loop for position from (isled-row-heading-end row) below (isled-row-content row) by 2
             do (put-text-property position (1+ position) 'display
                                   (concat (or (pop lines) blank) panel))
             do (put-text-property (1+ position) (+ position 2) 'face
                                   (and panel 'isled-expanded-body-face)))))

(defun isled-graph-gutter-style (row &optional glyphs)
  "Apply ROW's GLYPHS, or its retained/blank glyphs, after body styling."
  (when (and isled-graph-direction isled-graph-layout)
    (let* ((glyphs (or glyphs (and isled-graph-gutter--painted
                                  (gethash row isled-graph-gutter--painted))))
           (blank (isled-graph-gutter--space))
           (heading (if glyphs (isled-graph-glyphs-heading glyphs) blank))
           (wrapped (if glyphs (isled-graph-glyphs-wrapped glyphs) blank))
           (connector (and glyphs (isled-graph-glyphs-connector glyphs)))
           (continuing (if glyphs (isled-graph-glyphs-continuing glyphs) blank)))
      (with-silent-modifications
        (put-text-property (isled-row-start row) (isled-row-heading-end row) 'line-prefix nil)
        (isled-graph-gutter--heading row heading)
        (isled-graph-gutter--routing row connector blank)
        (isled-graph-gutter--prefix (isled-row-start row) (isled-row-heading-end row)
                                  'wrap-prefix wrapped)
        (isled-graph-gutter--prefix (isled-row-content row) (isled-row-end row)
                                  'wrap-prefix continuing)
        (isled-graph-gutter--prefix (isled-row-content row) (isled-row-end row)
                                  'line-prefix continuing)
        ;; Redisplay can inherit a prefix from the first invisible character
        ;; instead of the next heading.  Keep this fold boundary undecorated.
        (when (and (isled-row-hidden row) (< (isled-row-content row) (isled-row-end row)))
          (add-text-properties (isled-row-content row) (1+ (isled-row-content row))
                               '(line-prefix nil wrap-prefix nil)))))))

(defun isled-graph-gutter--strings (index)
  "Render and style prefixes for absolute layout INDEX."
  (let ((glyphs (isled-graph-glyphs-render isled-graph-layout index)))
    (dolist (string (list (isled-graph-glyphs-heading glyphs)
                          (isled-graph-glyphs-wrapped glyphs)
                          (isled-graph-glyphs-connector glyphs)
                          (isled-graph-glyphs-continuing glyphs)))
      (when string
        (add-face-text-property 0 (length string) 'isled-graph-gutter-face nil string)))
    glyphs))

(defun isled-graph-gutter--collect (needed index direction height)
  "Add rows to NEEDED from INDEX in DIRECTION, covering HEIGHT display lines."
  (let ((distance 0))
    (while (and (<= 0 index) (< index (length isled-rows)) (< distance height))
      (puthash (aref isled-rows index) t needed)
      (setq distance (+ distance 1 (isled-graph-glyphs-line-count isled-graph-layout index))
            index (+ index direction)))))

(defun isled-graph-gutter-nearby-rows ()
  "Collect bounded heading ranges around every visible window's start and point."
  (let ((needed (make-hash-table :test #'eq)))
    (dolist (window (isled-windows-visible))
      (dolist (position (list (window-start window) (window-point window)))
        (let* ((row (isled-row-at position))
               (index (if row (isled-row-index row) 0))
               (height (window-body-height window)))
          ;; Account for routing height so dense joins do not multiply painting.
          (isled-graph-gutter--collect needed index 1 (* 2 height))
          (isled-graph-gutter--collect needed (1- index) -1 height))))
    needed))

(defun isled-graph-gutter-update ()
  "Paint nearby graph rows and release offscreen glyph strings without reflow."
  (isled-graph-gutter-overflow)
  (when (and isled-graph-direction isled-graph-layout)
    (unless (eq isled-graph-gutter--rows isled-rows)
      (setq isled-graph-gutter--rows isled-rows
            isled-graph-gutter--painted (make-hash-table :test #'eq)))
    (let ((needed (isled-graph-gutter-nearby-rows)) retired)
      (maphash (lambda (row _) (unless (gethash row needed) (push row retired)))
               isled-graph-gutter--painted)
      (dolist (row retired)
        (remhash row isled-graph-gutter--painted)
        (isled-graph-gutter-style row))
      (maphash
       (lambda (row _)
         (unless (gethash row isled-graph-gutter--painted)
           (when-let ((index (gethash (isled-row-value row)
                                      (isled-graph-plan-index isled-graph-layout))))
             (let ((prefixes (isled-graph-gutter--strings index)))
               (puthash row prefixes isled-graph-gutter--painted)
               (isled-graph-gutter-style row prefixes)))))
       needed))))

(provide 'isled-graph-gutter)
;;; isled-graph-gutter.el ends here
