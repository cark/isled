;;; isled-context.el --- Selected location identity -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Assisted-by: Codex:GPT-6
;; Keywords: tools

;;; Commentary:
;; Keep browsing context separate from the canonical ledger session identity.

;;; Code:
(require 'seq)

(defvar isled--root)
(defvar-local isled-context-location nil
  "Canonical selected project or directory, independent of its ledger root.")
(defvar-local isled-context-local-ledger nil
  "Local ledger root present when this view's destination was chosen.")

(defun isled-context-canonical (directory)
  "Return the canonical existing local DIRECTORY, without a trailing slash."
  (when (file-remote-p directory) (user-error "Isled requires a local directory"))
  (unless (file-directory-p directory)
    (user-error "Directory does not exist: %s" directory))
  (directory-file-name (file-truename directory)))

(defun isled-context-current ()
  "Return this view's selected location, falling back to its ledger root."
  (or isled-context-location isled--root))

(defun isled-context-view (location &optional root except)
  "Find the most recent view for LOCATION and optional ROOT, excluding EXCEPT."
  (seq-find
   (lambda (buffer)
     (and (not (eq buffer except))
          (with-current-buffer buffer
            (and (derived-mode-p 'isled-mode)
                 (equal location (isled-context-current))
                 (or (not root) (equal root isled--root))))))
   (buffer-list)))

(provide 'isled-context)
;;; isled-context.el ends here
