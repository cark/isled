;;; isled.el --- Browse project issue ledgers  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT

;; Author: Sacha De Vos
;; Assisted-by: Codex:GPT-6
;; Version: 0.34.0
;; Package-Requires: ((emacs "30.1") (markdown-mode "2.6") (transient "0.8.0"))
;; Keywords: tools
;; URL: https://github.com/cark/isled

;;; Commentary:

;; A local expandable browser and draft editor for the Rust isled
;; command.  Invoke `isled' from a directory inside an initialized
;; project.  Each canonical ledger can own multiple independent view buffers.

;;; Code:
(require 'project)
(require 'isled-file-routing)

(defconst isled-required-cli-version "0.34.0"
  "Exact CLI release compatible with this frontend.
Independent of the version assigned by an Emacs package archive.")

(autoload 'isled-setup-cli "isled-cli" nil t)
(autoload 'isled-show-installation "isled-cli" nil t)
(autoload 'isled-cancel-setup "isled-cli" nil t)
(autoload 'isled "isled-entry" nil t)
(autoload 'isled-open-project "isled-entry" nil t)
(autoload 'isled-open-directory "isled-entry" nil t)
(autoload 'isled-duplicate-view "isled-buffers" nil t)
(autoload 'isled-edit-issue "isled-editor" nil t)
(autoload 'isled-close-issue "isled-editor" nil t)
(autoload 'isled-add-issue "isled-editor" nil t)
(autoload 'isled-open-source "isled-source" nil t)
(autoload 'isled-mode "isled-browser" nil t)
(autoload 'isled-graph-toggle "isled-graph" nil t)
(autoload 'isled-graph-reverse "isled-graph" nil t)

(declare-function isled-filter "isled-filter")
(declare-function isled-filter-open "isled-browser" ())
(declare-function isled-filter-closed "isled-browser" ())
(declare-function isled-filter-all "isled-browser" ())
(declare-function isled-refresh "isled-browser")
(declare-function isled-next "isled-browser")
(declare-function isled-previous "isled-browser")
(declare-function isled-next-issue "isled-browser")
(declare-function isled-previous-issue "isled-browser")
(declare-function isled-collapse-all "isled-browser")
(declare-function isled-activate "isled-browser")
(declare-function isled-jump-to-reference "isled-browser")
(declare-function isled-history-back "isled-browser")
(declare-function isled-history-forward "isled-browser")
(declare-function isled-work "isled-work")
(declare-function isled-help "isled-browser")
(declare-function isled-jump-to-issue "isled-jump")
(declare-function isled-jump-to-warning "isled-warnings")

(defvar isled--mode-map-version
  (if (featurep 'isled-browser) 0 8)
  "Version of package-owned migrations applied to the issue mode map.")

(defvar-keymap isled-mode-map
  :parent special-mode-map
  "e" #'isled-edit-issue
  "a" #'isled-add-issue
  "c" #'isled-close-issue
  "s" #'isled-open-source
  "f" #'isled-filter
  "v" #'isled-graph-toggle
  "d" #'isled-graph-reverse
  "O" #'isled-filter-open
  "C" #'isled-filter-closed
  "A" #'isled-filter-all
  "g" #'isled-refresh
  "TAB" #'isled-next
  "<tab>" #'isled-next
  "<backtab>" #'isled-previous
  "C-<tab>" #'isled-next-issue
  "C-S-<tab>" #'isled-previous-issue
  "C-<backtab>" #'isled-previous-issue
  "C-S-<iso-lefttab>" #'isled-previous-issue
  "C-<return>" #'isled-collapse-all
  "n" #'undefined
  "p" #'undefined
  "RET" #'isled-activate
  "M-." #'isled-jump-to-reference
  "M-," #'isled-history-back
  "C-M-," #'isled-history-forward
  "j" #'isled-jump-to-issue
  "!" #'isled-jump-to-warning
  "w" #'isled-work
  "?" #'isled-help
  "q" #'quit-window)

(defvar isled--setup-complete nil
  "Non-nil after the default project binding has been considered.")

;;;###autoload
(defun isled-setup ()
  "Install the default project shortcut without loading the browser.
Preserve existing bindings.  Repeated calls preserve later user overrides,
including removal of the default.  Customize `project-prefix-map' normally."
  (isled-file-routing-setup)
  (unless isled--setup-complete
    (unless (keymap-lookup project-prefix-map "i")
      (keymap-set project-prefix-map "i" #'isled-open-project))
    (setq isled--setup-complete t)))

;;;###autoload
(isled-setup)

(provide 'isled)
;;; isled.el ends here
