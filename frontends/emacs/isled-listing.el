;;; isled-listing.el --- Exclusive issue ordering modes -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Assisted-by: Codex:GPT-6
;; Keywords: tools

;;; Commentary:
;; Select dependency hierarchy or one flat order, retaining the last flat choice.
;; Rust owns selection and ordering; view state owns refresh and history memory.

;;; Code:
(require 'isled-filter)
(require 'isled-view-state)
(defvar isled-graph-direction)
(defvar isled-graph-layout-direction)
(defvar-local isled-listing-flat-order 'id "Last selected flat issue order.")
(declare-function isled--capture-view-state "isled-browser")
(declare-function isled--restore-view-state "isled-browser")

(defun isled-listing-order (order)
  "Select ORDER: hierarchy, id, or oldest-first, preserving browsing state."
  (interactive
   (list (pcase (completing-read "Issue order: "
                                '("Hierarchy" "Issue ID" "Oldest first") nil t)
           ("Hierarchy" 'hierarchy) ("Issue ID" 'id) (_ 'oldest-first))))
  (unless (memq order '(hierarchy id oldest-first))
    (user-error "Choose hierarchy, id or oldest-first"))
  (isled-navigation-with-window
    (let* ((origin (isled--capture-view-state))
           (state (copy-isled--view-state origin))
           (filter (isled--view-state-filter origin))
           (query (cond
                   ((eq order 'oldest-first)
                    (isled-filter-query-term filter "o:" "oldest-first"))
                   ((stringp filter) (isled-filter-query-term filter "o:" nil))
                   (t filter))))
      (setf (isled--view-state-filter state) query
            (isled--view-state-graph-direction state)
            (when (eq order 'hierarchy)
              (or isled-graph-direction isled-graph-layout-direction 'prerequisites))
            (isled--view-state-flat-order state)
            (if (eq order 'hierarchy) (isled--view-state-flat-order origin) order)
            (isled--view-state-preferred-state state) origin)
      ;; Remember the choice immediately so a following toggle need not wait
      ;; for the asynchronously loaded flat list to appear.
      (setq isled-listing-flat-order (isled--view-state-flat-order state))
      (isled--restore-view-state state))))

(provide 'isled-listing)
;;; isled-listing.el ends here
