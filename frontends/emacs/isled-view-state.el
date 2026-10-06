;;; isled-view-state.el --- Restorable issue view values -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Assisted-by: Codex:GPT-6
;; Keywords: tools

;;; Commentary:
;; Share the view value between navigation, filters and ordering commands without
;; loading the browser while compiling those commands.

;;; Code:
(require 'cl-lib)

(cl-defstruct (isled--view-state
               (:constructor isled--view-state-create))
  "Opaque restorable state for one issue filter."
  filter
  selected-id
  expanded-ids
  point-state
  preferred-state
  ledger-point
  (flat-order 'id)
  (graph-direction 'prerequisites))

(provide 'isled-view-state)
;;; isled-view-state.el ends here
