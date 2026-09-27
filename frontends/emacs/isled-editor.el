;;; isled-editor.el --- Add, edit and close complete issue drafts -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Assisted-by: Codex:GPT-6
;; Keywords: tools

;;; Commentary:
;; Shared draft lifecycle and asynchronous Rust validation/save coordination.

;;; Code:
(require 'isled-editor-completion)
(require 'isled-editor-feedback)
(require 'isled-browser)
(require 'diff)

(defcustom isled-editor-validation-delay 0.6
  "Idle seconds before asking Rust to validate the draft."
  :type 'number :group 'isled)

(defvar-keymap isled-editor-mode-map
  :parent widget-keymap
  "C-x C-s" #'isled-editor-save
  "C-c C-c" #'isled-editor-finish
  "C-c C-k" #'isled-editor-cancel
  "C-<tab>" #'isled-editor-next-field
  "C-S-<tab>" #'isled-editor-previous-field
  "C-S-<iso-lefttab>" #'isled-editor-previous-field
  "C-<iso-lefttab>" #'isled-editor-previous-field
  "C-<backtab>" #'isled-editor-previous-field
  "TAB" #'isled-editor-complete
  "<tab>" #'isled-editor-complete
  "C-c ?" #'isled-editor-help)
(setq isled-editor-field-map (make-composed-keymap isled-editor-mode-map widget-field-keymap))

(define-derived-mode isled-editor-mode text-mode "Isled Edit"
  "Edit a complete issue draft through Rust semantic operations."
  (setq-local inhibit-field-text-motion t)
  (setq-local widget-button-click-moves-point t)
  (setq-local header-line-format '(:eval (isled-editor-header)))
  (setq-local completion-category-defaults
              (cons '(isled-issue (styles substring basic))
                    completion-category-defaults))
  (setq-local completion-at-point-functions '(isled-editor-completion-at-point))
  (setq-local revert-buffer-function (lambda (&rest _) (isled-editor-revert)))
  (setq-local write-contents-functions (list (lambda () (isled-editor-save) t)))
  (add-hook 'post-command-hook #'isled-editor-form-highlight nil t)
  (add-hook 'post-command-hook #'isled-editor-form-statement-height nil t)
  (add-hook 'kill-buffer-query-functions #'isled-editor-confirm-discard nil t)
  (add-hook 'kill-buffer-hook #'isled-editor-cleanup nil t))

(defun isled-editor-next-field ()
  "Move to the next editable field or action."
  (interactive) (widget-forward 1))
(defun isled-editor-previous-field ()
  "Move to the previous editable field or action."
  (interactive) (widget-backward 1))
(defun isled-editor-complete ()
  "Complete at point, indent body text, or explain single-line field input."
  (interactive)
  (unless (completion-at-point)
    (if-let ((widget (widget-field-find (point))))
        (if (eq (widget-type widget) 'text)
            (let ((indent-tabs-mode nil)) (indent-for-tab-command))
          (message "No completion here; type a value.  C-TAB moves to the next field"))
      (message "Move into a field to edit; C-TAB moves to the next field"))))

(transient-define-prefix isled-editor-help ()
  "Show issue draft actions below the selected editor window."
  :transient-suffix t
  :transient-non-suffix #'isled--help-motion
  :display-action '(isled--help-display)
  [["Save / leave"
    ("C-x C-s" "Save and stay" isled-editor-save :transient nil)
    ("C-c C-c" "Save and return" isled-editor-finish :transient nil)
    ("C-c C-k" "Cancel draft" isled-editor-cancel :transient nil)]
   ["Draft"
    ("TAB" "Complete / indent body" isled-editor-complete :transient nil)
    ("C-<tab>" "Next field / action" isled-editor-next-field)
    ("C-S-<tab>" "Previous field / action" isled-editor-previous-field)
    ("g" "Revert draft" isled-editor-revert :transient nil)]
   ["Conflict / help"
    ("n" "Next error" isled-editor-next-error :transient nil)
    ("d" "Compare saved version" isled-editor-compare :transient nil)
    ("o" "Confirm overwrite" isled-editor-overwrite :transient nil)
    ("q" "Dismiss help" transient-quit-one)]]
  [:hide (lambda () t)
         ("C-<backtab>" "Previous field" isled-editor-previous-field)
         ("C-<iso-lefttab>" "Previous field" isled-editor-previous-field)
         ("C-S-<iso-lefttab>" "Previous field" isled-editor-previous-field)
         ("<up>" "Previous line" previous-line)
         ("<down>" "Next line" next-line)
         ("<left>" "Backward character" left-char)
         ("<right>" "Forward character" right-char)
         ("C-n" "Next line" next-line)
         ("C-p" "Previous line" previous-line)
         ("C-v" "Page down" scroll-up-command)
         ("M-v" "Page up" scroll-down-command)]
  (interactive nil isled-editor-mode)
  (transient-setup 'isled-editor-help))

(defun isled-editor-find (root id)
  "Find an existing draft for ID in ROOT."
  (seq-find (lambda (buffer)
              (with-current-buffer buffer
                (and (derived-mode-p 'isled-editor-mode) isled-editor-record
                     (equal isled-editor-root root)
                     (equal (isled-editor-record-id isled-editor-record) id))))
            (buffer-list)))

;;;###autoload
(defun isled-edit-issue ()
  "Edit the issue at point in a shared draft buffer."
  (interactive nil isled-mode)
  (let ((id (isled-sections-id-at-point)))
    (unless id (user-error "No issue at point"))
    (isled-editor-open isled--root id)))

;;;###autoload
(defun isled-add-issue ()
  "Create an independent issue draft in the current ledger."
  (interactive nil isled-mode)
  (unless isled--root (user-error "Open a ledger first"))
  (isled-editor-open isled--root nil))

;;;###autoload
(defun isled-close-issue ()
  "Prepare closure of the issue at point, preserving any existing draft."
  (interactive nil isled-mode)
  (let ((id (isled-sections-id-at-point)))
    (unless id (user-error "No issue at point"))
    (let ((buffer (isled-editor-open isled--root id)))
      (with-current-buffer buffer
        (when (equal (isled-editor-record-status isled-editor-record) "closed")
          (user-error "Issue is already closed"))
        (setq isled-editor-closing t)
        (unless isled-editor-busy (cl-incf isled-editor-generation))
        (isled-editor-form-closing-status)
        (goto-char (widget-field-start (cdr (assoc "outcome" isled-editor-fields))))
        (force-mode-line-update)))))

(defun isled-editor-open (root id)
  "Display a new or existing draft for ID in canonical ROOT."
  (let* ((existing (and id (isled-editor-find root id)))
         (origin (current-buffer))
         (windows (window-list))
         (buffer (or existing (generate-new-buffer (if id (format "*isled edit %s*" id) "*isled new issue*"))))
         (window (display-buffer buffer '(display-buffer-pop-up-window))))
    (unless existing
      (with-current-buffer buffer
        (isled-editor-mode)
        (setq isled-editor-root root isled-editor-origin origin
              default-directory (file-name-as-directory root)
              isled-editor-window (unless (memq window windows) window))
        (isled-editor-form-render (isled-editor-empty-draft))
        (set-buffer-modified-p nil)
        (isled-editor-completion-refresh)
        (setq isled-editor-session (isled-session-subscribe root #'isled-editor-disk-check))
        (when id
          (setq isled-editor-record (isled-editor-record-create :id id :status "loading"))
          (isled-editor-load id))))
    (when (window-live-p window)
      (select-window window)
      (unless (or existing id)
        (goto-char (widget-field-start (cdr (assoc "title" isled-editor-fields))))))
    buffer))

(defun isled-editor-load (id)
  "Load saved ID into the current draft without overwriting later typing."
  (when isled-editor-busy (user-error "An editor operation is pending"))
  (let ((buffer (current-buffer)) (generation isled-editor-generation))
    (setq isled-editor-busy t)
    (let ((inhibit-read-only t)) (setq buffer-read-only t))
    (isled-editor-request
     isled-editor-root "load" (isled-editor-record-create :id id) nil
     (lambda (response)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (setq isled-editor-busy nil buffer-read-only nil)
           (if (eq (alist-get 'ok response) t)
               (when (= generation isled-editor-generation)
                 (setq isled-editor-record
                       (alist-get 'record response)
                       isled-editor-conflict nil isled-editor-uncertain nil
                       isled-editor-disk-error nil isled-editor-save-failed nil)
                 (when (equal (isled-editor-record-status isled-editor-record) "closed")
                   (setq isled-editor-closing nil))
                 (isled-editor-form-render (isled-editor-record-draft isled-editor-record))
                 (when isled-editor-closing
                   (goto-char (widget-field-start (cdr (assoc "outcome" isled-editor-fields)))))
                 (set-buffer-modified-p nil))
             (isled-editor-form-errors (alist-get 'errors response)))))))))

(defun isled-editor-changed (&rest _ignored)
  "Mark a draft change and schedule background validation."
  (cl-incf isled-editor-generation)
  (set-buffer-modified-p t)
  (when (timerp isled-editor-timer) (cancel-timer isled-editor-timer))
  (setq isled-editor-timer
        (run-with-idle-timer isled-editor-validation-delay nil
                            #'isled-editor-validate-buffer (current-buffer))))

(defun isled-editor-validate-buffer (buffer)
  "Validate BUFFER without publishing or interrupting its author."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (unless (or isled-editor-busy isled-editor-validating isled-editor-uncertain)
        (let ((generation isled-editor-generation))
          (setq isled-editor-validating t)
          (isled-editor-request
           isled-editor-root "validate" isled-editor-record (isled-editor-form-submission)
           (lambda (response)
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (setq isled-editor-validating nil)
                 (if (or (/= generation isled-editor-generation) isled-editor-busy)
                     (setq isled-editor-timer
                           (run-with-idle-timer isled-editor-validation-delay nil
                                               #'isled-editor-validate-buffer buffer))
                   (isled-editor-form-errors (alist-get 'errors response))))))
           isled-editor-closing))))))

(defun isled-editor-source-conflict-p ()
  "Return a modified source buffer competing with this draft, if any."
  (when-let* ((record isled-editor-record)
              (path (isled-editor-record-path record))
              (buffer (find-buffer-visiting path)))
    (and (buffer-modified-p buffer) buffer)))

(defun isled-editor-save (&optional finish baseline)
  "Save the draft, optionally FINISH; BASELINE is a confirmed current version."
  (interactive)
  (when isled-editor-busy (user-error "An editor operation is pending"))
  (when isled-editor-uncertain (user-error "Previous save is uncertain; inspect saved state and Revert before retrying"))
  (when-let ((source (isled-editor-source-conflict-p)))
    (user-error "Source buffer %s has unsaved edits; save or discard those first" (buffer-name source)))
  (let ((buffer (current-buffer)) (generation isled-editor-generation)
        (window (selected-window)))
    (setq isled-editor-busy t)
    (isled-editor-request
     isled-editor-root "save" (or baseline isled-editor-record) (isled-editor-form-submission)
     (lambda (response)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (setq isled-editor-busy nil)
           (if (eq (alist-get 'ok response) t)
               (progn
                 (setq isled-editor-record
                       (alist-get 'record response)
                       isled-editor-conflict nil isled-editor-disk-error nil
                       isled-editor-save-failed nil isled-editor-closing nil)
                 (rename-buffer (format "*isled edit %s*" (isled-editor-record-id isled-editor-record)) t)
                 (when (buffer-live-p isled-editor-origin)
                   (with-current-buffer isled-editor-origin (isled-refresh)))
                 (when (= generation isled-editor-generation)
                   (isled-editor-form-render (isled-editor-record-draft isled-editor-record))
                   (set-buffer-modified-p nil)
                   (when (and finish (eq (selected-window) window)
                              (eq (window-buffer window) buffer))
                     (isled-editor-return)))
                 (when-let ((warning (alist-get 'warning response))) (message "%s" warning)))
             (when (equal (alist-get 'code response) "conflict")
               (setq isled-editor-conflict
                     (alist-get 'current response)))
             (when (member (alist-get 'code response) '("publication" "transport"))
               (setq isled-editor-uncertain t)
               (message "Save may have changed the ledger; inspect before retrying"))
             (isled-editor-report-save-failure response))
           (when isled-editor-disk-again (isled-editor-disk-check)))))
     isled-editor-closing)))

(defun isled-editor-finish ()
  "Save this issue and return to its ledger view."
  (interactive) (isled-editor-save t))

(defun isled-editor-confirm-discard ()
  "Ask before discarding an unsaved draft."
  (or (not (buffer-modified-p)) (yes-or-no-p "Discard unsaved issue draft changes? ")))

(defun isled-editor-cancel ()
  "Cancel editing without undoing a completed save."
  (interactive)
  (when isled-editor-busy (user-error "Wait for the pending editor operation"))
  (when (isled-editor-confirm-discard)
    (set-buffer-modified-p nil)
    (isled-editor-return)))

(defun isled-editor-revert ()
  "Reload the saved issue or reset a new draft after confirmation."
  (interactive)
  (when isled-editor-busy (user-error "Wait for the pending editor operation"))
  (when (isled-editor-confirm-discard)
    (if isled-editor-record
        (isled-editor-load (isled-editor-record-id isled-editor-record))
      (when isled-editor-uncertain
        (unless (yes-or-no-p "Creation may have succeeded.  Have you inspected the ledger before resetting? ")
          (user-error "Inspect the ledger before resetting this draft")))
      (setq isled-editor-uncertain nil)
      (isled-editor-form-render (isled-editor-empty-draft))
      (set-buffer-modified-p nil))))

(defun isled-editor-overwrite ()
  "Confirm replacing the saved version returned by the last conflict."
  (interactive)
  (unless isled-editor-conflict (user-error "No conflicting saved version to overwrite"))
  (when (yes-or-no-p "Overwrite newer saved edits with this draft? ")
    (isled-editor-save nil isled-editor-conflict)))

(defun isled-editor-compare ()
  "Show a standard read-only diff of the saved version and draft fields."
  (interactive)
  (unless isled-editor-conflict (user-error "No conflicting saved version to compare"))
  (let ((saved (make-temp-file "isled-saved-")) (draft (make-temp-file "isled-draft-"))
        (saved-fields (isled-editor-record-draft isled-editor-conflict))
        (fields (isled-editor-form-submission)))
    (unwind-protect
        (progn
          (with-temp-file saved
            (insert (isled-editor-form-text saved-fields)))
          (with-temp-file draft (insert (isled-editor-form-text fields)))
          (let ((buffer (diff-no-select saved draft "-u" t)))
            (with-current-buffer buffer (setq buffer-read-only t))
            (display-buffer buffer)))
      (delete-file saved) (delete-file draft))))

(defun isled-editor-return ()
  "Return through surviving ledger/editor windows without replacing other work."
  (let* ((buffer (current-buffer)) (origin isled-editor-origin)
         (window isled-editor-window) (record isled-editor-record)
         (origin-window (and (buffer-live-p origin) (get-buffer-window origin)))
         (editor-window (get-buffer-window buffer)))
    (when (buffer-live-p origin)
      (cond (origin-window (select-window origin-window))
            (editor-window (set-window-buffer editor-window origin)
                           (select-window editor-window)))
      (when (and (window-live-p window) (eq (window-buffer window) buffer)
                 (not (one-window-p t))) (delete-window window))
      (when (and record (get-buffer-window origin))
        (with-current-buffer origin
          (isled--visit-issue
           (isled-issue-create :id (isled-editor-record-id record)
                               :status (isled-editor-record-status record))))))
    (kill-buffer buffer)))

(defun isled-editor-cleanup ()
  "Cancel idle work and retire completion documentation buffers."
  (when (timerp isled-editor-timer) (cancel-timer isled-editor-timer))
  (isled-session-unsubscribe isled-editor-session)
  (dolist (entry isled-editor-documents)
    (when (buffer-live-p (cdr entry)) (kill-buffer (cdr entry)))))

(provide 'isled-editor)
;;; isled-editor.el ends here
