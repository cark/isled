;;; isled-listing.el --- Issue ordering and limits -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Assisted-by: Codex:GPT-6
;; Keywords: tools

;;; Commentary:
;; Keep listing choices in the query so refresh and history retain them.
;; Rust owns selection and ordering; oldest-first presentation uses flat rows.

;;; Code:
(require 'isled-filter)
(defvar isled--filter)

(defun isled-listing-order (order)
  "Select ORDER, either oldest-first or id, for this issue view."
  (interactive
   (list (if (equal (completing-read "Issue order: " '("Oldest first" "ID") nil t)
                    "Oldest first") 'oldest-first 'id)))
  (unless (memq order '(oldest-first id)) (user-error "Choose oldest-first or id"))
  (isled-filter--request
   (isled-filter-query-term isled--filter "o:" (symbol-name order))
   nil nil (eq order 'oldest-first)))

(defun isled-listing-limit (limit)
  "Show at most LIMIT matching issues, or all matches when LIMIT is nil."
  (interactive
   (list (let ((text (read-string "Issue limit (empty for all): ")))
           (unless (string-empty-p text)
             (unless (string-match-p "\\`[0-9]+\\'" text)
               (user-error "Limit is a non-negative number of issues"))
             (string-to-number text)))))
  (unless (or (null limit) (natnump limit))
    (user-error "Limit is a non-negative number of issues"))
  (isled-filter--request
   (isled-filter-query-term isled--filter "n:" (and limit (number-to-string limit)))))

(provide 'isled-listing)
;;; isled-listing.el ends here
