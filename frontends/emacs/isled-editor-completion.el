;;; isled-editor-completion.el --- Draft completion and lazy previews -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Keywords: tools

;;; Commentary:
;; Standard completion data without controlling the user's display framework.

;;; Code:
(require 'isled-editor-form)
(require 'isled-frontend)
(defvar-local isled-editor-choices nil "Kind and tag candidates for this ledger.")

(defun isled-editor-completion-refresh ()
  "Refresh completion metadata asynchronously for the current ledger."
  (dolist (entry isled-editor-documents)
    (when (buffer-live-p (cdr entry)) (kill-buffer (cdr entry))))
  (setq isled-editor-documents nil)
  (let ((buffer (current-buffer)))
    (isled-process-start
     isled-editor-root
     (json-encode '((schema_version . 3) (mode . "view")
                    (filter . ((status . "all"))) (details . [])))
     (lambda (result)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (condition-case failure
               (let* ((response (isled-frontend-decode (isled-command-result-stdout result)))
                      (view (isled-response-view response)))
                 (setq isled-editor-candidates (and view (isled-snapshot-issues view))
                       isled-editor-choices (isled-response-choices response)))
             (error (message "Issue completion unavailable: %s" (error-message-string failure))))))))))

(defun isled-editor-completion-document (candidate)
  "Return a bounded local text preview for issue CANDIDATE on demand.
Completion frameworks request documentation synchronously.  Read only the
selected local file for presentation; Rust still owns all semantic validation."
  (when (string-match "\\`#?\\([0-9]\\{4\\}\\)" candidate)
    (let* ((id (match-string 1 candidate))
           (issue (seq-find (lambda (row) (equal id (isled-issue-id row)))
                            isled-editor-candidates))
           (path (and issue (isled-issue-path issue)))
           (document (cdr (assoc id isled-editor-documents))))
      (when (and path (not (file-remote-p path)))
        (unless (buffer-live-p document)
          (setq document (generate-new-buffer (format " *isled preview %s*" id)))
          (push (cons id document) isled-editor-documents))
        (with-current-buffer document
          (let ((inhibit-read-only t))
            (erase-buffer)
            (condition-case failure
                (progn
                  (insert-file-contents path nil 0 16384)
                  (when (>= (buffer-size) 16384) (insert "\n[Preview truncated]")))
              (error (insert (error-message-string failure))))
            (goto-char (point-min))
            (special-mode)))
        document))))

(defun isled-editor-completion-issues (start end)
  "Complete issue IDs/titles between START and END."
  (let* ((insertion-start (copy-marker start))
         (rows isled-editor-candidates)
         (candidates (mapcar (lambda (issue)
                               (format "%s — %s" (isled-issue-id issue)
                                       (isled-issue-title issue))) rows)))
    (list start end
          (lambda (string predicate action)
            (if (eq action 'metadata) '(metadata (category . isled-issue))
              (complete-with-action action candidates string predicate)))
          :exclusive 'no
          :annotation-function
          (lambda (candidate)
            (let ((row (nth (cl-position candidate candidates :test #'equal) rows)))
              (concat "  " (isled-issue-status row))))
          :company-doc-buffer #'isled-editor-completion-document
          :exit-function
          (lambda (candidate status)
            (when (eq status 'finished)
              (let ((id (substring candidate 0 4)))
                (delete-region insertion-start (point))
                (insert id)))))))

(defun isled-editor-completion-at-point ()
  "Provide open-set field, issue-reference and local link completion."
  (when-let* ((widget (widget-field-find (point)))
              (locator (car (rassq widget isled-editor-fields))))
    (let* ((start (widget-field-start widget))
           (before (buffer-substring-no-properties start (point))))
      (cond
       ((equal locator "kind")
        (list start (widget-field-end widget) (cons "task" (mapcar (lambda (s) (substring s 2))
								   (seq-filter (lambda (s) (string-prefix-p "k:" s)) isled-editor-choices)))
              :exclusive 'no))
       ((equal locator "tags")
        (let* ((end (save-excursion
                      (skip-chars-forward "a-z0-9-" (widget-field-end widget)) (point)))
               (begin (save-excursion (skip-chars-backward "a-z0-9-" start) (point)))
               (used (split-string
                      (concat (buffer-substring-no-properties start begin) " "
                              (buffer-substring-no-properties end (widget-field-end widget)))
                      "[, \t\n]+" t)))
          (list begin end
                (seq-remove (lambda (tag) (member tag used))
                            (mapcar (lambda (s) (substring s 2))
                                    (seq-filter (lambda (s) (string-prefix-p "t:" s)) isled-editor-choices)))
                :exclusive 'no)))
       ((string-suffix-p ".id" locator)
        (isled-editor-completion-issues
         (if (eq (char-after start) ?#) (1+ start) start)
         (widget-field-end widget)))
       ((string-match "\\]([^()\n]*\\'" before)
        (let* ((begin (+ start (match-beginning 0) 2))
               (fragment (buffer-substring-no-properties begin (point))))
          (unless (string-match-p "\\`[a-zA-Z]+:" fragment)
            (let ((directory (or (file-name-directory fragment) "")))
              (list (+ begin (length directory)) (point)
                    (completion-table-dynamic
                     (lambda (prefix)
                       (file-name-all-completions prefix (expand-file-name directory isled-editor-root))))
                    :exclusive 'no)))))
       ((string-match "#\\([^#\n]*\\)\\'" before)
        (let ((fragment (match-string 1 before))
              (begin (+ start (match-beginning 1))))
          ;; A complete numeric reference ends at whitespace or punctuation.
          ;; Do not restart completion over the prose typed after acceptance.
          (unless (string-match-p "\\`[0-9]\\{4\\}\\(?:[^[:alnum:]]\\|\\'\\)" fragment)
            (isled-editor-completion-issues begin (point)))))))))

(provide 'isled-editor-completion)
;;; isled-editor-completion.el ends here
