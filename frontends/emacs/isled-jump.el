;;; isled-jump.el --- Choose a ledger issue to visit -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Keywords: tools

;;; Commentary:
;; Fetch summaries independently of the visible filter, then use shared navigation.

;;; Code:
(require 'isled-frontend)
(require 'isled-process)
(require 'isled-navigation)

(defvar isled--root)
(defvar-local isled-jump--serial 0 "Generation of the latest issue chooser request.")
(declare-function isled--capture-view-state "isled-browser")
(declare-function isled--visit-issue "isled-browser")

(defun isled-jump--id (text)
  "Normalize a complete numeric issue ID in TEXT, or return nil."
  (when (string-match-p "\\`#?[0-9]\\{1,4\\}\\'" text)
    (format "%04d" (string-to-number (string-remove-prefix "#" text)))))

(defun isled-jump--read (issues)
  "Read a destination from typed ledger summary ISSUES."
  (unless issues (user-error "No readable issues in this ledger"))
  (let* ((candidates (mapcar (lambda (issue)
                               (cons (format "%s — %s" (isled-issue-id issue)
                                             (isled-issue-title issue)) issue)) issues))
         ;; Retain configured styles; substring is a fallback for title matching.
         (completion-styles (append completion-styles '(substring)))
         (completion-extra-properties
          (list :annotation-function
                (lambda (candidate)
                  (concat "  " (isled-issue-status (cdr (assoc candidate candidates)))))))
         (choice (completing-read
                  "Jump to issue: "
                  (lambda (string predicate action)
                    (if (eq action 'metadata) '(metadata (category . isled-issue))
                      (complete-with-action action candidates
                                            (or (isled-jump--id string) string) predicate)))
                  nil nil))
         (id (isled-jump--id choice)))
    (or (cdr (assoc choice candidates))
        (and id (seq-find (lambda (issue) (equal id (isled-issue-id issue))) issues))
        (user-error "No issue matches %s" choice))))

(defun isled-jump--receive (result root origin serial)
  "Offer RESULT for ROOT only while ORIGIN and request SERIAL remain current."
  (when (and (= serial isled-jump--serial) (equal root isled--root)
             (isled-navigation-valid-p origin)
             (eq (selected-window) (car origin))
             (not (active-minibuffer-window)))
    (condition-case failure
        (progn
          (unless (eql (isled-command-result-status result) 0)
            (error "%s" (isled-snapshot--failure-message result)))
          (let* ((response (isled-frontend-decode (isled-command-result-stdout result)))
                 (view (isled-response-view response)))
            (unless (and view (equal root (isled-response-root response)))
              (error "Missing ledger issue choices"))
            (isled-navigation-at-origin
             origin
             (lambda ()
               (let ((target (isled-jump--read (isled-snapshot-issues view)))
                     (state (isled--capture-view-state)))
                 (isled--visit-issue target (lambda () (isled-navigation-record state))))))))
      (quit nil)
      (error (message "Cannot jump to issue: %s" (error-message-string failure))))))

(defun isled-jump-to-issue ()
  "Choose an issue by ID or title from this ledger, independent of its filter."
  (interactive nil isled-mode)
  (unless isled--root (user-error "The ledger is still loading"))
  (let ((buffer (current-buffer))
        (root isled--root)
        (origin (isled-navigation-origin))
        (serial (cl-incf isled-jump--serial)))
    (funcall isled-process-function root
             (json-encode '((schema_version . 3) (mode . "view")
                            (filter . ((status . "all"))) (details . [])))
             (lambda (result)
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (isled-jump--receive result root origin serial)))))))

(provide 'isled-jump)
;;; isled-jump.el ends here
