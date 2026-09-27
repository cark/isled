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
(defvar isled-loading-active)
(defvar isled-loading-graph-intent)
(declare-function isled--capture-view-state "isled-browser" ())
(declare-function isled--restore-view-state "isled-browser" (state &optional callback))
(declare-function isled--view-state-create "isled-browser" (&rest fields))
(declare-function isled--view-state-filter "isled-browser" (state))
(declare-function isled--view-state-selected-id "isled-browser" (state))
(declare-function isled--view-state-expanded-ids "isled-browser" (state))
(declare-function isled--view-state-point-state "isled-browser" (state))
(declare-function isled--view-state-ledger-point "isled-browser" (state))

;;;###autoload
(defun isled-graph-toggle ()
  "Switch flat/hierarchical presentation, preserving query and browsing state."
  (interactive nil isled-mode)
  (isled-navigation-with-window
    (let ((origin (isled--capture-view-state))
          (direction (if isled-loading-active isled-loading-graph-intent isled-graph-direction)))
      (isled--restore-view-state
       (isled--view-state-create
        :filter (isled--view-state-filter origin)
        :graph-direction (unless direction (or isled-graph-layout-direction 'prerequisites))
        :selected-id (isled--view-state-selected-id origin)
        :expanded-ids (copy-sequence (isled--view-state-expanded-ids origin))
        :point-state (isled--view-state-point-state origin)
        :ledger-point (isled--view-state-ledger-point origin)
        :preferred-state origin)))))

;;;###autoload
(defun isled-graph-reverse ()
  "Switch prerequisites/objectives in column one, preserving query and selection."
  (interactive nil isled-mode)
  (isled-navigation-with-window
    (let ((origin (isled--capture-view-state))
          (direction (if isled-loading-active isled-loading-graph-intent isled-graph-direction)))
      (unless direction (user-error "Enable hierarchical view with v first"))
      (isled--restore-view-state
       (isled--view-state-create
        :filter (isled--view-state-filter origin)
        :graph-direction (if (eq direction 'prerequisites) 'dependents 'prerequisites)
        :selected-id (isled--view-state-selected-id origin)
        :expanded-ids (copy-sequence (isled--view-state-expanded-ids origin))
        :point-state (isled--view-state-point-state origin)
        :preferred-state origin)))))

(defun isled-graph-header-filter (filter)
  "Return FILTER's identity label including the current presentation."
  (let ((query (string-trim (isled-filter-query-text filter))))
    (concat (if (string-empty-p query) "All" query) " · "
            (pcase isled-graph-direction
              ('prerequisites "prerequisites first")
              ('dependents "dependents first")
              (_ "flat")))))

(provide 'isled-graph)
;;; isled-graph.el ends here
