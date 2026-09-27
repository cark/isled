;;; isled-filter-query.el --- Filter text and structured criteria -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Assisted-by: Codex:GPT-6
;; Keywords: tools

;;; Commentary:
;; Parse the frontend's small AND grammar and retain token boundaries for editing.
;;; Code:
(require 'cl-lib)
(require 'subr-x)

(defun isled-filter-query-tokens (text &optional partial)
  "Tokenize TEXT as (START END VALUE QUOTED), tolerating unfinished PARTIAL input."
  (let ((position 0) (length (length text)) tokens)
    (while (< position length)
      (if (memq (aref text position) '(?\s ?\t)) (cl-incf position)
        (let ((start position) quoted inside chars)
          (while (and (< position length)
                      (or inside (not (memq (aref text position) '(?\s ?\t)))))
            (let ((character (aref text position)))
              (cond
               ((eq character ?\") (setq quoted t inside (not inside)))
               ((and inside (eq character ?\\) (< (1+ position) length)
                     (memq (aref text (1+ position)) '(?\\ ?\")))
                (cl-incf position) (push (aref text position) chars))
               (t (push character chars))))
            (cl-incf position))
          (when (and inside (not partial)) (user-error "Close the quoted phrase"))
          (push (list start position (apply #'string (nreverse chars)) quoted) tokens))))
    (nreverse tokens)))

(defun isled-filter-query-text (filter)
  "Return the editable query for FILTER, including the initial status choice."
  (pcase filter
    ('open "s:open ") ('closed "s:closed ") ('all "")
    ((pred stringp) filter)
    (_ (error "Invalid issue filter"))))

(defun isled-filter-query-initial (filter)
  "Return FILTER ready for appending another filter term."
  (let ((query (isled-filter-query-text filter)))
    (if (or (string-empty-p query) (string-match-p "[ \t]\\'" query))
        query
      (concat query " "))))

(defun isled-filter-query-criteria (filter)
  "Parse FILTER into bounded-protocol criteria, or signal actionable input errors."
  (when (string-match-p "[\n\r]" (isled-filter-query-text filter))
    (user-error "Filter must be one line"))
  (let ((status "all") tags kinds text)
    (dolist (token (isled-filter-query-tokens
                    (isled-filter-query-text filter)))
      (let ((value (nth 2 token)))
        (if (and (not (nth 3 token)) (string-match "\\`\\([tks]\\):\\(.*\\)\\'" value))
            (let ((prefix (match-string 1 value)) (name (match-string 2 value)))
              (unless (string-match-p "\\`[a-z0-9]+\\(?:-[a-z0-9]+\\)*\\'" name)
                (user-error "Complete %s with a lowercase name" value))
              (pcase prefix
                ("s" (setq status (pcase name ("open" "open") ("closed" "closed")
                                         (_ (user-error "Status is open or closed")))))
                ("t" (push name tags))
                ("k" (push name kinds))))
          (unless (string-empty-p value) (push value text)))))
    `((status . ,status) (tags . ,(vconcat (nreverse tags)))
      (kinds . ,(vconcat (nreverse kinds))) (text . ,(vconcat (nreverse text))))))

(defun isled-filter-query-status (filter status)
  "Replace FILTER's status terms with STATUS, retaining other original tokens."
  (let* ((query (isled-filter-query-text filter))
         (tokens (isled-filter-query-tokens query t))
         (retained (cl-loop for token in tokens
                            unless (and (not (nth 3 token))
                                        (string-prefix-p "s:" (nth 2 token)))
                            collect (substring query (car token) (cadr token)))))
    (string-join (append (pcase status ('open '("s:open")) ('closed '("s:closed")))
                         retained) " ")))

(provide 'isled-filter-query)
;;; isled-filter-query.el ends here
