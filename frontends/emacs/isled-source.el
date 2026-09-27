;;; isled-source.el --- Visit issue Markdown source -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Assisted-by: Codex:GPT-6
;; Keywords: tools

;;; Commentary:
;; Explicit source visits preserve ordinary file editing and bypass app routing.

;;; Code:
(require 'isled-view)
(require 'isled-sections)

(defvar isled--snapshot)
(defvar isled-inhibit-file-routing nil
  "Non-nil while explicitly visiting source instead of an issue app view.
Issue-file routing integrations must respect this dynamically bound bypass.")

;;;###autoload
(defun isled-open-source ()
  "Open the issue at point as Markdown source in the current window.
Reuse existing file buffers without reverting edits or moving their point.
New buffers start at the heading.  Missing files are never created."
  (interactive nil isled-mode)
  (let* ((id (isled-sections-id-at-point))
         (issue (and id (isled-view-find-issue
                        (isled-snapshot-issues isled--snapshot)
                        id))))
    (unless issue (user-error "No issue at point"))
    (let ((path (isled-issue-path issue))
          (isled-inhibit-file-routing t))
      (unless (file-regular-p path)
        (user-error "Issue source is unavailable: %s" path))
      (let* ((existing (find-buffer-visiting path))
             (buffer (or existing (find-file-noselect path))))
        (unless existing
          (with-current-buffer buffer (goto-char (point-min))))
        (switch-to-buffer buffer)))))

(provide 'isled-source)
;;; isled-source.el ends here
