;;; isled-filter-inline.el --- Token-scoped filter completion -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Keywords: tools

;;; Commentary:
;; Completion at point for a plain query minibuffer.
;;; Code:
(require 'isled-filter-display)

(defcustom isled-filter-inline-auto t
  "Whether inline filter suggestions open automatically.
When nil, press TAB to open completion.  An open completion UI still updates
its choices and previews highlighted candidates.  This option affects only
our inline filter prompt, not other interfaces or global completion settings."
  :type 'boolean
  :group 'isled)

(defvar-local isled-filter-inline--requested nil
  "Exact input state awaiting choices after an explicit completion request.")
(defvar completion-reference-buffer)
(declare-function isled-filter--changed "isled-filter")
(declare-function corfu--auto-post-command "corfu")

(defvar-local isled-filter-inline--timer nil
  "Pending automatic completion display timer.")
(defvar-local isled-filter-inline--window nil
  "Stock completion window displayed by this prompt.")
(defvar-local isled-filter-inline--state nil
  "Last query modification tick and point scheduled for completion display.")

(defun isled-filter-inline--visible-p ()
  "Return non-nil when this prompt owns a displayed completion session."
  (pcase (isled-filter-display-owner t)
    ('corfu
     (and completion-in-region-mode
          (markerp (car completion-in-region--data))
          (eq (marker-buffer (car completion-in-region--data)) (current-buffer))))
    ('stock
     (let ((prompt (current-buffer)))
       (when-let ((window (get-buffer-window "*Completions*")))
         (eq (buffer-local-value 'completion-reference-buffer (window-buffer window))
             prompt))))))

(defun isled-filter-inline--wanted-p ()
  "Return whether automatic, visible or explicitly requested choices may show."
  (or isled-filter-inline-auto
      (isled-filter-inline--visible-p)
      (equal isled-filter-inline--requested
             (list (buffer-chars-modified-tick) (point)))))

(defun isled-filter-inline-complete ()
  "Complete the current filter token, waiting for pending contextual choices."
  (interactive)
  (when isled-filter-completion-context
    (isled-filter--changed))
  (if (and (isled-filter-display-owner t)
           isled-filter-completion-pending)
      (setq isled-filter-inline--requested
            (list (buffer-chars-modified-tick) (point)))
    (prog1 (completion-at-point)
      ;; TAB has just rendered the stock UI.  Do not let our post-command hook
      ;; schedule a redundant rebuild that would reset its selected candidate.
      (setq isled-filter-inline--state
            (list (buffer-chars-modified-tick) (point)))
      (isled-filter-inline--cancel-timer))))

(defun isled-filter-inline-at-point ()
  "Return token bounds and choices for completion in the query minibuffer."
  (when-let ((context
              (isled-filter-completion-token
               (minibuffer-contents-no-properties)
               (- (point) (minibuffer-prompt-end)))))
    (pcase-let* ((`(,start ,end ,_ ,whole) context)
                 (choices (isled-filter-completion-choices
                           whole isled-filter-completion-values))
                 (origin (minibuffer-prompt-end)))
      (list (+ origin start) (+ origin end)
            (lambda (string predicate action)
              (if (eq action 'metadata)
                  '(metadata (category . isled-filter))
                (complete-with-action action choices string predicate)))
            :exclusive 'no
            :exit-function #'isled-filter-completion-status-exit))))

(defun isled-filter-inline--cancel-timer ()
  "Cancel this prompt's pending display timer."
  (when (timerp isled-filter-inline--timer)
    (cancel-timer isled-filter-inline--timer))
  (setq isled-filter-inline--timer nil))

(defun isled-filter-inline-stop ()
  "Cancel pending display and dismiss this prompt's stock completion window."
  (isled-filter-inline--cancel-timer)
  (when (and (window-live-p isled-filter-inline--window)
             (eq (window-buffer isled-filter-inline--window)
                 (get-buffer "*Completions*")))
    (quit-window nil isled-filter-inline--window))
  (setq isled-filter-inline--window nil))

(defun isled-filter-inline--show (buffer state)
  "Show stock choices in BUFFER if its query and point still match STATE."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (equal state isled-filter-inline--state)
        (isled-filter-inline--cancel-timer))
      (when (and (isled-filter-inline--wanted-p)
                 (eq (isled-filter-display-owner t) 'stock)
                 (active-minibuffer-window)
                 (eq buffer (window-buffer (active-minibuffer-window)))
                 (equal state isled-filter-inline--state)
                 (equal state (list (buffer-chars-modified-tick) (point))))
        (pcase (isled-filter-inline-at-point)
          (`(,start ,end ,table . ,_)
           (if (completion-all-completions
                (buffer-substring-no-properties start end) table nil (- (point) start))
               (progn
                 ;; Help displays without expanding even a unique match.
                 (completion-help-at-point)
                 (setq isled-filter-inline--window
                       (get-buffer-window "*Completions*")))
             (isled-filter-inline-stop)))
          (_ (isled-filter-inline-stop)))))))

(defun isled-filter-inline-changed ()
  "Refresh stock suggestions after a filter input or cursor change.
The enabled Corfu minor mode owns automatic display."
  (let ((state (list (buffer-chars-modified-tick) (point)))
        (previous isled-filter-inline--state))
    (when (and (isled-filter-inline--wanted-p)
               (eq (isled-filter-display-owner t) 'stock)
               (not (equal previous state)))
      (setq isled-filter-inline--state state)
      (isled-filter-inline--cancel-timer)
      (if (and (equal (car previous) (car state))
               (window-live-p isled-filter-inline--window))
          ;; Refresh before Emacs discards the old token's completion window.
          (isled-filter-inline--show (current-buffer) state)
        (setq isled-filter-inline--timer
              (run-at-time 0.2 nil #'isled-filter-inline--show
                           (current-buffer) state))))))

(defun isled-filter-inline-refresh ()
  "Refresh delivered choices without inserting text into the filter prompt."
  (when (and (eq (current-buffer) (window-buffer (minibuffer-window)))
             (isled-filter-inline--wanted-p))
    ;; A refresh may temporarily close the old popup while choices are pending.
    ;; Retain permission only for this exact input, never for a later edit.
    (when isled-filter-completion-pending
      (setq isled-filter-inline--requested
            (list (buffer-chars-modified-tick) (point))))
    (setq isled-filter-inline--state
          (list (buffer-chars-modified-tick) (point)))
    (when (and (not (isled-filter-display-corfu))
               (eq (isled-filter-display-owner t) 'stock))
      (isled-filter-display-stock
       (lambda ()
         (if isled-filter-completion-pending
             (isled-filter-inline-stop)
           (isled-filter-inline--show
            (current-buffer) isled-filter-inline--state)))))
    (unless isled-filter-completion-pending
      (setq isled-filter-inline--requested nil))))

(defun isled-filter-inline-setup (choices)
  "Arrange inline suggestions using CHOICES in this minibuffer."
  (setq-local completion-no-auto-exit t
              isled-filter-inline--requested nil
              isled-filter-completion-values choices
              completion-at-point-functions
              (list #'isled-filter-inline-at-point))
  ;; Use an existing Corfu installation's own non-inserting auto display.
  ;; Global Corfu enables minibuffers late in their setup hook.  Prepare its
  ;; local auto-display settings before that enablement, without enabling it
  ;; ourselves or taking over another completion-in-region dispatcher.
  (when (and (or (eq (isled-filter-display-owner t) 'corfu)
                 (and (eq (isled-filter-display-owner t) 'stock)
                      (bound-and-true-p global-corfu-mode)
                      (bound-and-true-p global-corfu-minibuffer)))
             (boundp 'corfu-auto))
    (set (make-local-variable 'corfu-auto) isled-filter-inline-auto)
    (unless isled-filter-inline-auto
      (remove-hook 'post-command-hook #'corfu--auto-post-command t))
    (set (make-local-variable 'corfu-auto-prefix) 0)
    (when (boundp 'corfu-auto-commands)
      (set (make-local-variable 'corfu-auto-commands)
           (append (symbol-value 'corfu-auto-commands)
                   '(forward-char backward-char right-char left-char
                                  forward-word backward-word move-beginning-of-line
                                  move-end-of-line beginning-of-buffer end-of-buffer
                                  mouse-set-point)))))
  (add-hook 'isled-filter-completion-update-hook
            #'isled-filter-inline-refresh nil t)
  (add-hook 'post-command-hook #'isled-filter-inline-changed nil t)
  (add-hook 'minibuffer-exit-hook #'isled-filter-inline-stop nil t)
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map (current-local-map))
    ;; Completion in region owns only the token, including text after point.
    (define-key map (kbd "TAB") #'isled-filter-inline-complete)
    (define-key map (kbd "<tab>") #'isled-filter-inline-complete)
    (when (eq (isled-filter-display-owner t) 'stock)
      (define-key map (kbd "M-v") #'switch-to-completions))
    (use-local-map map)))

(provide 'isled-filter-inline)
;;; isled-filter-inline.el ends here
