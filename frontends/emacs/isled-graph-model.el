;;; isled-graph-model.el --- Validated dependency layout -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Keywords: tools

;;; Commentary:
;; Retain Rust's lane assignments and direct routes.  The lane interval index
;; answers painting queries without traversing dependencies or earlier rows.

;;; Code:
(require 'cl-lib)
(require 'isled-snapshot)
(declare-function isled-frontend--id "isled-frontend" (id))
(declare-function isled-frontend--hash "isled-frontend" (hash))
(declare-function isled-graph-drawing-decode "isled-graph-drawing" (wire plan))

(cl-defstruct isled-graph-row id lane start targets (routes :unprepared)
              (filtered-prerequisites 0) (filtered-dependents 0))
(cl-defstruct isled-graph-plan lanes rows index tracks drawing)
(cl-defstruct isled-graph-response hash direction plan)

(defvar-local isled-graph-direction 'prerequisites "Dependency direction, or nil for flat view.")
(defvar-local isled-graph-layout nil "Last validated Rust layout plan.")
(defvar-local isled-graph-hash nil "Conditional token for the retained layout.")
(defvar-local isled-graph-layout-direction nil "Direction of the retained layout.")

(defun isled-graph-decode (wire)
  "Decode optional graph WIRE, validating all structural invariants eagerly."
  (when wire
    (let ((hash (isled-frontend--hash (isled-snapshot--field wire 'hash)))
          (direction (isled-snapshot--field wire 'direction))
          (plan (isled-snapshot--field wire 'plan)))
      (unless (member direction '("prerequisites" "dependents"))
        (isled-snapshot--invalid "invalid graph direction"))
      (make-isled-graph-response
       :hash hash :direction (intern direction)
       :plan (unless (eq plan :json-null)
               (require 'isled-graph-drawing)
               (let ((result (isled-graph--decode-plan plan)))
                 (setf (isled-graph-plan-drawing result)
                       (isled-graph-drawing-decode (isled-snapshot--field plan 'drawing) result))
                 result))))))

(defun isled-graph--decode-row (wire lanes count ordinal)
  "Decode WIRE with LANES and COUNT at ORDINAL into a structurally valid row."
  (let ((id (isled-frontend--id (isled-snapshot--field wire 'id)))
        (lane (isled-snapshot--field wire 'lane))
        (start (isled-snapshot--field wire 'start))
        (targets (isled-snapshot--field wire 'targets))
        (prerequisites (alist-get 'filtered_prerequisites wire 0))
        (dependents (alist-get 'filtered_dependents wire 0))
        (previous ordinal))
    (unless (and (integerp lane) (<= 0 lane) (< lane lanes)
                 (or (eq start :json-null)
                     (and (integerp start) (<= 0 start) (< start ordinal)))
                 (listp targets)
                 (integerp prerequisites) (<= 0 prerequisites 9998)
                 (integerp dependents) (<= 0 dependents 9998))
      (isled-snapshot--invalid "invalid graph row"))
    (dolist (target targets)
      (unless (and (integerp target) (< previous target) (< target count))
        (isled-snapshot--invalid "invalid graph route"))
      (setq previous target))
    (make-isled-graph-row :id id :lane lane
                          :start (unless (eq start :json-null) start)
                          :targets targets :filtered-prerequisites prerequisites
                          :filtered-dependents dependents)))

(defun isled-graph--decode-plan (wire)
  "Validate WIRE and construct the retained lane interval index."
  (let* ((values (isled-snapshot--field wire 'rows))
         (lanes (isled-snapshot--field wire 'lanes))
         (count (and (listp values) (length values))))
    (unless (and count (<= count 9999) (integerp lanes) (<= 0 lanes count)
                 (eq (zerop lanes) (zerop count)))
      (isled-snapshot--invalid "invalid graph dimensions"))
    (isled-graph--index-rows
     (vconcat (cl-loop for value in values for ordinal from 0
                       collect (isled-graph--decode-row value lanes count ordinal))) lanes)))

(defun isled-graph--index-rows (rows lanes)
  "Validate ROWS' tracks and index them across LANES, including routing nodes."
  (let* ((count (length rows))
         (starts (make-vector count nil))
         (tracks (make-vector lanes nil))
         (ends (make-vector lanes nil))
         (index (make-hash-table :test #'equal :size count)))
    (cl-loop for row across rows for ordinal from 0
             for id = (isled-graph-row-id row)
             do (when id
                  (when (gethash id index) (isled-snapshot--invalid "duplicate graph identity"))
                  (puthash id ordinal index))
             do (dolist (target (isled-graph-row-targets row))
                  (unless (aref starts target) (aset starts target ordinal))))
    (cl-loop for row across rows for ordinal from 0
             for lane = (isled-graph-row-lane row)
             for start = (isled-graph-row-start row)
             for previous = (aref ends lane)
             do (unless (and (eql start (aref starts ordinal))
                             (or (null previous) (< previous (or start ordinal))
                                 (and (= previous (or start ordinal)) start
                                      (memq ordinal (isled-graph-row-targets
                                                     (aref rows previous))))))
                  (isled-snapshot--invalid "overlapping or inconsistent graph track"))
             do (aset ends lane ordinal)
             when start do (push ordinal (aref tracks lane)))
    (dotimes (lane lanes) (aset tracks lane (vconcat (nreverse (aref tracks lane)))))
    (make-isled-graph-plan :lanes lanes :rows rows :index index :tracks tracks)))

(defun isled-graph-display-plan (plan)
  "Return PLAN's drawing geometry, or PLAN for an internal geometry fixture."
  (or (isled-graph-plan-drawing plan) plan))

(defun isled-graph-drawing-span (plan index)
  "Return drawing step bounds for semantic row INDEX of PLAN."
  (let* ((drawing (isled-graph-display-plan plan))
         (rows (isled-graph-plan-rows drawing))
         (start (gethash (isled-graph-row-id (aref (isled-graph-plan-rows plan) index))
                         (isled-graph-plan-index drawing)))
         (end (1+ start)))
    (while (and (< end (length rows)) (null (isled-graph-row-id (aref rows end))))
      (setq end (1+ end)))
    (cons start end)))

(defun isled-graph-order (issues plan)
  "Order ISSUES by PLAN, retaining only currently available identities."
  (if (not plan) issues
    (let ((index (make-hash-table :test #'equal :size (length issues))))
      (dolist (issue issues) (puthash (isled-issue-id issue) issue index))
      (cl-loop for row across (isled-graph-plan-rows plan)
               for issue = (gethash (isled-graph-row-id row) index)
               when issue collect issue))))

(defun isled-graph-continuing (plan boundary)
  "Return lanes continuing across BOUNDARY using PLAN's indexed intervals."
  (let ((rows (isled-graph-plan-rows plan)) result)
    (cl-loop for tracks across (isled-graph-plan-tracks plan) for lane from 0
             do (let ((low 0) (high (length tracks)))
                  (while (< low high)
                    (let ((middle (/ (+ low high) 2)))
                      (if (< (aref tracks middle) boundary)
                          (setq low (1+ middle)) (setq high middle))))
                  (when (and (< low (length tracks))
                             (< (isled-graph-row-start (aref rows (aref tracks low)))
                                boundary))
                    (push lane result))))
    (nreverse result)))

(provide 'isled-graph-model)
;;; isled-graph-model.el ends here
