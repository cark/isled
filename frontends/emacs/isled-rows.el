;;; isled-rows.el --- Indexed issue text positions  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Assisted-by: Codex:GPT-6
;; Keywords: tools

;;; Commentary:

;; Complete headings and routing placeholders are ordinary buffer text.  Each row
;; owns heading/body boundaries; edits update following positions in one traversal.

;;; Code:

(require 'cl-lib)
(require 'isled-snapshot)

(cl-defstruct isled-row
  issue index start heading-end content end heading-key (hidden t) heading-background fold materialized rich)
(defvar-local isled-rows [] "Ordered rows in this buffer.")
(defvar-local isled-rows-index nil "Issue ID to row lookup.")
(defvar-local isled-rows-expanded nil "Set of currently expanded rows.")

(defun isled-rows-heading-key (issue)
  "Capture the values used to render ISSUE's heading."
  (vector (isled-issue-title issue) (isled-issue-kind issue)
          (isled-issue-status issue) (isled-issue-ready issue)
          (isled-work-data-label (isled-issue-work issue))
          (and (isled-issue-work issue)
               (isled-work-data-question (isled-issue-work issue)))))

(defun isled-rows-heading-matches-p (row issue)
  "Return non-nil when ROW already displays ISSUE's heading values."
  (let ((key (isled-row-heading-key row)))
    (and (equal (aref key 0) (isled-issue-title issue))
         (equal (aref key 1) (isled-issue-kind issue))
         (equal (aref key 2) (isled-issue-status issue))
         (eq (aref key 3) (isled-issue-ready issue))
         (equal (aref key 4) (isled-work-data-label (isled-issue-work issue)))
         (equal (aref key 5) (and (isled-issue-work issue)
                                  (isled-work-data-question (isled-issue-work issue)))))))

(defun isled-row-value (row)
  "Return the identity of ROW."
  (isled-issue-id (isled-row-issue row)))

(defun isled-row-at (&optional position)
  "Return the row at POSITION or point, including retained folded text."
  (when (< (point-min) (point-max))
    (get-text-property (min (or position (point)) (1- (point-max))) 'isled-row)))

(defun isled-rows-clear ()
  "Release overlays owned by the existing row model."
  (seq-doseq (row isled-rows)
    (dolist (overlay (list (isled-row-fold row)
                          (isled-row-heading-background row)))
      (when (overlayp overlay) (delete-overlay overlay))))
  (setq isled-rows [] isled-rows-index nil
        isled-rows-expanded nil))

(defun isled-rows-insert (issues heading &optional routing)
  "Insert ISSUES with HEADING text and optional ROUTING text before each body.
Both callbacks receive the issue.  Routing lines remain visible when folded."
  (let ((position (point)) (index 0) rows chunks)
    (isled-rows-clear)
    (setq isled-rows-index (make-hash-table :test #'equal)
          isled-rows-expanded (make-hash-table :test #'eq))
    (dolist (issue issues)
      (let* ((title (funcall heading issue))
             (text (concat title (when routing (funcall routing issue))))
             (end (+ position (length text)))
             (row (make-isled-row :issue issue :index index
                                          :start position :heading-end (+ position (length title))
                                          :content end :end end
                                          :heading-key (isled-rows-heading-key issue))))
        (add-text-properties 0 (length text)
                             (list 'isled-row row 'rear-nonsticky t) text)
        (push text chunks)
        (push row rows)
        (puthash (isled-issue-id issue) row isled-rows-index)
        (setq position end index (1+ index))))
    (insert (apply #'concat (nreverse chunks)))
    (setq isled-rows (vconcat (nreverse rows))))
  (add-hook 'kill-buffer-hook #'isled-rows-clear nil t)
  (add-hook 'change-major-mode-hook #'isled-rows-clear nil t))

(defun isled-rows-shift (row delta)
  "Adjust positions following ROW by DELTA after a text replacement."
  (unless (zerop delta)
    (cl-loop for index from (1+ (isled-row-index row))
             below (length isled-rows)
             for next = (aref isled-rows index)
             do (cl-incf (isled-row-start next) delta)
             do (cl-incf (isled-row-heading-end next) delta)
             do (cl-incf (isled-row-content next) delta)
             do (cl-incf (isled-row-end next) delta))))

(defun isled-rows-write-body (row text)
  "Replace ROW's retained body with TEXT, preserving its identity."
  (let* ((start (isled-row-content row))
         (end (isled-row-end row))
         (delta (- (length text) (- end start)))
         (inhibit-read-only t))
    (save-excursion
      (goto-char start)
      (delete-region start end)
      (insert (propertize text 'isled-row row 'rear-nonsticky t)))
    (cl-incf (isled-row-end row) delta)
    (isled-rows-shift row delta)
    (set-buffer-modified-p nil)))

(defun isled-rows-write-heading (row text)
  "Replace ROW's heading with TEXT and adjust following positions."
  (let* ((start (isled-row-start row))
         (end (isled-row-heading-end row))
         (delta (- (length text) (- end start)))
         (inhibit-read-only t))
    (save-excursion
      (goto-char start)
      (delete-region start end)
      (insert (propertize text 'isled-row row 'rear-nonsticky t)))
    (setf (isled-row-heading-key row)
          (isled-rows-heading-key (isled-row-issue row)))
    (cl-incf (isled-row-heading-end row) delta)
    (cl-incf (isled-row-content row) delta)
    (cl-incf (isled-row-end row) delta)
    (isled-rows-shift row delta)))

(defun isled-rows-style-body (row text)
  "Apply TEXT properties to ROW without replacing its searchable characters."
  (let ((start (isled-row-content row))
        (end (isled-row-end row)) (offset 0))
    (unless (equal (substring-no-properties text) (buffer-substring-no-properties start end))
      (error "Presentation changed text for %s" (isled-row-value row)))
    (with-silent-modifications
      (set-text-properties start end (list 'isled-row row 'rear-nonsticky t))
      (while (< offset (length text))
        (let ((next (next-property-change offset text (length text))))
          (add-text-properties (+ start offset) (+ start next) (text-properties-at offset text))
          (setq offset next))))))

(provide 'isled-rows)
;;; isled-rows.el ends here
