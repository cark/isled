;;; isled-frontend.el --- Bounded wire decoding  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Assisted-by: Codex:GPT-6
;; Keywords: tools

;;; Commentary:

;; Validate compact views and conditional details before changing visible state.
;; Complete issue decoding shares the supported snapshot codec.

;;; Code:

(require 'isled-snapshot)
(require 'isled-graph-model)

(cl-defstruct (isled-response
               (:constructor isled-response-create))
  "Validated bounded response with an optional changed view."
  root view-hash view changes choices choices-present first-warning warning-targets graph)

(cl-defstruct (isled-detail
               (:constructor isled-detail-create))
  "Conditional detail result, including explicit absence or failure."
  id hash type issue targets unavailable)

(defun isled-frontend-decode (json)
  "Decode bounded response JSON into typed values or signal an error."
  (let* ((wire (json-parse-string json :object-type 'alist :array-type 'list
                                  :null-object :json-null :false-object :json-false))
         (root (isled-snapshot--file-name
                (isled-snapshot--bytes
                 (isled-snapshot--field wire 'root) "root")))
         (hash (isled-snapshot--field wire 'view_hash))
         (view (isled-snapshot--field wire 'view))
         (changes (isled-snapshot--field wire 'changes)))
    (unless (and (eql (isled-snapshot--field wire 'schema_version) 3)
                 (file-name-absolute-p root) (listp changes))
      (isled-snapshot--invalid "invalid bounded response"))
    (unless (eq hash :json-null) (isled-frontend--hash hash))
    (let ((details (mapcar (lambda (value)
                             (isled-frontend--detail value root)) changes))
          previous)
      (dolist (detail details)
        (let ((id (isled-detail-id detail)))
          (when (and previous (not (string< previous id)))
            (isled-snapshot--invalid "unordered detail changes"))
          (setq previous id)))
      (isled-response-create
       :root root :view-hash (unless (eq hash :json-null) hash)
       :graph (isled-graph-decode (alist-get 'graph wire))
       :view (unless (eq view :json-null)
               (isled-frontend--view view root))
       :choices-present (and (assq 'choices wire) t)
       :choices (isled-frontend--choices (alist-get 'choices wire))
       :first-warning (isled-frontend--warning-target (alist-get 'first_warning wire) root)
       :warning-targets (isled-frontend--warning-targets (alist-get 'warning_targets wire) root)
       :changes details))))

(defun isled-frontend--warning-target (wire root)
  "Decode an optional known warning target WIRE for ROOT."
  (unless (memq wire '(nil :json-null))
    (pcase (isled-snapshot--field wire 'type)
      ("issue" (isled-snapshot--summary (isled-snapshot--field wire 'issue)))
      ("problem" (car (isled-snapshot--unavailable-files
                       (list (isled-snapshot--field wire 'problem)) root)))
      (_ (isled-snapshot--invalid "invalid known warning target")))))

(defun isled-frontend--warning-targets (wire root)
  "Decode ordered known warning targets WIRE for ROOT."
  (unless (listp wire) (isled-snapshot--invalid "invalid warning targets"))
  (let (previous)
    (mapcar
     (lambda (value)
       (let* ((target (isled-frontend--warning-target value root))
              (id (cond ((isled-issue-p target) (isled-issue-id target))
                        ((isled-unavailable-p target) (isled-unavailable-id target))
                        (t (isled-snapshot--invalid "missing warning target")))))
         (when (and previous (not (string< previous id)))
           (isled-snapshot--invalid "unordered warning targets"))
         (setq previous id)
         target)) wire)))

(defun isled-frontend--choices (choices)
  "Validate optional completion CHOICES from cached metadata."
  (unless (and (listp choices)
               (seq-every-p (lambda (value)
                              (and (stringp value)
                                   (string-match-p "\\`[tks]:[a-z0-9-]+\\'" value))) choices))
    (isled-snapshot--invalid "invalid filter choices"))
  choices)

(defun isled-frontend--view (wire root)
  "Decode filtered view WIRE belonging to ROOT."
  (let* ((rows (isled-snapshot--field wire 'issues))
         (issues (mapcar #'isled-snapshot--summary rows))
         (unavailable (isled-snapshot--unavailable-files
                       (isled-snapshot--field wire 'unavailable) root)))
    (isled-snapshot--validate-order issues)
    (isled-snapshot--validate-distinct-identities issues unavailable)
    (isled-snapshot-create :root root :issues issues :unavailable unavailable)))

(defun isled-frontend--detail (wire root)
  "Decode one conditional detail WIRE from ROOT."
  (let* ((id (isled-snapshot--field wire 'id))
         (hash (isled-frontend--hash
                (isled-snapshot--field wire 'hash)))
         (type (isled-snapshot--field wire 'type))
         (result (isled-detail-create :id id :hash hash)))
    (isled-frontend--id id)
    (pcase type
      ("issue"
       (let* ((detail (isled-snapshot--field wire 'detail))
              (issue (isled-snapshot--issue
                      (isled-snapshot--field detail 'issue)))
              (targets (mapcar #'isled-snapshot--summary
                               (isled-snapshot--field detail 'targets)))
              (unavailable (isled-snapshot--unavailable-files
                            (isled-snapshot--field detail 'unavailable) root)))
         (unless (equal id (isled-issue-id issue))
           (isled-snapshot--invalid "detail identity mismatch"))
         (isled-snapshot--validate-order targets)
         (isled-snapshot--validate-distinct-identities targets unavailable)
         (setf (isled-detail-type result) 'issue
               (isled-detail-issue result) issue
               (isled-detail-targets result) targets
               (isled-detail-unavailable result) unavailable)))
      ("deleted" (setf (isled-detail-type result) 'deleted))
      ("problem"
       (let* ((problem (isled-snapshot--field wire 'problem))
              (path (isled-snapshot--field problem 'path))
              (error (isled-snapshot--field problem 'error))
              (file (if (eq path :json-null)
                        (isled-unavailable-create :id id :error error)
                      (car (isled-snapshot--unavailable-files
                            (list problem) root)))))
         (unless (and (equal id (isled-snapshot--field problem 'id))
                      (stringp error))
           (isled-snapshot--invalid "invalid problem detail"))
         (setf (isled-detail-type result) 'problem
               (isled-detail-unavailable result) (list file))))
      (_ (isled-snapshot--invalid "invalid detail type")))
    result))

(defun isled-frontend--id (id)
  "Require a canonical issue ID and return it."
  (unless (and (stringp id) (string-match-p "\\`[0-9]\\{4\\}\\'" id)
               (not (equal id "0000")))
    (isled-snapshot--invalid "invalid detail ID"))
  id)

(defun isled-frontend--hash (hash)
  "Require an opaque live HASH and return it."
  (unless (and (stringp hash)
               (let ((case-fold-search nil))
                 (string-match-p "\\`[0-9a-f]\\{16\\}\\'" hash)))
    (isled-snapshot--invalid "invalid live hash"))
  hash)

(provide 'isled-frontend)
;;; isled-frontend.el ends here
