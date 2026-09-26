;;; isled-file-routing.el --- Deliberate issue file opens -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Keywords: tools

;;; Commentary:
;; Register lightweight display adapters.  Background file readers are untouched.
;; Rust validation and navigation load only for a deliberate local candidate open.

;;; Code:

(defcustom isled-file-routing t
  "Whether ordinary issue-file opens should reveal the issue in its ledger view.
Source-line and fragment destinations, modified buffers, remote files and
symlinked paths always retain normal file-opening behavior.  Changes take
effect immediately, including for pending validation."
  :type 'boolean
  :group 'isled)

(defvar isled-inhibit-file-routing nil
  "Non-nil while deliberately opening Markdown source without routing.")
(defvar isled-file-routing--serial 0
  "Generation of the latest deliberate file open.")

(autoload 'isled-file-visit "isled-file-visit")

(defun isled-file-routing--candidate (file)
  "Return (ROOT ID FILE) for a local regular issue FILE candidate.
Rust must still validate its complete record and canonical identity."
  (when (and (stringp file) (not (file-remote-p file)))
    (let* ((path (expand-file-name file))
           (directory (file-name-directory path))
           (name (file-name-nondirectory path)))
      (when (and (equal (file-name-nondirectory (directory-file-name directory)) ".issues")
                 (string-match "\\`\\([0-9]\\{4\\}\\)-.+\\.md\\'" name))
        (let ((id (match-string 1 name)))
          (when (and (file-regular-p path)
                     ;; Comparing the whole path excludes symlinked ancestors too.
                     (equal path (file-truename path)))
            (list (directory-file-name (file-name-directory (directory-file-name directory)))
                  id path)))))))

(defun isled-file-routing--location-p (path)
  "Return non-nil if PATH explicitly names a source line or fragment."
  (and (stringp path) (string-match-p "#\\|\\.md:[0-9]+\\(?:[:0-9]*\\)\\'" path)))

(defvar org-link-frame-setup)
(defvar agent-shell-file-display-action)
(declare-function xref-push-marker-stack "xref")

(defun isled-file-routing--display (command)
  "Return the buffer display function corresponding to file COMMAND."
  (pcase command
    ('find-file (lambda (buffer) (switch-to-buffer buffer) (selected-window)))
    ('find-file-other-window
     (lambda (buffer) (switch-to-buffer-other-window buffer) (selected-window)))
    ('find-file-other-frame
     (lambda (buffer) (switch-to-buffer-other-frame buffer) (selected-window)))))

(defun isled-file-routing--try (file display fallback)
  "Schedule FILE validation for DISPLAY and FALLBACK; return non-nil if handled."
  (when (and isled-file-routing (not isled-inhibit-file-routing)
             display (not (isled-file-routing--location-p file)))
    (condition-case failure
        (when-let ((candidate (isled-file-routing--candidate file)))
          (unless (when-let ((buffer (find-buffer-visiting file)))
                    (buffer-modified-p buffer))
            (isled-file-visit candidate isled-file-routing--serial display fallback)
            t))
      (error (message "Isled: opening Markdown (%s)" (error-message-string failure)) nil))))

(defun isled-file-routing--open (command function file &rest arguments)
  "Route a COMMAND open of FILE, or call FUNCTION with ARGUMENTS normally."
  (if isled-inhibit-file-routing
      (apply function file arguments)
    (let* ((file (if (stringp file) (expand-file-name file) file))
           (directory default-directory)
           (fallback (lambda ()
                       (let ((isled-inhibit-file-routing t)
                             (default-directory directory))
                         (apply function file arguments)))))
      (setq isled-file-routing--serial (1+ isled-file-routing--serial))
      (unless (isled-file-routing--try
               file (isled-file-routing--display command) fallback)
        (funcall fallback)))))

(defun isled-file-routing--markdown (function url &rest arguments)
  "Preserve explicit URL locations while calling FUNCTION with ARGUMENTS."
  (let ((isled-inhibit-file-routing
         (or isled-inhibit-file-routing
             (isled-file-routing--location-p url))))
    (apply function url arguments)))

(defun isled-file-routing--org (function path &optional in-emacs line search)
  "Respect Org application selection for PATH, IN-EMACS, LINE and SEARCH.
Intercept only a standard Emacs display selected by FUNCTION."
  (let* ((isled-inhibit-file-routing
          (or isled-inhibit-file-routing line search
              (isled-file-routing--location-p path)))
         (command (cdr (assq 'file org-link-frame-setup)))
         (display (isled-file-routing--display command))
         (directory default-directory))
    (if (or isled-inhibit-file-routing (not display))
        (funcall function path in-emacs line search)
      (setq isled-file-routing--serial (1+ isled-file-routing--serial))
      (catch 'isled-file-routing--handled
        (let ((org-link-frame-setup
               (cons
                (cons 'file
                      (lambda (file)
                        (if (isled-file-routing--try
                             file display
                             (lambda ()
                               (let ((default-directory directory)
                                     (isled-inhibit-file-routing t))
                                 (funcall function path in-emacs line search))))
                            (throw 'isled-file-routing--handled nil)
                          (let ((isled-inhibit-file-routing t)) (funcall command file)))))
                org-link-frame-setup)))
          (funcall function path in-emacs line search))))))

(defun isled-file-routing--agent-shell (function &rest arguments)
  "Route a plain agent-shell file link before FUNCTION opens its source.
ARGUMENTS with a source location retain the original file callback.  Ledger
views use agent-shell's file display action when available."
  (let ((file (plist-get arguments :file))
        (directory default-directory)
        (origin (point-marker))
        (action (and (boundp 'agent-shell-file-display-action) agent-shell-file-display-action)))
    (if (or isled-inhibit-file-routing
            (plist-get arguments :line-start) (plist-get arguments :line-end)
            (plist-get arguments :column) (isled-file-routing--location-p file))
        (let ((isled-inhibit-file-routing t)) (apply function arguments))
      (setq isled-file-routing--serial (1+ isled-file-routing--serial))
      (unless
          (isled-file-routing--try
           file
           (lambda (buffer)
             (when-let ((window (if (boundp 'agent-shell-file-display-action)
                                   (display-buffer buffer action)
                                 (switch-to-buffer buffer) (selected-window))))
               (select-window window)
               (xref-push-marker-stack origin)
               window))
           (lambda ()
             (let ((isled-inhibit-file-routing t) (default-directory directory))
               (apply function arguments))))
        (let ((isled-inhibit-file-routing t)) (apply function arguments))))))

(defun isled-file-routing--optional-adapters (&optional _file)
  "Register display adapters for optional packages that have been loaded."
  (when (featurep 'markdown-mode)
    (advice-add 'markdown--browse-url :around #'isled-file-routing--markdown))
  (when (featurep 'org)
    (advice-add 'org-open-file :around #'isled-file-routing--org))
  (when (featurep 'agent-shell-markdown)
    (advice-add 'agent-shell-markdown-visit-file :around #'isled-file-routing--agent-shell)))

(defun isled-file-routing-setup ()
  "Install idempotent adapters without loading any browser or link package."
  (dolist (command '(find-file find-file-other-window find-file-other-frame))
    (advice-add command :around (apply-partially #'isled-file-routing--open command)
                '((name . isled-file-routing--open))))
  (add-hook 'after-load-functions #'isled-file-routing--optional-adapters)
  (isled-file-routing--optional-adapters))

(provide 'isled-file-routing)
;;; isled-file-routing.el ends here
