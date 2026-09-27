;;; isled-view.el --- Rendering for isled  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT

;; Author: Sacha De Vos
;; Assisted-by: Codex:GPT-6
;; Keywords: tools

;;; Commentary:

;; Pure filtering and selection for project issue presentations.  This library
;; does not run processes, discover ledgers, or mutate buffers.

;;; Code:

(require 'cl-lib)
(require 'isled-snapshot)
(require 'isled-graph-model)
(require 'seq)

(defun isled-view-visible-issues (snapshot filter &optional graph)
  "Return issues from SNAPSHOT matching FILTER.

FILTER is `open', `closed', `all', or a Rust query.  GRAPH supplies lane order."
  (let ((status (pcase filter
                  ('open "open")
                  ('closed "closed")
                  ('all nil)
                  ((pred stringp) nil)
                  (_ (error "Unknown isled filter: %S" filter)))))
    (isled-graph-order (seq-filter (lambda (issue)
                  (or (null status)
                      (string= (isled-issue-status issue) status)))
                (isled-snapshot-issues snapshot)) graph)))

(defun isled-view-select-id (issues preferred-id)
  "Choose an identifier from ISSUES, retaining PREFERRED-ID when present."
  (if (and preferred-id
           (seq-some (lambda (issue)
                       (string= preferred-id (isled-issue-id issue)))
                     issues))
      preferred-id
    (when-let ((first (car issues)))
      (isled-issue-id first))))

(defun isled-view-replacement-id (issues missing-id)
  "Choose the positional replacement for MISSING-ID from ordered ISSUES.

Prefer the first issue after MISSING-ID.  When there is no successor, return
the final preceding issue.  Return nil when ISSUES is empty."
  (if-let ((successor
            (seq-find
             (lambda (issue)
               (string< missing-id (isled-issue-id issue)))
             issues)))
      (isled-issue-id successor)
    (when-let ((preceding (car (last issues))))
      (isled-issue-id preceding))))

(defun isled-view-index-issues (issues)
  "Index validated ISSUES by identity for repeated lookups."
  (let ((index (make-hash-table :test #'equal :size (length issues))))
    (dolist (issue issues)
      (puthash (isled-issue-id issue) issue index))
    index))

(defun isled-view-find-issue (issues id)
  "Return the issue in ISSUES whose identifier is ID."
  (seq-find (lambda (issue)
              (string= id (isled-issue-id issue)))
            issues))

(defun isled-view-find-target (snapshot id)
  "Find ID in SNAPSHOT's target index or visible issues."
  (or (and (hash-table-p (isled-snapshot-targets snapshot))
           (gethash id (isled-snapshot-targets snapshot)))
      (isled-view-find-issue (isled-snapshot-issues snapshot) id)))

(provide 'isled-view)
;;; isled-view.el ends here
