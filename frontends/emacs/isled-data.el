;;; isled-data.el --- Retained frontend detail data  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Keywords: tools

;;; Commentary:

;; Retain detail hashes and bodies separately from Rust-filtered summaries.
;; Build the renderer's typed snapshot without inventing unloaded content.

;;; Code:

(require 'isled-frontend)
(require 'isled-view)
(require 'isled-sequence)

(defvar-local isled-data-view nil
  "Latest Rust-filtered summary view.")
(defvar-local isled-data-hash nil
  "Conditional token for the current summary view.")
(defvar-local isled-data-targets nil
  "Latest metadata observed for reference targets outside the filtered view.")
(defvar-local isled-data-details nil
  "Hash table of issue IDs to retained conditional detail results.")

(defun isled-data-request-details (ids)
  "Return a JSON-ready vector requesting IDS with retained live hashes."
  (vconcat
   (mapcar (lambda (id)
             (let ((detail (and isled-data-details
                                (gethash id isled-data-details))))
               `((id . ,id) (hash . ,(if detail (isled-detail-hash detail)
                                       :json-null)))))
           ids)))

(defvar-local isled-data--summary nil
  "Indexed summary list for the current filtered view.")
(defvar-local isled-data--visible nil
  "Indexed combined list exposed to the renderer.")
(defvar-local isled-data--files nil
  "Unavailable records indexed by issue identity.")
(defvar-local isled-data--projection nil
  "Mutable combined snapshot retained until the next full view.")

(defun isled-data-accept (response)
  "Retain validated RESPONSE and return the current mutable snapshot.
Only a full view rebuilds the projection; details update touched identities."
  (unless isled-data-details
    (setq isled-data-details (make-hash-table :test #'equal)
          isled-data-targets (make-hash-table :test #'equal)))
  (when (isled-response-view response)
    (setq isled-data-view (isled-response-view response))
    (isled-data--recover-view))
  (when (or (isled-response-view response)
            (not isled-data--projection))
    (isled-data--index (isled-data-snapshot)))
  (when (isled-response-view-hash response)
    (setq isled-data-hash (isled-response-view-hash response)))
  (let ((rows (make-hash-table :test #'equal))
        (invalid (make-hash-table :test #'equal))
        (touched (make-hash-table :test #'equal)))
    (dolist (detail (isled-response-changes response))
      (isled-data--collect detail rows invalid touched))
    (maphash (lambda (id _) (isled-data--update id rows invalid)) touched))
  (setf (isled-snapshot-issues isled-data-view)
        (isled-sequence-list isled-data--summary)
        (isled-snapshot-issues isled-data--projection)
        (isled-sequence-list isled-data--visible)
        (isled-snapshot-unavailable isled-data-view)
        (hash-table-values isled-data--files)
        (isled-snapshot-unavailable isled-data--projection)
        (sort (hash-table-values isled-data--files)
              (lambda (a b) (string< (isled-unavailable-id a)
                                    (isled-unavailable-id b)))))
  isled-data--projection)

(defun isled-data--recover-view ()
  "Let a new full view supersede cached problems for its valid identities."
  (dolist (issue (isled-snapshot-issues isled-data-view))
    (let* ((id (isled-issue-id issue))
           (detail (gethash id isled-data-details)))
      (when (and detail (not (eq (isled-detail-type detail) 'issue)))
        (remhash id isled-data-details)))))

(defun isled-data--index (snapshot)
  "Retain indexes for a complete accepted SNAPSHOT."
  (setq isled-data--projection snapshot
        isled-data--summary (isled-sequence-index
                               (isled-snapshot-issues isled-data-view))
        isled-data--visible (isled-sequence-index (isled-snapshot-issues snapshot))
        isled-data--files (make-hash-table :test #'equal))
  (dolist (file (isled-snapshot-unavailable isled-data-view))
    (puthash (isled-unavailable-id file) file isled-data--files))
  (setf (isled-snapshot-issues isled-data-view)
        (isled-sequence-list isled-data--summary)
        (isled-snapshot-issues snapshot) (isled-sequence-list isled-data--visible))
  snapshot)

(defun isled-data--collect (detail rows invalid touched)
  "Apply DETAIL cache effects and collect ROWS, INVALID identities and TOUCHED IDs."
  (let ((id (isled-detail-id detail)))
    (puthash id detail isled-data-details)
    (puthash id t touched)
    (unless (eq (isled-detail-type detail) 'issue) (puthash id t invalid))
    (remhash id isled-data--files)
    (remhash id isled-data-targets))
  (when-let ((issue (isled-detail-issue detail)))
    (dolist (reference (isled-issue-references issue))
      (when (eq (isled-inline-reference-resolution reference) 'missing)
        (let ((id (isled-inline-reference-target-id reference)))
          (puthash id t invalid)
          (puthash id t touched)
          (remhash id isled-data-targets)))))
  (dolist (issue (append (when (isled-detail-issue detail)
                           (list (isled-detail-issue detail)))
                         (isled-detail-targets detail)))
    (let ((id (isled-issue-id issue)))
      (puthash id issue rows)
      (puthash id t touched)
      (puthash id issue isled-data-targets)
      (remhash id isled-data--files)))
  (dolist (file (isled-detail-unavailable detail))
    (let ((id (isled-unavailable-id file)))
      (puthash id t touched)
      (puthash id t invalid)
      (puthash id file isled-data--files)
      (remhash id isled-data-targets))))

(defun isled-data--update (id rows invalid)
  "Apply final batch ROWS and INVALID state to the retained entry for ID."
  (let ((summary (isled-sequence-get isled-data--summary id))
        (targets (isled-snapshot-targets isled-data--projection)))
    (if (gethash id invalid)
        (progn
          (isled-sequence-remove isled-data--summary id)
          (isled-sequence-remove isled-data--visible id))
      (when summary
        (setq summary (or (gethash id rows) summary))
        (isled-sequence-replace isled-data--summary summary)
        (let ((merged (isled-data--merge summary (gethash id isled-data-details))))
          (unless (isled-sequence-replace isled-data--visible merged)
            (error "Missing indexed visible issue %s" id)))))
    (let ((target (or (isled-sequence-get isled-data--visible id)
                      (gethash id isled-data-targets))))
      (if target (puthash id target targets) (remhash id targets)))))

(defun isled-data-snapshot ()
  "Combine the current summaries with retained detail data for presentation."
  (let ((targets (copy-hash-table isled-data-targets))
        (unavailable (make-hash-table :test #'equal)) issues)
    (dolist (file (isled-snapshot-unavailable isled-data-view))
      (puthash (isled-unavailable-id file) file unavailable))
    (dolist (summary (isled-snapshot-issues isled-data-view))
      (let* ((id (isled-issue-id summary))
             (detail (gethash id isled-data-details)))
        (pcase (and detail (isled-detail-type detail))
          ('deleted nil)
          ('problem
           (puthash id (car (isled-detail-unavailable detail)) unavailable))
          (_ (unless (gethash id unavailable)
               (push (isled-data--merge summary detail) issues))))))
    ;; Current list summaries take precedence over older cached target labels.
    (dolist (issue issues) (puthash (isled-issue-id issue) issue targets))
    (isled-snapshot-create
     :root (isled-snapshot-root isled-data-view)
     :issues (nreverse issues) :targets targets
     :unavailable (sort (hash-table-values unavailable)
                        (lambda (a b) (string< (isled-unavailable-id a)
                                               (isled-unavailable-id b)))))))

(defun isled-data--merge (summary detail)
  "Use SUMMARY metadata with the cached body and annotations from DETAIL."
  (if (not (and detail (isled-detail-issue detail))) summary
    (let ((issue (copy-isled-issue summary))
          (body (isled-detail-issue detail)))
      (setf (isled-issue-content issue) (isled-issue-content body)
            (isled-issue-references issue) (isled-issue-references body)
            (isled-issue-warnings issue) (isled-issue-warnings body))
      issue)))

(provide 'isled-data)
;;; isled-data.el ends here
