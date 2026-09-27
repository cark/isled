;;; isled-graph-drawing.el --- Validated shared dependency routes -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Assisted-by: Codex:GPT-6
;; Keywords: tools

;;; Commentary:
;; Decode Rust's sparse drawing steps against the exact semantic dependencies.
;; A routing-only junction may share a complete outgoing set, never add edges.

;;; Code:
(require 'isled-graph-model)

(defun isled-graph-drawing--destinations (value count)
  "Validate a sorted semantic destination VALUE against COUNT."
  (unless (listp value) (isled-snapshot--invalid "invalid drawing destinations"))
  (let ((previous -1))
    (dolist (target value)
      (unless (and (integerp target) (< previous target) (< target count))
        (isled-snapshot--invalid "invalid drawing destination"))
      (setq previous target)))
  value)

(defun isled-graph-drawing--positions (values count)
  "Index semantic rows in drawing VALUES, preserving all COUNT identities."
  (let ((positions (make-vector count nil)) (expected 0))
    (cl-loop for value across values for step from 0
             for row = (isled-snapshot--field value 'row)
             unless (eq row :json-null) do
             (unless (and (integerp row) (= row expected) (< row count))
               (isled-snapshot--invalid "invalid drawing row order"))
             (aset positions row step)
             (setq expected (1+ expected)))
    (unless (= expected count) (isled-snapshot--invalid "missing drawing rows"))
    positions))

(defun isled-graph-drawing--targets (value values semantic positions)
  "Resolve VALUE's targets using VALUES, SEMANTIC rows and POSITIONS."
  (let ((row (isled-snapshot--field value 'row))
        (join (alist-get 'join value))
        (targets (alist-get 'targets value)))
    (cond
     ((eq row :json-null)
      (when join (isled-snapshot--invalid "a drawing junction cannot join another"))
      (isled-graph-drawing--destinations targets (length semantic))
      (unless (> (length targets) 1) (isled-snapshot--invalid "empty drawing junction"))
      (mapcar (lambda (target) (aref positions target)) targets))
     (join
      (unless (and (integerp join) (<= 0 join) (< join (length values))
                   (null targets)
                   (eq (isled-snapshot--field (aref values join) 'row) :json-null)
                   (equal (isled-graph-row-targets (aref semantic row))
                          (isled-snapshot--field (aref values join) 'targets)))
        (isled-snapshot--invalid "shared drawing route changes dependencies"))
      (list join))
     (t
      (when targets (isled-snapshot--invalid "drawing row overrides dependencies"))
      (mapcar (lambda (target) (aref positions target))
              (isled-graph-row-targets (aref semantic row)))))))

(defun isled-graph-drawing-decode (wire plan)
  "Validate drawing WIRE against PLAN and index the resulting physical tracks."
  (let* ((raw (isled-snapshot--field wire 'steps))
         (lanes (isled-snapshot--field wire 'lanes))
         (semantic (isled-graph-plan-rows plan))
         (count (length semantic)))
    (unless (and (listp raw) (<= count (length raw) (+ count (/ count 2)))
                 (integerp lanes) (<= 0 lanes (length raw))
                 (eq (zerop lanes) (zerop count)))
      (isled-snapshot--invalid "invalid drawing dimensions"))
    (let* ((values (vconcat raw))
           (positions (isled-graph-drawing--positions values count))
           (rows (make-vector (length values) nil))
           (incoming (make-vector (length values) 0)))
      (cl-loop for value across values for ordinal from 0
               for semantic-row = (isled-snapshot--field value 'row)
               for lane = (isled-snapshot--field value 'lane)
               for start = (isled-snapshot--field value 'start)
               for targets = (isled-graph-drawing--targets value values semantic positions)
               do (unless (and (integerp lane) (<= 0 lane) (< lane lanes)
                               (or (eq start :json-null)
                                   (and (integerp start) (<= 0 start) (< start ordinal))))
                    (isled-snapshot--invalid "invalid drawing track"))
               do (let ((previous ordinal))
                    (dolist (target targets)
                      (unless (< previous target) (isled-snapshot--invalid "backward drawing route"))
                      (aset incoming target (1+ (aref incoming target)))
                      (setq previous target)))
               do (aset rows ordinal
                        (make-isled-graph-row
                         :id (unless (eq semantic-row :json-null)
                               (isled-graph-row-id (aref semantic semantic-row)))
                         :filtered-prerequisites
                         (if (eq semantic-row :json-null) 0
                           (isled-graph-row-filtered-prerequisites (aref semantic semantic-row)))
                         :filtered-dependents
                         (if (eq semantic-row :json-null) 0
                           (isled-graph-row-filtered-dependents (aref semantic semantic-row)))
                         :lane lane :start (unless (eq start :json-null) start) :targets targets)))
      (cl-loop for row across rows for ordinal from 0
               when (null (isled-graph-row-id row)) do
               (unless (> (aref incoming ordinal) 1)
                 (isled-snapshot--invalid "unshared drawing junction")))
      (isled-graph--index-rows rows lanes))))

(provide 'isled-graph-drawing)
;;; isled-graph-drawing.el ends here
