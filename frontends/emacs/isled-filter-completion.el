;;; isled-filter-completion.el --- Filter token completion context -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Assisted-by: Codex:GPT-6
;; Keywords: tools

;;; Commentary:
;; Locate a query token and scope structured choices without changing input.
;;; Code:
(require 'isled-filter-query)
(require 'seq)

(defun isled-filter-completion-choices (part choices)
  "Narrow CHOICES to the structured prefix in PART, if present."
  (setq choices (append choices '("o:oldest-first" "o:id")))
  (if (string-match "\\`[tkswron]:" part)
      (let ((prefix (match-string 0 part)))
        (seq-filter (lambda (choice) (string-prefix-p prefix choice)) choices))
    choices))

(defun isled-filter-completion-token (text position)
  "Return (START END BEFORE WHOLE) for the token in TEXT at POSITION.
BEFORE is its text before point.  Quoted literal tokens return nil."
  (let* ((token (seq-find (lambda (item) (<= (car item) position (cadr item)))
                          (isled-filter-query-tokens text t)))
         (start (if token (car token) position))
         (end (if token (cadr token) position))
         (part (substring text start position))
         (whole (substring text start end)))
    (unless (nth 3 token)
      (list start end part whole))))

(cl-defstruct (isled-filter-context
               (:constructor isled-filter-context-create))
              "One exact editable token occurrence and the other provisional constraints."
              text point start end before whole criteria)

(defun isled-filter-completion-context (text position)
  "Describe completion at POSITION in TEXT, parsing only the other terms.
Status replacement excludes every status term; other edits exclude one span."
  (when-let ((token (isled-filter-completion-token text position)))
    (pcase-let* ((`(,start ,end ,before ,whole) token)
                 (status (string-prefix-p "s:" whole))
                 (remaining
                  (if status (isled-filter-query-status text 'all)
                    (concat (substring text 0 start) (substring text end)))))
      (isled-filter-context-create
       :text text :point position :start start :end end :before before :whole whole
       :criteria (isled-filter-query-criteria remaining)))))

(defvar-local isled-filter-completion-context nil
  "Exact context currently awaiting or holding structured choices.")
(defvar-local isled-filter-completion-values nil
  "Current contextual choices; nil also represents no matches.")
(defvar-local isled-filter-completion-pending nil
  "Non-nil while current context is awaiting its reply.")
(defvar-local isled-filter-completion-update-hook nil
  "Local functions updating the active completion display after choice delivery.")

(defun isled-filter-completion-status-exit (choice status)
  "After inserting CHOICE with completion STATUS, remove other status tokens."
  (when (memq status '(finished exact))
    (let* ((offset (minibuffer-prompt-end))
           (position (- (point) offset))
           (query (minibuffer-contents-no-properties))
           (tokens (isled-filter-query-tokens query t))
           (inserted
            (seq-find
             (lambda (token)
               (and (<= (car token) position (1+ (cadr token)))
                    (not (nth 3 token))
                    (string-prefix-p "s:" (nth 2 token))
                    (string-suffix-p (nth 2 token) (string-trim-right choice))))
             tokens)))
      (when inserted
        (save-excursion
          (dolist (token (reverse tokens))
            (when (and (not (eq token inserted)) (not (nth 3 token))
                       (string-prefix-p "s:" (nth 2 token)))
              (delete-region (+ offset (car token)) (+ offset (cadr token))))))))))

(provide 'isled-filter-completion)
;;; isled-filter-completion.el ends here
