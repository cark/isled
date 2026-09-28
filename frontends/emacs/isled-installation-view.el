;;; isled-installation-view.el --- Persistent installation paths -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Assisted-by: Codex:GPT-6
;; Keywords: tools

;;; Commentary:
;; Keep installation paths visible beside the ledger until explicitly dismissed.

;;; Code:
(require 'button)
(require 'dired)

(defun isled-installation-display (paths &optional program)
  "Display stable PATHS and optional Emacs PROGRAM until the user dismisses them.
Use a side window so opening the ledger cannot replace the installation notice."
  (let ((buffer (get-buffer-create "*Isled installation*"))
        (directory (file-name-as-directory (alist-get 'path_directory paths))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Isled %s\n\n" (or (alist-get 'version paths) "installation")))
        (insert "Press q in this window to dismiss it.\n"
                "Show it again with M-x isled-show-installation.\n\n")
        (insert-text-button "Open installation folder"
                            'follow-link t
                            'help-echo directory
                            'action (lambda (_button) (dired-other-window directory)))
        (insert "\n\n")
        (dolist (entry '(("Executable" . executable) ("Skill directory" . skill)
                         ("Skill instructions" . skill_file) ("Add to PATH" . path_directory)))
          (insert (format "%s:\n%s\n\n" (car entry) (alist-get (cdr entry) paths))))
        (insert "Use these current paths in your shell and agent setup.\n"
                "They follow the selected release when you upgrade or roll back.\n"
                "An existing agent conversation may need to reload the skill.\n\n")
        (when program (insert (format "Emacs uses this compatible executable:\n%s\n" program)))
        (goto-char (point-min))
        (special-mode)
        (setq default-directory directory)))
    (display-buffer buffer '((display-buffer-in-side-window)
                             (side . bottom) (window-height . 0.4)))))

(provide 'isled-installation-view)
;;; isled-installation-view.el ends here
