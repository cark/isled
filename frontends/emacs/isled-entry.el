;;; isled-entry.el --- Choose a ledger location -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Assisted-by: Codex:GPT-6
;; Keywords: tools

;;; Commentary:
;; Resolve explicit project/directory context and ask before using or creating
;; another ledger.  View lifetime owns remembered choices, not a persistent map.

;;; Code:
(require 'project)
(require 'isled-context)
(require 'isled-buffers)
(require 'isled-initialize)

(defvar isled-entry-project-history nil "History of selected project roots.")

(defun isled-entry-default ()
  "Return the current view context or current directory for a chooser."
  (file-name-as-directory
   (or (and (derived-mode-p 'isled-mode) (isled-context-current))
       default-directory)))

(defun isled-entry-project-root ()
  "Return the current project's root, or nil outside a project."
  (when-let ((project (project-current nil))) (project-root project)))

;;;###autoload
(defun isled (&optional directory fresh)
  "Open the current context, or explicit DIRECTORY, without a location chooser.
Inside a view stay there; prefix FRESH duplicates it.  Else use the current
project root or current directory and ask before using a parent or creating."
  (interactive (list nil current-prefix-arg))
  (if (and (not directory) (derived-mode-p 'isled-mode))
      (if fresh (isled-duplicate-view) (current-buffer))
    (isled-entry-open (or directory (isled-entry-project-root) default-directory) fresh)))

;;;###autoload
(defun isled-open-project (&optional fresh)
  "Choose a project and open its ledger.
With prefix FRESH, create another independent view."
  (interactive "P")
  (let* ((default (if (derived-mode-p 'isled-mode) (isled-entry-default)
                    (or (isled-entry-project-root) default-directory)))
         (projects (delete-dups (cons (file-name-as-directory default)
                                     (project-known-project-roots))))
         (directory (completing-read "Open project ledger: " projects nil nil nil
                                     'isled-entry-project-history default)))
    (isled-entry-open directory fresh)))

;;;###autoload
(defun isled-open-directory (&optional fresh)
  "Choose any directory and open its ledger.
With prefix FRESH, create another independent view."
  (interactive "P")
  (let* ((default (isled-entry-default))
         (directory (read-directory-name "Open directory ledger: " default default t)))
    (isled-entry-open directory fresh)))

(defun isled-entry-ledger (location)
  "Return canonical ledger root at LOCATION, or nil if absent.
Reject an existing non-directory entry instead of looking elsewhere."
  (let ((path (expand-file-name ".issues" location)))
    (when (or (file-exists-p path) (file-symlink-p path))
      (unless (and (file-directory-p path) (file-readable-p path))
        (user-error "Ledger is not a readable directory: %s" path))
      (when (file-symlink-p path)
        (user-error "Symlinked .issues directories are not supported: %s" path))
      (isled-context-canonical location))))

(defun isled-entry--parent (location)
  "Find the nearest ledger above LOCATION, without scanning sibling projects."
  (let ((parent (file-name-directory (directory-file-name location))))
    (when (and parent (not (equal (directory-file-name parent) location)))
      (when-let ((found (locate-dominating-file parent ".issues")))
        (isled-entry-ledger found)))))

(defun isled-entry--choice (location local parent)
  "Ask where to open LOCATION, given LOCAL and PARENT ledger roots."
  (let* ((parent-label (and parent (format "Open parent ledger: %s/.issues" parent)))
         (local-label (if local (format "Open local ledger: %s/.issues" local)
                        (format "Create ledger here: %s/.issues" location)))
         (choices (append (and parent (list parent-label)) (list local-label "Cancel")))
         (choice (completing-read
                  (if local (format "A local ledger is now available in %s: " location)
                    (format "No ledger in %s: " location))
                  choices nil t nil nil (or parent-label local-label))))
    (cond ((equal choice "Cancel") (signal 'quit nil))
          ((equal choice parent-label) parent)
          ((equal choice local-label) (or local 'create))
          (t (user-error "No ledger destination selected")))))

(defun isled-entry-open (directory fresh)
  "Resolve DIRECTORY and open its view, honoring FRESH and explicit choices."
  (let* ((location (isled-context-canonical directory))
         (local (isled-entry-ledger location))
         (view (isled-context-view location))
         (remembered (and view (buffer-local-value 'isled--root view)))
         (valid (and remembered (equal remembered (isled-entry-ledger remembered))))
         (acknowledged (and view (buffer-local-value 'isled-context-local-ledger view)))
         (root (cond
                ((and valid (or (not local) (equal local remembered)
                                (equal local acknowledged))) remembered)
                ((and valid local (not (equal local remembered)))
                 (isled-entry--choice location local remembered))
                (local local)
                (t (isled-entry--choice location nil (isled-entry--parent location))))))
    (if (eq root 'create)
        (isled-initialize location
                          (lambda () (isled-buffers-open location
                                                        (isled-entry-ledger location)
                                                        fresh (isled-entry-ledger location))))
      (isled-buffers-open location root fresh local))))

(provide 'isled-entry)
;;; isled-entry.el ends here
