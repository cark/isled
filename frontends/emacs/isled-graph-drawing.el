;;; isled-graph-drawing.el --- Validated sparse dependency routes -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Assisted-by: Codex:GPT-6
;; Keywords: tools

;;; Commentary:
;; Each edge runs right, down a track, then right to its target.  Only complete
;; outgoing sets share routing junctions.  Validate before retaining geometry.

;;; Code:
(require 'isled-graph-model)

(cl-defstruct isled-graph-drawing lanes steps positions incoming outgoing intervals maxima)
(cl-defstruct isled-graph-step row lane)
(cl-defstruct isled-graph-route source target lane)

(defun isled-graph-drawing--steps (raw lanes count)
  "Decode RAW into physical rows with LANES for COUNT semantic rows."
  (unless (and (listp raw) (<= count (length raw) (* 2 count)))
    (isled-snapshot--invalid "invalid drawing step count"))
  (let ((expected 0))
    (prog1
        (vconcat
         (mapcar (lambda (value)
                   (let ((row (isled-snapshot--field value 'row))
                         (lane (isled-snapshot--field value 'lane)))
                     (unless (and (integerp lane) (<= 0 lane) (< lane lanes))
                       (isled-snapshot--invalid "invalid drawing node"))
                     (unless (eq row :json-null)
                       (unless (and (integerp row) (= row expected) (< row count))
                         (isled-snapshot--invalid "invalid drawing row order"))
                       (setq expected (1+ expected)))
                     (make-isled-graph-step :row (unless (eq row :json-null) row) :lane lane))) raw))
      (unless (= expected count) (isled-snapshot--invalid "missing drawing rows")))))

(defun isled-graph-drawing--route (wire steps lanes previous)
  "Decode one route.
Validate WIRE against STEPS and LANES, following PREVIOUS route."
  (let ((source (isled-snapshot--field wire 'source))
        (target (isled-snapshot--field wire 'target))
        (lane (isled-snapshot--field wire 'lane)))
    (unless (and (integerp source) (integerp target) (<= 0 source) (< source target (length steps))
                 (integerp lane) (< 0 lane lanes)
                 (<= (isled-graph-step-lane (aref steps source)) lane
                     (isled-graph-step-lane (aref steps target)))
                 (or (null previous) (< (car previous) source)
                     (and (= (car previous) source) (< (cdr previous) target))))
      (isled-snapshot--invalid "invalid or backward drawing route"))
    (make-isled-graph-route :source source :target target :lane lane)))

(defun isled-graph-drawing--destinations (steps incoming outgoing)
  "Validate shared junctions.
Use STEPS with INCOMING and OUTGOING adjacency.
Return their semantic destinations; junctions are a fork or a merge then fork."
  (let ((destinations (make-vector (length steps) nil)))
    (cl-loop for index downfrom (1- (length steps)) to 0
             for step = (aref steps index) for row = (isled-graph-step-row step)
             for targets = (mapcar #'isled-graph-route-target (aref outgoing index)) do
             (if row (aset destinations index (list row))
               (unless (and (> (length (aref incoming index)) 0) targets)
                 (isled-snapshot--invalid "orphan drawing junction"))
               (cond
                ((cl-every (lambda (target) (isled-graph-step-row (aref steps target))) targets)
                 (unless (and (> (length targets) 1)
                              (or (> (length (aref incoming index)) 1)
                                  (null (isled-graph-step-row
                                         (aref steps (isled-graph-route-source
                                                      (car (aref incoming index))))))))
                   (isled-snapshot--invalid "empty or unshared drawing fork"))
                 (aset destinations index
                       (mapcar (lambda (target) (isled-graph-step-row (aref steps target))) targets)))
                ((and (= (length targets) 1) (= (car targets) (1+ index))
                      (null (isled-graph-step-row (aref steps (car targets))))
                      (= (isled-graph-step-lane step)
                         (isled-graph-step-lane (aref steps (car targets))))
                      (> (length (aref incoming index)) 1)
                      (= (length (aref incoming (car targets))) 1)
                      (cl-every (lambda (route)
                                  (isled-graph-step-row (aref steps (isled-graph-route-source route))))
                                (aref incoming index)))
                 (aset destinations index (aref destinations (car targets))))
                (t (isled-snapshot--invalid "invalid shared drawing junction")))))
    destinations))

(defun isled-graph-drawing--semantics (steps incoming outgoing semantic)
  "Verify exact direct dependencies.
Compare STEPS and their INCOMING and OUTGOING routes against SEMANTIC rows."
  (let ((destinations (isled-graph-drawing--destinations steps incoming outgoing)))
    (cl-loop for step across steps for index from 0
             for row = (isled-graph-step-row step)
             for routes = (aref outgoing index) do
             (unless (eq (zerop (isled-graph-step-lane step)) (null (aref incoming index)))
               (isled-snapshot--invalid "drawing roots must use the first column"))
             (if row
                 (progn
                   (when (and (> (length routes) 1)
                              (seq-some (lambda (route)
                                          (null (isled-graph-step-row
                                                 (aref steps (isled-graph-route-target route))))) routes))
                     (isled-snapshot--invalid "only complete destination sets may share a fork"))
                   (let ((actual (if (= (length routes) 1)
                                     (aref destinations (isled-graph-route-target (car routes)))
                                   (mapcar (lambda (route)
                                             (isled-graph-step-row (aref steps (isled-graph-route-target route))))
                                           routes))))
                     (unless (equal actual (isled-graph-row-targets (aref semantic row)))
                       (isled-snapshot--invalid "drawing changes direct dependencies"))))
               (when (and (seq-some (lambda (route) (< (isled-graph-route-lane route)
                                                      (isled-graph-step-lane step)))
                                   (aref incoming index))
                          (seq-some (lambda (route) (> (isled-graph-route-lane route)
                                                      (isled-graph-step-lane step))) routes))
                 (isled-snapshot--invalid "drawing merge and fork need separate lines"))))))

(defun isled-graph-drawing--tracks (tracks steps outgoing)
  "Index physical track intervals.
Check TRACKS against STEPS and OUTGOING edges before indexing them."
  (let ((positions (make-vector (length tracks) nil)) intervals)
    (cl-loop for step across steps for row from 0
             do (push row (aref positions (isled-graph-step-lane step))))
    (dotimes (lane (length tracks))
      (let (unions)
        (dolist (route (nreverse (aref tracks lane)))
          (let ((previous (car unions)) (start (isled-graph-route-source route)))
            (if (and previous (> (isled-graph-route-target previous) start))
                (unless (and (= (isled-graph-route-target previous) (isled-graph-route-target route))
                             (= (length (aref outgoing start)) 1))
                  (isled-snapshot--invalid "overlapping drawing tracks"))
              (when (and previous (= (isled-graph-route-target previous) start)
                         (/= (isled-graph-step-lane (aref steps start)) lane))
                (isled-snapshot--invalid "drawing track forks before its merge"))
              (push route unions))))
        (let* ((ordered (nreverse unions)) (remaining ordered))
          (dolist (row (nreverse (aref positions lane)))
            (while (and remaining (<= (isled-graph-route-target (car remaining)) row))
              (setq remaining (cdr remaining)))
            (when (and remaining (< (isled-graph-route-source (car remaining)) row))
              (isled-snapshot--invalid "unrelated drawing track crosses a node")))
          (setq intervals (nconc ordered intervals)))))
    (vconcat (sort intervals (lambda (a b) (< (isled-graph-route-source a)
                                             (isled-graph-route-source b)))))))

(defun isled-graph-drawing--maxima (intervals)
  "Index INTERVALS by subtree end in a balanced implicit interval tree."
  (let ((maxima (make-vector (length intervals) 0)))
    (cl-labels ((index (low high)
                  (if (= low high) 0
                    (let* ((middle (/ (+ low high) 2))
                           (end (max (isled-graph-route-target (aref intervals middle))
                                     (index low middle) (index (1+ middle) high))))
                      (aset maxima middle end) end))))
      (index 0 (length intervals)))
    maxima))

(defun isled-graph-drawing-decode (wire plan)
  "Validate drawing WIRE against PLAN and retain its sparse geometry."
  (unless (eql (alist-get 'version wire) 1)
    (isled-snapshot--invalid "unsupported graph drawing; use matching Isled CLI and Emacs versions"))
  (let* ((semantic (isled-graph-plan-rows plan))
         (count (length semantic))
         (edges (cl-loop for row across semantic sum (length (isled-graph-row-targets row))))
         (raw-routes (isled-snapshot--field wire 'routes))
         (lanes (isled-snapshot--field wire 'lanes)))
    (unless (and (listp raw-routes) (<= (length raw-routes) (+ edges count))
                 (integerp lanes) (<= 0 lanes (if (zerop count) 0 (+ 1 edges count)))
                 (eq (zerop lanes) (zerop count)))
      (isled-snapshot--invalid "invalid drawing dimensions"))
    (let* ((steps (isled-graph-drawing--steps (isled-snapshot--field wire 'steps) lanes count))
           (positions (make-vector count nil))
           (incoming (make-vector (length steps) nil)) (outgoing (make-vector (length steps) nil))
           (tracks (make-vector lanes nil)) previous)
      (dolist (value raw-routes)
        (let* ((route (isled-graph-drawing--route value steps lanes previous))
               (source (isled-graph-route-source route)) (target (isled-graph-route-target route)))
          (push route (aref incoming target)) (push route (aref outgoing source))
          (push route (aref tracks (isled-graph-route-lane route)))
          (setq previous (cons source target))))
      (dotimes (index (length steps))
        (setf (aref outgoing index) (nreverse (aref outgoing index)))
        (when-let* ((row (isled-graph-step-row (aref steps index)))) (aset positions row index)))
      (isled-graph-drawing--semantics steps incoming outgoing semantic)
      (let ((intervals (isled-graph-drawing--tracks tracks steps outgoing)))
        (make-isled-graph-drawing :lanes lanes :steps steps :positions positions
                                  :incoming incoming :outgoing outgoing :intervals intervals
                                  :maxima (isled-graph-drawing--maxima intervals))))))

(defun isled-graph-drawing-span (plan index)
  "Return physical drawing bounds for semantic INDEX of PLAN."
  (let* ((drawing (isled-graph-plan-drawing plan))
         (positions (isled-graph-drawing-positions drawing)))
    (cons (aref positions index)
          (if (< (1+ index) (length positions)) (aref positions (1+ index))
            (length (isled-graph-drawing-steps drawing))))))

(defun isled-graph-drawing-active (drawing row)
  "Find DRAWING's tracks passing through ROW without scanning empty columns."
  (let ((intervals (isled-graph-drawing-intervals drawing))
        (maxima (isled-graph-drawing-maxima drawing)) active)
    (cl-labels ((visit (low high)
                  (when (< low high)
                    (let* ((middle (/ (+ low high) 2)) (route (aref intervals middle)))
                      (when (> (aref maxima middle) row)
                        (visit low middle)
                        (when (< (isled-graph-route-source route) row)
                          (when (< row (isled-graph-route-target route))
                            (push (isled-graph-route-lane route) active))
                          (visit (1+ middle) high)))))))
      (visit 0 (length intervals)))
    active))

(provide 'isled-graph-drawing)
;;; isled-graph-drawing.el ends here
