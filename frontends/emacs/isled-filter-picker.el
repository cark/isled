;;; isled-filter-picker.el --- Token-scoped filter completion -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Assisted-by: Codex:GPT-6
;; Keywords: tools

;;; Commentary:
;; A recursive single-token picker using the ordinary completing-read UI.
;;; Code:
(require 'isled-filter-preview)

(defvar-local isled-filter-picker--buffer nil
  "Recursive picker currently consuming this outer prompt's choices.")

(defvar-local isled-filter-picker--loading nil
  "Nonselectable loading indication in the recursive picker.")

(defun isled-filter-picker-stop ()
  "Remove the recursive picker's loading indication on exit."
  (when (overlayp isled-filter-picker--loading)
    (delete-overlay isled-filter-picker--loading))
  (setq isled-filter-picker--loading nil))

(declare-function isled-filter--changed "isled-filter")

(defun isled-filter-picker-refresh ()
  "Refresh a live recursive picker from this outer prompt's current choices."
  (let ((picker isled-filter-picker--buffer)
        (pending isled-filter-completion-pending))
    (when (and (buffer-live-p picker)
               (eq picker (window-buffer (minibuffer-window))))
      (with-current-buffer picker
        (isled-filter-picker-stop)
        (when pending
          (setq isled-filter-picker--loading
                (make-overlay (point-max) (point-max) nil nil t))
          (overlay-put isled-filter-picker--loading 'after-string
                       (propertize " [Loading choices…]" 'face 'shadow)))
        (when (and (not (isled-filter-display-vertico))
                   (eq (isled-filter-display-owner) 'stock))
          (isled-filter-display-stock #'minibuffer-completion-help))))))

(defun isled-filter-picker-context (text position)
  "Return the structured token bounds and prefix for TEXT at POSITION.
Reject quoted literals and ordinary text instead of replacing them."
  (let ((context (isled-filter-completion-token text position)))
    (unless (and context
                 (let ((whole (nth 3 context)))
                   (or (string-empty-p whole)
                       (string-match-p "\\`[tksw]\\(?::.*\\)?\\'" whole))))
      (user-error "Move to a structured token or between terms to pick a filter"))
    ;; The picker starts from text before point; inline completion instead
    ;; receives the whole token and a separate cursor offset from Emacs.
    (list (car context) (cadr context) (nth 2 context))))

(defun isled-filter-picker-pick ()
  "Immediately pick a token from current or asynchronously arriving choices.
Cancelling this recursive prompt leaves the outer query and point unchanged."
  (interactive)
  (when isled-filter-completion-context
    (isled-filter--changed))
  (pcase-let* ((`(,start ,end ,initial)
                (isled-filter-picker-context
                 (minibuffer-contents-no-properties)
                 (- (point) (minibuffer-prompt-end))))
               (origin (current-buffer))
               (query (minibuffer-contents-no-properties))
               (position (point))
               (context isled-filter-completion-context)
               (offset (minibuffer-prompt-end))
               (enable-recursive-minibuffers t)
               (table (lambda (string predicate action)
                        (with-current-buffer origin
                          (complete-with-action
                           action (isled-filter-completion-choices
                                   initial isled-filter-completion-values)
                           string predicate)))))
    (unwind-protect
        (condition-case nil
            (let ((choice
                   (minibuffer-with-setup-hook
                       (lambda ()
                         (setq-local isled-filter-preview--picker-origin origin)
                         (add-hook 'minibuffer-exit-hook
                                   #'isled-filter-picker-stop nil t)
                         (let ((picker (current-buffer)))
                           (with-current-buffer origin
                             (setq isled-filter-picker--buffer picker)
                             (isled-filter-picker-refresh))))
                     (completing-read "Filter token (RET insert, C-g back): "
                                      table nil t initial))))
              (with-current-buffer origin
                (when (and (eq context isled-filter-completion-context)
                           (equal query (minibuffer-contents-no-properties))
                           (= position (point))
                           (member choice isled-filter-completion-values))
                  (goto-char (+ offset start))
                  (delete-region (point) (+ offset end))
                  (insert choice)
                  (isled-filter-completion-status-exit choice 'finished))))
          (quit nil))
      (when (buffer-live-p origin)
        (with-current-buffer origin
          (setq isled-filter-picker--buffer nil)
          (isled-filter-preview--apply nil))))))

(defun isled-filter-picker-setup (choices)
  "Arrange a separate token picker using CHOICES in this minibuffer."
  (setq-local isled-filter-completion-values choices)
  (add-hook 'isled-filter-completion-update-hook
            #'isled-filter-picker-refresh nil t)
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map (current-local-map))
    (define-key map (kbd "TAB") #'isled-filter-picker-pick)
    (define-key map (kbd "<tab>") #'isled-filter-picker-pick)
    (use-local-map map)))

(provide 'isled-filter-picker)
;;; isled-filter-picker.el ends here
