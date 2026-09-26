;;; isled-sequence.el --- Indexed issue list spines  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Keywords: tools

;;; Commentary:

;; Retain an ordered issue list while replacing and removing known IDs directly.
;; Only this module mutates its private list spine and predecessor index.

;;; Code:

(require 'cl-lib)
(require 'isled-snapshot)

(cl-defstruct isled-sequence head previous)

(defun isled-sequence-index (issues)
  "Index a private list spine of ISSUES for direct replacement and removal."
  (let* ((head (cons nil (copy-sequence issues)))
         (previous (make-hash-table :test #'equal))
         (cursor head))
    (while (cdr cursor)
      (puthash (isled-issue-id (cadr cursor)) cursor previous)
      (setq cursor (cdr cursor)))
    (make-isled-sequence :head head :previous previous)))

(defun isled-sequence-get (chain id)
  "Return ID's retained issue in CHAIN, or nil."
  (cadr (gethash id (isled-sequence-previous chain))))

(defun isled-sequence-replace (chain issue)
  "Replace an existing ISSUE in CHAIN; return non-nil if it belongs there."
  (when-let ((previous (gethash (isled-issue-id issue)
                               (isled-sequence-previous chain))))
    (setcar (cdr previous) issue)
    t))

(defun isled-sequence-remove (chain id)
  "Remove ID from CHAIN in constant time, preserving all other list cells."
  (when-let ((previous (gethash id (isled-sequence-previous chain))))
    (setcdr previous (cddr previous))
    (remhash id (isled-sequence-previous chain))
    (when (cdr previous)
      (puthash (isled-issue-id (cadr previous)) previous
               (isled-sequence-previous chain)))))

(defun isled-sequence-list (chain)
  "Return the current retained list in CHAIN."
  (cdr (isled-sequence-head chain)))

(provide 'isled-sequence)

;;; isled-sequence.el ends here
