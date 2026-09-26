;;; isled-graph-glyphs.el --- Dependency lane geometry -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Keywords: tools

;;; Commentary:
;; Turn one retained layout row into node, routing and continuation lines.
;; Only horizontal routes need their own line.  Straight chains stay compact.

;;; Code:
(require 'isled-graph-model)
(require 'subr-x)

(cl-defstruct isled-graph-glyphs heading wrapped connector continuing)

(defun isled-graph-glyphs--junction (north east south west)
  "Return the glyph connecting NORTH, EAST, SOUTH and WEST ports."
  (let ((ports (+ (if north 1 0) (if east 2 0) (if south 4 0) (if west 8 0))))
    (when (= ports 15) (error "Unseparated dependency merge and split"))
    (aref [?\s ?│ ?─ ?╰ ?│ ?│ ?╭ ?├ ?─ ?╯ ?─ ?┴ ?╮ ?┤ ?┬] ports)))

(defun isled-graph-glyphs--routes (plan index)
  "Retain sparse, one-sided routing groups for step INDEX of PLAN."
  (let* ((rows (isled-graph-plan-rows plan))
         (row (aref rows index)))
    (when (eq (isled-graph-row-routes row) :unprepared)
      (let ((lane (isled-graph-row-lane row)) left right joins)
        (dolist (target (isled-graph-row-targets row))
          (let* ((destination (aref rows target))
                 (to (isled-graph-row-lane destination)))
            (unless (= to lane)
              (cond ((< (isled-graph-row-start destination) index)
                     (push (list target) joins))
                    ((< to lane) (push target left))
                    (t (push target right))))))
        (setf (isled-graph-row-routes row)
              (append (when left (list (nreverse left)))
                      (when right (list (nreverse right))) (nreverse joins)))))
    (isled-graph-row-routes row)))

(defun isled-graph-glyphs-line-count (plan index)
  "Return the number of routing lines following semantic INDEX of PLAN."
  (let ((drawing (isled-graph-display-plan plan))
        (span (isled-graph-drawing-span plan index)))
    (cl-loop for step from (car span) below (cdr span)
             sum (length (isled-graph-glyphs--routes drawing step)))))

(defun isled-graph-glyphs--verticals (active width)
  "Make WIDTH cells containing vertical strokes in ACTIVE lanes."
  (let ((cells (make-vector width ?\s)))
    (cl-loop for present across active for lane from 0
             when present do (aset cells (* 2 lane) ?│))
    cells))

(defun isled-graph-glyphs--route (lane targets active keep-source width)
  "Draw a route from LANE to TARGETS through ACTIVE lanes in WIDTH cells.
KEEP-SOURCE continues the source stem; crossings interrupt the vertical stroke."
  (let* ((cells (make-vector width ?\s))
         (destinations (make-vector (length active) nil))
         (left lane) (right lane))
    (dolist (to targets)
      (aset destinations to t)
      (setq left (min left to) right (max right to)))
    (dotimes (track (length active))
      (let* ((cell (* 2 track))
             (north (or (aref active track) (= track lane)))
             (south (or (aref active track) (aref destinations track)
                        (and (= track lane) keep-source)))
             (east (and (<= left track) (< track right)))
             (west (and (< left track) (<= track right))))
        (aset cells cell
              (if (and east west (aref active track) (not (aref destinations track))) ?─
                (isled-graph-glyphs--junction north east south west)))
        (when east (aset cells (1+ cell) ?─))))
    (dolist (to targets) (aset active to t))
    (aset active lane keep-source)
    (concat cells)))

(defun isled-graph-glyphs--step (plan index)
  "Render one issue or routing-only step INDEX of drawing PLAN."
  (let* ((rows (isled-graph-plan-rows plan))
         (row (aref rows index))
         (lane (isled-graph-row-lane row))
         (width (1+ (* 2 (isled-graph-plan-lanes plan))))
         (active (make-vector (isled-graph-plan-lanes plan) nil))
         (routes (isled-graph-glyphs--routes plan index))
         (same-lane (seq-some (lambda (target) (= lane (isled-graph-row-lane (aref rows target))))
                              (isled-graph-row-targets row)))
         heading wrapped lines)
    (dolist (track (isled-graph-continuing plan index)) (aset active track t))
    (setq heading (isled-graph-glyphs--verticals active width))
    (aset heading (* 2 lane)
          (if (or (isled-graph-row-start row) (isled-graph-row-targets row)
                  (> (isled-graph-row-filtered-prerequisites row) 0)
                  (> (isled-graph-row-filtered-dependents row) 0)) ?○ ?•))
    (aset active lane (and (isled-graph-row-targets row) t))
    (setq wrapped (isled-graph-glyphs--verticals active width))
    (aset active lane nil)
    (while routes
      (push (isled-graph-glyphs--route
             lane (mapcar (lambda (target) (isled-graph-row-lane (aref rows target))) (car routes))
             active (and (or (cdr routes) same-lane) t) width) lines)
      ;; The source stem is handled independently of continuing destination tracks.
      (aset active lane nil)
      (setq routes (cdr routes)))
    (aset active lane (and same-lane t))
    (make-isled-graph-glyphs
     :heading (concat heading) :wrapped (concat wrapped)
     :connector (when lines (string-join (nreverse lines) "\n"))
     :continuing (concat (isled-graph-glyphs--verticals active width)))))

(defun isled-graph-glyphs-render (plan index)
  "Render semantic row INDEX of PLAN, including its routing lines."
  (let ((drawing (isled-graph-display-plan plan))
        (span (isled-graph-drawing-span plan index)) first continuing connectors)
    (cl-loop for step from (car span) below (cdr span)
             for glyphs = (isled-graph-glyphs--step drawing step)
             do (unless first (setq first glyphs))
             do (setq continuing (isled-graph-glyphs-continuing glyphs))
             when (isled-graph-glyphs-connector glyphs)
             do (push (isled-graph-glyphs-connector glyphs) connectors))
    (setf (isled-graph-glyphs-connector first) (when connectors (string-join (nreverse connectors) "\n"))
          (isled-graph-glyphs-continuing first) continuing)
    first))

(provide 'isled-graph-glyphs)
;;; isled-graph-glyphs.el ends here
