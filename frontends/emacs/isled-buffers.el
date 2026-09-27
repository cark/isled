;;; isled-buffers.el --- Independent ledger views -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Assisted-by: Codex:GPT-6
;; Keywords: tools

;;; Commentary:
;; Create, duplicate and reuse view buffers without duplicating ledger resources.

;;; Code:
(require 'isled-loading)
(require 'isled-navigation)
(require 'isled-context)

(defvar isled--root)
(defvar isled--snapshot)
(defvar isled--filter)
(defvar isled-filter-choices)
(defvar isled--saved-view-states)
(defvar isled--last-collapse-by-filter)
(defvar isled--back-history)
(defvar isled--forward-history)
(defvar-local isled-buffers-fresh nil "Non-nil when root reuse is unwanted.")
(declare-function isled-mode "isled-browser")
(declare-function isled--view-state-create "isled-browser")
(declare-function isled--buffer-for-root "isled-browser")
(declare-function isled--buffer-name "isled-browser")
(declare-function isled--capture-view-state "isled-browser")
(declare-function isled--restore-loaded-view-state "isled-browser")
(declare-function isled--configure-auto-refresh "isled-auto-refresh")

(defun isled-buffers-open (location root fresh local)
  "Open ROOT for LOCATION, honoring FRESH and the acknowledged LOCAL ledger."
  (require 'isled-browser)
  (unless root (user-error "No ledger at the selected location"))
  (let ((existing (isled-context-view location root)))
    (cond
     ((and existing (not fresh))
      (with-current-buffer existing (setq isled-context-local-ledger local))
      (pop-to-buffer existing) existing)
     ((and existing (buffer-local-value 'isled-data-view existing))
      (with-current-buffer existing
        (setq isled-context-local-ledger local)
        (isled-buffers--copy)))
     (t
      (let ((buffer (generate-new-buffer "*isled: loading*")))
        (with-current-buffer buffer
          (isled-mode)
          (setq isled--root root isled-context-location location
                isled-context-local-ledger local
                default-directory (file-name-as-directory root)
                isled-buffers-fresh fresh
                isled-loading-initializer #'isled--opened)
          (let ((inhibit-read-only t)) (insert "Loading project issues…\n")))
        (pop-to-buffer buffer)
        (isled-loading-request 'refresh)
        (if (buffer-live-p buffer) buffer (current-buffer)))))))

(defun isled-buffers-display-root (root display)
  "Show ROOT's recent view using DISPLAY, returning its window or nil.
Create and start loading a view only if DISPLAY actually shows it."
  (require 'isled-browser)
  (let* ((existing (isled--buffer-for-root root))
         (buffer (or existing (generate-new-buffer "*isled: loading*")))
         window)
    (unwind-protect
        (progn
          (unless existing
            (with-current-buffer buffer
              (isled-mode)
              (setq isled--root root isled-context-location root
                    default-directory (file-name-as-directory root)
                    isled-loading-initializer #'isled--opened)
              (let ((inhibit-read-only t)) (insert "Loading project issues…\n"))))
          (setq window (funcall display buffer))
          (when window
            (unless (and (window-live-p window) (eq (window-buffer window) buffer))
              (error "Issue display did not return its window"))
            (select-window window)
            (set-buffer buffer)
            (unless existing (isled-loading-request 'refresh)))
          window)
      (unless (or existing (and (window-live-p window) (eq (window-buffer window) buffer)))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

;;;###autoload
(defun isled-duplicate-view ()
  "Copy this view into an independent buffer and select it."
  (interactive nil isled-mode)
  (require 'isled-browser)
  (unless isled-data-view (user-error "Wait for the initial view to load"))
  (isled-buffers--copy))

(defun isled-buffers--display (buffer)
  "Select BUFFER in a sensible split or the invoking window."
  (let ((window (isled-buffers--split)))
    (select-window (or window (selected-window)))
    (let ((dedicated (window-dedicated-p)))
      (unwind-protect
          (progn (set-window-dedicated-p (selected-window) nil)
                 (switch-to-buffer buffer))
        (set-window-dedicated-p (selected-window) dedicated)))))

(defun isled-buffers--split ()
  "Split the invoking window, relaxing automatic display thresholds if needed."
  (or (condition-case nil
          (when (functionp split-window-preferred-function)
            (funcall split-window-preferred-function (selected-window)))
        (error nil))
      (let ((split-height-threshold 0)
            (split-width-threshold 0))
        (condition-case nil
            (split-window-sensibly (selected-window))
          (error nil)))))

(defun isled-buffers--copy ()
  "Create an independent view sharing this ledger and copying browsing state."
  (isled-navigation-with-window
    (let* ((source (current-buffer))
           (root isled--root)
           (state (isled--capture-view-state))
           (filter isled--filter)
           (location (isled-context-current))
           (local isled-context-local-ledger)
           (buffer (generate-new-buffer (isled--buffer-name location))))
      (with-current-buffer buffer
        (isled-mode)
        (setq isled--root root isled-context-location location
              isled-context-local-ledger local
              default-directory (file-name-as-directory root)
              isled--filter filter isled-loading-active t
              isled-loading-filter (buffer-local-value 'isled-loading-filter source)
              isled-filter-choices (buffer-local-value 'isled-filter-choices source)
              isled-loading-intent filter
              isled-data-view (copy-isled-snapshot
                                       (buffer-local-value 'isled-data-view source))
              isled-data-hash (buffer-local-value 'isled-data-hash source))
        (dolist (variable '(isled-graph-layout isled-graph-hash isled-graph-layout-direction
                             isled-loading-graph isled-loading-graph-intent))
          (set variable (buffer-local-value variable source)))
        (isled-session-attach)
        (setq isled--snapshot
              (isled-data-accept
               (isled-response-create :root root :view isled-data-view
                                              :view-hash isled-data-hash)))
        (dolist (variable '(isled--saved-view-states isled--last-collapse-by-filter
                              isled--back-history isled--forward-history))
          (set variable (copy-tree (buffer-local-value variable source)))))
      (isled-buffers--display buffer)
      (setq isled-loading-presented t)
      (if (equal filter isled-loading-filter)
          (progn
            (let ((isled-sections--defer-rich t))
              (isled--restore-loaded-view-state
               (or state (isled--view-state-create :filter filter))))
            (isled-loading-schedule))
        (isled-loading-request 'view))
      buffer)))

(defun isled--opened ()
  "Finish canonical ownership after asynchronous discovery."
  (let ((existing (and (not isled-buffers-fresh)
                       (isled-context-view (isled-context-current) isled--root (current-buffer)))))
    (if existing
        (let ((redundant (current-buffer)))
          (pop-to-buffer existing)
          (kill-buffer redundant))
      (rename-buffer (isled--buffer-name (isled-context-current)) t)
      (when (isled--configure-auto-refresh)
        (isled-loading-request 'refresh)))))

(provide 'isled-buffers)
;;; isled-buffers.el ends here
