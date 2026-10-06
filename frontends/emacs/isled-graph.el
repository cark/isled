;;; isled-graph.el --- Dependency presentation interaction -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Assisted-by: Codex:GPT-6
;; Keywords: tools

;;; Commentary:
;; Toggle or reverse dependency presentation, retaining the query and location.
;; Logical ordering and gutters belong to the model and painting modules.

;;; Code:
(require 'isled-graph-model)
(require 'isled-filter-query)
(require 'isled-navigation)
(require 'isled-listing)
(require 'isled-view-state)
(defvar isled-loading-active)
(defvar isled-loading-graph-intent)
(declare-function isled--capture-view-state "isled-browser" ())
(declare-function isled--restore-view-state "isled-browser" (state &optional callback))

;;;###autoload
(defun isled-graph-toggle ()
  "Switch flat/hierarchical presentation, preserving query and browsing state."
  (interactive nil isled-mode)
  (let ((direction (if isled-loading-active isled-loading-graph-intent isled-graph-direction)))
    (isled-listing-order (if direction isled-listing-flat-order 'hierarchy))))

;;;###autoload
(defun isled-graph-reverse ()
  "Switch prerequisites/objectives in column one, preserving query and selection."
  (interactive nil isled-mode)
  (isled-navigation-with-window
    (let ((origin (isled--capture-view-state))
          (direction (if isled-loading-active isled-loading-graph-intent isled-graph-direction)))
      (unless direction (user-error "Enable hierarchical view with v first"))
      (let ((state (copy-isled--view-state origin)))
        (setf (isled--view-state-graph-direction state)
              (if (eq direction 'prerequisites) 'dependents 'prerequisites)
              (isled--view-state-preferred-state state) origin)
        (isled--restore-view-state state)))))

(defun isled-graph-header-filter (filter)
  "Return FILTER's identity label including the current presentation."
  (let ((query (string-trim (isled-filter-query-text filter))))
    (concat (if (string-empty-p query) "All" query) " · "
            (pcase isled-graph-direction
              ('prerequisites "prerequisites first")
              ('dependents "dependents first")
              (_ (if (eq (isled-filter-query-order filter) 'oldest-first)
                     "flat · oldest first" "flat · issue ID"))))))

(provide 'isled-graph)
;;; isled-graph.el ends here
