;;; isled-filter.el --- Live filter interaction -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Assisted-by: Codex:GPT-6
;; Keywords: tools

;;; Commentary:
;; Edit one full query, preview through the existing loading queue, and restore
;; the original view on cancellation.  Completion does not require a specific UI.
;;; Code:
(require 'isled-filter-query)
(require 'isled-filter-inline)
(require 'isled-filter-picker)
(require 'isled-filter-minibuffer)
(require 'isled-navigation)

(defvaralias 'isled-search-interface 'isled-filter-interface
  "Compatibility name for `isled-filter-interface'.")

(defcustom isled-filter-interface 'inline-suggestions
  "How structured filters are completed in the filter prompt.
Inline suggestions complete the token at point, using Corfu when enabled.
Separate filter picker opens a single-token completion prompt with TAB.
Minibuffer suggestions use the ordinary `completing-read' interface, including
Vertico when enabled.  All interfaces also work with standard Emacs completion."
  :type '(choice (const :tag "Inline suggestions" inline-suggestions)
                 (const :tag "Separate filter picker" separate-filter-picker)
                 (const :tag "Minibuffer suggestions" minibuffer-suggestions))
  :group 'isled)

(defvar isled--filter)
(defvar isled-loading-generation)
(defvar isled-loading-pending)
(defvar isled-loading-intent)
(declare-function isled-loading-request "isled-loading")
(declare-function isled--capture-view-state "isled-browser")
(declare-function isled--state-for-filter "isled-browser" (query &optional flat))
(declare-function isled--window-anchors "isled-browser")
(declare-function isled--restore-window-anchors "isled-browser")

(defvar-local isled-filter-choices '("s:open" "s:closed")
  "Completion choices from the last successful view response.")
(defvar-local isled-filter-active nil "Non-nil while this view owns a filter prompt.")
(defvar-local isled-filter-feedback nil "Current filter input validation hint.")
(defvar-local isled-filter--origin nil "Window owning this filter minibuffer.")
(defvar-local isled-filter--last nil "Last previewed minibuffer text.")
(defvar-local isled-filter--criteria nil
  "Parsed criteria for the current prompt's last previewed text.")
(defvar isled-filter--accepted-query nil
  "Text and parsed criteria accepted by the current prompt invocation.")
(defvar isled-filter-history nil "Previously accepted filter strings.")

(defvar-local isled-filter-help
    "t: tag · k: kind · s: status · w: work · r: reason · o: order · n: limit · \"…\" phrase · AND · TAB complete · RET keep"
  "Short filter syntax and interaction reminder.")

(defun isled-filter--request (query &optional criteria completion flat)
  "Preview QUERY with CRITERIA and COMPLETION.  Use FLAT for flat presentation."
  (let ((criteria (or criteria (isled-filter-query-criteria query))))
    (isled-navigation-with-window
     (isled-loading-request
      'view (isled--state-for-filter
             query (or flat
                       (and (alist-get 'oldest_first criteria)
                            (not (alist-get 'oldest_first
                                            (isled-filter-query-criteria isled--filter))))))
      nil criteria completion))
    criteria))

(defvar-local isled-filter--position nil "Last completion cursor offset.")
(defvar-local isled-filter--view nil "View buffer owning this prompt.")

(defun isled-filter--choices-received (prompt context window view session choices &optional failure)
  "Deliver CHOICES or FAILURE to current PROMPT CONTEXT in WINDOW/VIEW SESSION."
  (when (and (buffer-live-p prompt) (buffer-live-p view)
             (window-live-p window) (eq (window-buffer window) view)
             (eq session (buffer-local-value 'isled-filter-active view)))
    (with-current-buffer prompt
      (when (and (eq context isled-filter-completion-context)
                 (equal (isled-filter-context-text context)
                        (minibuffer-contents-no-properties))
                 (= (isled-filter-context-point context)
                    (- (point) (minibuffer-prompt-end))))
        (when failure
          (with-current-buffer view
            (setq isled-filter-feedback (error-message-string failure))))
        (setq isled-filter-completion-values choices
              isled-filter-completion-pending nil)
        (if (active-minibuffer-window)
            (with-selected-window (minibuffer-window)
              (with-current-buffer prompt
                (run-hooks 'isled-filter-completion-update-hook)))
          (run-hooks 'isled-filter-completion-update-hook))))))

(defun isled-filter--changed ()
  "Preview text edits and request choices for the exact token at point."
  (let* ((query (minibuffer-contents-no-properties))
         (position (- (point) (minibuffer-prompt-end)))
         (text-changed (not (equal query isled-filter--last)))
         (window isled-filter--origin)
         (view isled-filter--view)
         (prompt (current-buffer)) context feedback criteria)
    (unless (and (not text-changed) (eql position isled-filter--position))
      (condition-case failure
          (setq context (isled-filter-completion-context query position))
        (user-error (setq feedback (error-message-string failure))))
      (when text-changed
        (condition-case failure
            (setq criteria (isled-filter-query-criteria query))
          (user-error (setq feedback (error-message-string failure)))))
      (setq isled-filter--last query isled-filter--position position
            isled-filter-completion-context context
            isled-filter-completion-values nil
            isled-filter-completion-pending (and context t))
      (when text-changed (setq isled-filter--criteria criteria))
      (run-hooks 'isled-filter-completion-update-hook)
      (when (and (window-live-p window) (buffer-live-p view)
                 (eq (window-buffer window) view))
        (with-selected-window window
          (when isled-filter-active
            (let ((completion
                   (when context
                     (list (isled-filter-context-criteria context)
                           (apply-partially #'isled-filter--choices-received
                                            prompt context window view
                                            isled-filter-active)))))
              (setq isled-filter-feedback feedback)
              (when (and text-changed (not criteria))
                ;; Fence the old candidate before scheduling any restoration.
                (setq isled-loading-generation (list t)
                      isled-loading-pending nil
                      isled-loading-intent isled--filter))
              (with-current-buffer prompt
                (when isled-filter-preview--query
                  (if (and text-changed criteria)
                      (setq isled-filter-preview--query nil
                            isled-filter-preview--baseline nil)
                    (isled-filter-preview--apply nil))))
              (cond
               ((and text-changed criteria)
                (isled-filter--request query criteria completion))
               (t
                (when completion
                  (isled-loading-request 'choices nil nil nil completion))))
              (force-mode-line-update))))))))

(defun isled-filter--accept ()
  "Accept the full minibuffer query, without substituting a selected token."
  (interactive)
  (let* ((query (minibuffer-contents-no-properties))
         (criteria (or (and (equal query isled-filter--last)
                            isled-filter--criteria)
                       (isled-filter-query-criteria query))))
    (setq isled-filter--accepted-query (cons query criteria))
    (exit-minibuffer)))

(defun isled-filter--setup (window choices interface)
  "Arrange the prompt owned by WINDOW with CHOICES using INTERFACE."
  (setq-local isled-filter--origin window
              isled-filter--view (window-buffer window)
              isled-filter--position nil
              isled-filter--last nil
              isled-filter--criteria nil)
  (pcase interface
    ('inline-suggestions (isled-filter-inline-setup choices))
    ('separate-filter-picker (isled-filter-picker-setup choices))
    ('minibuffer-suggestions (isled-filter-minibuffer-setup choices)))
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map (current-local-map))
    (define-key map (kbd "RET") #'isled-filter--accept)
    (define-key map (kbd "SPC") #'self-insert-command)
    (use-local-map map))
  (add-hook 'post-command-hook #'isled-filter--changed -50 t)
  (when (minibufferp)
    (isled-filter--changed)
    (isled-filter-preview-setup interface)))

(defun isled-filter--read (initial choices interface)
  "Read a full query from INITIAL and CHOICES using INTERFACE."
  (if (eq interface 'minibuffer-suggestions)
      (isled-filter-minibuffer-read initial choices)
    (read-from-minibuffer "Filter issues: " initial nil nil
                          'isled-filter-history)))

(defun isled-filter--finish (query window buffer)
  "Submit accepted QUERY to its still-displayed WINDOW and BUFFER, returning t."
  (unless (and (window-live-p window) (eq (window-buffer window) buffer))
    (user-error "The filter view is no longer displayed"))
  ;; Some completing-read replacements return their selected candidate even
  ;; after our RET command has explicitly accepted the editable whole query.
  (setq query (or (car isled-filter--accepted-query) query))
  (with-selected-window window
    (isled-filter--request
     query (and (equal query (car isled-filter--accepted-query))
                (cdr isled-filter--accepted-query))))
  t)

(defun isled-filter--cleanup (buffer window state anchors accepted)
  "End BUFFER's prompt, restoring STATE and ANCHORS in WINDOW unless ACCEPTED."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq isled-filter-active nil isled-filter-feedback nil)
      (unless accepted
        (setq isled-loading-generation (list t)
              isled-loading-pending nil
              isled-loading-intent isled--filter)
        (when (and (window-live-p window) (eq (window-buffer window) buffer))
          (with-selected-window window
            (isled-loading-request
             'view state (lambda () (isled--restore-window-anchors anchors))))))
      (force-mode-line-update))))

(defun isled-filter ()
  "Edit and preview the full filter; restore its position on cancellation."
  (interactive nil isled-mode)
  (when isled-filter-active (user-error "This view already has a filter prompt"))
  (unless (memq isled-filter-interface
                '(inline-suggestions separate-filter-picker minibuffer-suggestions))
    (user-error "Unknown filter interface: %s" isled-filter-interface))
  (let* ((interface (if (and (eq isled-filter-interface 'minibuffer-suggestions)
                             (not (isled-filter-display-owner)))
                        'separate-filter-picker
                      isled-filter-interface))
         (window (selected-window)) (buffer (current-buffer))
         (state (isled-navigation-call #'isled--capture-view-state))
         (anchors (isled--window-anchors))
         (initial (isled-filter-query-initial isled--filter))
         (choices nil)
         (isled-filter--accepted-query nil)
         accepted)
    (setq isled-filter-active (list t) isled-filter-feedback nil
          isled-filter-help
          (concat "t: tag · k: kind · s: status · w: work · r: reason · o: order · n: limit · \"…\" phrase · AND · "
                  (if (eq interface 'separate-filter-picker)
                      "TAB pick token" "TAB complete")
                  " · RET keep"))
    (force-mode-line-update)
    (unwind-protect
        (minibuffer-with-setup-hook
            (apply-partially #'isled-filter--setup window choices interface)
          (setq accepted
                (isled-filter--finish
                 (isled-filter--read initial choices interface) window buffer)))
      (isled-filter--cleanup buffer window state anchors accepted))))

(defalias 'isled-search #'isled-filter
  "Compatibility name for `isled-filter'.")

(provide 'isled-filter)
;;; isled-filter.el ends here
