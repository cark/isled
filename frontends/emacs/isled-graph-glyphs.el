;;; isled-graph-glyphs.el --- Dependency lane geometry -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Assisted-by: Codex:GPT-6
;; Keywords: tools

;;; Commentary:
;; Paint Rust's explicit right/down routes on headings.  Crossings do not join.
;; Only nearby headings allocate strings; all retained layout data stays sparse.

;;; Code:
(require 'isled-graph-drawing)
(require 'subr-x)

(cl-defstruct isled-graph-glyphs heading wrapped connector continuing)

(defun isled-graph-glyphs--junction (north east south west)
  "Return the glyph connecting NORTH, EAST, SOUTH and WEST ports."
  (let ((ports (+ (if north 1 0) (if east 2 0) (if south 4 0) (if west 8 0))))
    (when (= ports 15) (error "Unseparated dependency merge and split"))
    (aref [?\s ?│ ?─ ?╰ ?│ ?│ ?╭ ?├ ?─ ?╯ ?─ ?┴ ?╮ ?┤ ?┬] ports)))

(defun isled-graph-glyphs-line-count (plan index)
  "Return the number of routing lines following semantic INDEX of PLAN."
  (let ((span (isled-graph-drawing-span plan index)))
    (- (cdr span) (car span) 1)))

(defun isled-graph-glyphs--bar (cells left right endpoints incoming active)
  "Paint a bar in CELLS from LEFT to RIGHT using ENDPOINTS.
INCOMING selects a merge; otherwise paint a fork.  ACTIVE tracks cross it."
  (when (< left right)
    (cl-loop for cell from (* 2 left) to (* 2 right) do (aset cells cell ?─))
    (cl-loop for lane from left to right for cell = (* 2 lane) do
             (aset cells cell
                   (if (and (aref active lane) (not (aref endpoints lane))) ?╪
                     (isled-graph-glyphs--junction
                      (or (aref active lane) (and incoming (aref endpoints lane))) (< lane right)
                      (or (aref active lane) (and (not incoming) (aref endpoints lane))) (> lane left)))))))

(defun isled-graph-glyphs--step (plan index)
  "Render physical step INDEX of PLAN without choosing routes in Emacs."
  (let* ((drawing (isled-graph-plan-drawing plan))
         (lanes (isled-graph-drawing-lanes drawing))
         (step (aref (isled-graph-drawing-steps drawing) index))
         (lane (isled-graph-step-lane step))
         (row (when-let* ((ordinal (isled-graph-step-row step)))
                (aref (isled-graph-plan-rows plan) ordinal)))
         (width (1+ (* 2 lanes)))
         (active (make-vector lanes nil))
         (incoming (make-vector lanes nil)) (outgoing (make-vector lanes nil))
         (heading (make-vector width ?\s)) (continuing (make-vector width ?\s))
         (left lane) (right lane))
    (dolist (track (isled-graph-drawing-active drawing index))
      (aset active track t)
      (aset heading (* 2 track) ?│)
      (aset continuing (* 2 track) ?│))
    (dolist (route (aref (isled-graph-drawing-incoming drawing) index))
      (let ((track (isled-graph-route-lane route)))
        (aset incoming track t)
        (setq left (min left track))))
    (dolist (route (aref (isled-graph-drawing-outgoing drawing) index))
      (let ((track (isled-graph-route-lane route)))
        (aset outgoing track t)
        (aset continuing (* 2 track) ?│)
        (setq right (max right track))))
    (isled-graph-glyphs--bar heading left lane incoming t active)
    (isled-graph-glyphs--bar heading lane right outgoing nil active)
    (aset heading (* 2 lane)
          (if row
              (if (or (> lane 0) (isled-graph-row-targets row)
                      (> (isled-graph-row-filtered-prerequisites row) 0)
                      (> (isled-graph-row-filtered-dependents row) 0)) ?○ ?•)
            (isled-graph-glyphs--junction (aref incoming lane) (< lane right)
                                         (aref outgoing lane) (< left lane))))
    (make-isled-graph-glyphs :heading (concat heading) :wrapped (concat continuing)
                            :continuing (concat continuing))))

(defun isled-graph-glyphs-render (plan index)
  "Render semantic INDEX of PLAN and any following routing-only lines."
  (let* ((span (isled-graph-drawing-span plan index))
         (first (isled-graph-glyphs--step plan (car span))) lines)
    (cl-loop for step from (1+ (car span)) below (cdr span)
             for glyphs = (isled-graph-glyphs--step plan step) do
             (push (isled-graph-glyphs-heading glyphs) lines)
             (setf (isled-graph-glyphs-continuing first) (isled-graph-glyphs-continuing glyphs)))
    (setf (isled-graph-glyphs-connector first) (when lines (string-join (nreverse lines) "\n")))
    first))

(provide 'isled-graph-glyphs)
;;; isled-graph-glyphs.el ends here
