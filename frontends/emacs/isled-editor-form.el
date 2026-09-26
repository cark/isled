;;; isled-editor-form.el --- Editable issue fields and diagnostics -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Keywords: tools

;;; Commentary:
;; Widget-backed fields preserve ordinary text motion and protected structure.

;;; Code:
(require 'wid-edit)
(require 'isled-editor-model)
(require 'isled-presentation)

(defface isled-editor-field
  '((((class color) (background dark)) :foreground "#e6edf3" :background "#253344" :extend t :weight normal)
    (((class color) (background light)) :foreground "#172b4d" :background "#e8eff8" :extend t :weight normal)
    (t :inverse-video t))
  "Background for editable issue fields."
  :group 'isled)
(defface isled-editor-active-field
  '((((class color) (background dark)) :foreground "#ffffff" :background "#354f70" :extend t :weight normal)
    (((class color) (background light)) :foreground "#10243a" :background "#cbdff5" :extend t :weight normal)
    (t :inverse-video t :weight normal))
  "Background for the field containing point."
  :group 'isled)
(defface isled-editor-error
  '((t :inherit error))
  "Actionable errors beside draft fields."
  :group 'isled)
(defface isled-editor-label
  '((t :inherit font-lock-keyword-face :weight bold))
  "Labels and section headings in issue drafts."
  :group 'isled)
(defvar isled-editor-field-map nil "Keymap used inside editable draft fields.")
(declare-function isled-editor-changed "isled-editor" (&rest ignored))
(declare-function isled-editor-revert "isled-editor" ())
(declare-function isled-editor-compare "isled-editor" ())
(declare-function isled-editor-overwrite "isled-editor" ())

(defun isled-editor-form-field (locator value &optional multiline)
  "Insert an editable VALUE at LOCATOR, optionally MULTILINE."
  (let ((widget (widget-create
                 (if multiline 'text 'editable-field)
                 :format "%v\n" :value value :size nil
                 :value-face 'isled-editor-field
                 :keymap isled-editor-field-map
                 :notify #'isled-editor-changed)))
    (widget-put widget :isled-error-marker (copy-marker (1- (point))))
    (push (cons locator widget) isled-editor-fields)
    widget))

(defun isled-editor-form-value (locator)
  "Return the current widget value for LOCATOR."
  (widget-value (cdr (assoc locator isled-editor-fields))))

(defun isled-editor-form-draft ()
  "Collect the current complete draft without changing its authored fields."
  `((title . ,(isled-editor-form-value "title"))
    (kind . ,(isled-editor-form-value "kind"))
    (tags . ,(vconcat (split-string (isled-editor-form-value "tags") "[, \t\n]+" t)))
    (statement . ,(isled-editor-form-value "statement"))
    (evidence . ,(vconcat (isled-editor-form-list "evidence")))
    (outcome . ,(isled-editor-form-value "outcome"))
    (waiting_on . ,(vconcat (isled-editor-form-relations "waiting_on")))
    (blocking . ,(vconcat (isled-editor-form-relations "blocking")))))

(defun isled-editor-form-submission ()
  "Collect a normalized submission without rewriting the visible draft."
  (let ((draft (isled-editor-form-draft)))
    (setf (alist-get 'statement draft) (string-trim (alist-get 'statement draft))
          (alist-get 'tags draft) (vconcat (delete-dups (append (alist-get 'tags draft) nil))))
    draft))

(defun isled-editor-form-list (field)
  "Collect ordered scalar values beneath FIELD."
  (cl-loop for index from 0
           while (assoc (format "%s.%d" field index) isled-editor-fields)
           collect (isled-editor-form-value (format "%s.%d" field index))))

(defun isled-editor-form-relations (field)
  "Collect ordered relation values beneath FIELD."
  (cl-loop for index from 0
           for locator = (format "%s.%d" field index)
           while (assoc (concat locator ".id") isled-editor-fields)
           collect `((id . ,(isled-editor-form-value (concat locator ".id")))
                     (reason . ,(isled-editor-form-value (concat locator ".reason"))))))

(defun isled-editor-form-change-list (field index)
  "Remove INDEX from FIELD, or append an empty entry when INDEX is nil."
  (let* ((draft (isled-editor-form-draft))
         (values (append (alist-get field draft) nil)))
    (setf (alist-get field draft)
          (vconcat (if index (cl-loop for entry in values for i from 0
                                      unless (= i index) collect entry)
                     (append values (list (if (eq field 'evidence) ""
                                            '((id . "") (reason . ""))))))))
    (isled-editor-form-render draft)
    (let* ((row (if index (min index (1- (length (alist-get field draft)))) (length values)))
           (locator (format "%s.%d%s" field row (if (eq field 'evidence) "" ".id"))))
      (if-let ((widget (cdr (assoc locator isled-editor-fields))))
          (goto-char (widget-field-start widget))
        (goto-char (cdr (assq field isled-editor-add-buttons)))))
    (isled-editor-changed)))

(defun isled-editor-form-button (label function)
  "Insert an action LABEL calling FUNCTION."
  (widget-create 'push-button :notify (lambda (&rest _) (funcall function)) label))

(defun isled-editor-form-add-button (field label)
  "Insert the add button for FIELD with LABEL and retain its navigation anchor."
  (push (cons field (copy-marker (point))) isled-editor-add-buttons)
  (isled-editor-form-button label (lambda () (isled-editor-form-change-list field nil))))

(defun isled-editor-form-label (text)
  "Insert protected label TEXT with the section face."
  (insert (propertize text 'face 'isled-editor-label 'rear-nonsticky '(face))))

(defun isled-editor-form-render (draft)
  "Render DRAFT as protected labels and editable fields."
  (let* ((old-widget (widget-field-find (point)))
         (old-locator (car (rassq old-widget isled-editor-fields)))
         (old-offset (and old-widget (- (point) (widget-field-start old-widget))))
         (window (get-buffer-window (current-buffer)))
         (old-start (and window (window-start window))))
    (make-local-variable 'before-change-functions)
    (make-local-variable 'after-change-functions)
    (cl-incf isled-editor-generation)
    (let ((inhibit-read-only t)
          (before-change-functions nil) (after-change-functions nil))
      (remove-overlays)
      (setq widget-field-list nil widget-field-new nil widget-field-last nil)
      (erase-buffer)
      (setq isled-editor-fields nil isled-editor-errors nil
            isled-editor-add-buttons nil isled-editor-active-overlay nil)
      (isled-editor-form-label "Status: ")
      (let ((status (if isled-editor-record (isled-editor-record-status isled-editor-record) "open")))
        (insert (propertize (capitalize status) 'face (pcase status
                                          ("open" 'success)
                                          ("closed" 'isled-closed-issue-id-face)
                                          (_ 'isled-subdued-face))
                            'rear-nonsticky '(face)) "\n\n"))
      (dolist (entry '((title . "Title: ") (kind . "Kind:  ") (tags . "Tags (spaces or commas):\n")))
	(isled-editor-form-label (cdr entry))
	(isled-editor-form-field
	 (symbol-name (car entry))
	 (if (eq (car entry) 'tags)
             (mapconcat #'identity (alist-get 'tags draft) ", ")
           (alist-get (car entry) draft))))
      (isled-editor-form-label "Statement\n")
      (isled-editor-form-field "statement" (alist-get 'statement draft) t)
      (isled-editor-form-label "Evidence\n")
      (let ((entries (alist-get 'evidence draft)))
	(unless (equal entries ["Pending."])
          (cl-loop for value across entries for index from 0 do
                   (insert "• ")
                   (isled-editor-form-field (format "evidence.%d" index) value)
                   (let ((row index))
                     (isled-editor-form-button "Remove evidence"
                                               (lambda () (isled-editor-form-change-list 'evidence row))))
                   (insert "\n"))))
      (isled-editor-form-add-button 'evidence "Add evidence")
      (isled-editor-form-label "\n\nOutcome\n")
      (isled-editor-form-field "outcome" (alist-get 'outcome draft) t)
      (dolist (section '((waiting_on . "Waiting on — this issue waits on")
			 (blocking . "Blocking — this issue blocks")))
	(isled-editor-form-label (concat (cdr section) "\n"))
	(let ((field (car section)))
          (cl-loop for edge across (alist-get field draft) for index from 0 do
                   (let ((locator (format "%s.%d" field index)) (row index))
                     (isled-editor-form-label "Issue: ")
                     (isled-editor-form-field (concat locator ".id") (alist-get 'id edge))
                     (isled-editor-form-label "Reason: ")
                     (isled-editor-form-field (concat locator ".reason") (alist-get 'reason edge))
                     (isled-editor-form-button "Remove relation"
                                               (lambda () (isled-editor-form-change-list field row)))
                     (insert "\n")))
          (isled-editor-form-add-button field "Add relation"))
	(insert "\n\n"))
      (isled-editor-form-button "Revert draft" #'isled-editor-revert)
      (insert "\n"))
    (widget-setup)
    (setq-local truncate-lines nil truncate-partial-width-windows nil word-wrap t)
    (dolist (entry isled-editor-fields)
      (let* ((widget (cdr entry))
             (overlay (make-overlay (widget-field-start widget)
                                    (min (point-max) (1+ (widget-field-end widget))))))
	(overlay-put overlay 'face 'isled-editor-field)))
    (isled-editor-form-statement-height)
    (isled-editor-form-closing-status)
  (let ((widget (cdr (assoc old-locator isled-editor-fields))))
      (goto-char (if widget
                     (min (+ (widget-field-start widget) old-offset) (widget-field-end widget))
                   (widget-field-start (cdr (assoc "title" isled-editor-fields))))))
    (when (and window old-start) (set-window-start window (min old-start (point-max)) t))))

(defun isled-editor-form-closing-status ()
  "Display closure intent without changing draft text or cursor position."
  (when (overlayp isled-editor-closing-overlay)
    (delete-overlay isled-editor-closing-overlay))
  (when isled-editor-closing
    (save-excursion
      (goto-char (point-min))
      (let ((end (line-end-position)))
        (setq isled-editor-closing-overlay (make-overlay end end))
        (overlay-put isled-editor-closing-overlay 'after-string
                     (propertize " → Closed" 'face 'warning))))))

(defun isled-editor-form-errors (errors)
  "Show selectable ERRORS outside values without moving point."
  (let ((inhibit-read-only t) (inhibit-modification-hooks t)
        (before-change-functions nil) (after-change-functions nil)
        (buffer-undo-list t) (modified (buffer-modified-p)))
    (save-excursion
      (dolist (overlay isled-editor-errors)
        (delete-region (overlay-start overlay) (overlay-end overlay))
        (delete-overlay overlay))
      (setq isled-editor-errors nil)
      (seq-doseq (entry errors)
        (let* ((field (alist-get 'field entry))
               (widget (or (cdr (assoc field isled-editor-fields))
                           (cdr (assoc (concat field ".id") isled-editor-fields))
                           (cdr (assoc (concat field ".reason") isled-editor-fields))))
               (position (if widget (widget-get widget :isled-error-marker) (point-min))))
          (goto-char position)
          (let ((start (point)))
            (insert (propertize (concat "  ⚠ " (alist-get 'message entry) "\n")
                                'face 'isled-editor-error 'read-only t
                                'front-sticky nil 'rear-nonsticky t))
            (push (make-overlay start (point)) isled-editor-errors)))))
    (set-buffer-modified-p modified)))

(defun isled-editor-form-highlight ()
  "Highlight the editable field containing point."
  (when isled-editor-active-overlay (delete-overlay isled-editor-active-overlay))
  (when-let ((widget (widget-field-find (point))))
    (setq isled-editor-active-overlay
          (make-overlay (widget-field-start widget)
                        (min (point-max) (1+ (widget-field-end widget)))))
    (overlay-put isled-editor-active-overlay 'face 'isled-editor-active-field)
    (overlay-put isled-editor-active-overlay 'priority '(nil . 1))))

(defun isled-editor-form-statement-height ()
  "Keep Statement at least three lines tall without adding authored whitespace."
  (when-let ((widget (cdr (assoc "statement" isled-editor-fields))))
    (let* ((start (widget-field-start widget)) (end (widget-field-end widget))
           (window (get-buffer-window (current-buffer)))
           (lines (if window (max 1 (count-screen-lines start end nil window))
                    (1+ (cl-count ?\n (buffer-substring-no-properties start end)))))
           (overlay (widget-get widget :isled-height-overlay)))
      (unless (overlayp overlay)
        (setq overlay (make-overlay end (1+ end)))
        (widget-put widget :isled-height-overlay overlay))
      (move-overlay overlay end (1+ end))
      (overlay-put overlay 'after-string
                   (propertize (make-string (max 0 (- 3 lines)) ?\n)
                               'face (if (<= start (point) end)
                                         'isled-editor-active-field 'isled-editor-field))))))

(defun isled-editor-form-text (draft)
  "Render DRAFT as readable field text for standard diff comparison."
  (concat "Title: " (alist-get 'title draft) "\nKind: " (alist-get 'kind draft)
          "\nTags: " (mapconcat #'identity (alist-get 'tags draft) ", ")
          "\n\nStatement\n" (alist-get 'statement draft)
          "\n\nEvidence\n"
          (mapconcat (lambda (entry) (concat "• " entry))
                     (if (zerop (length (alist-get 'evidence draft))) ["Pending."]
                       (alist-get 'evidence draft)) "\n")
          "\n\nOutcome\n" (alist-get 'outcome draft)
          (mapconcat
           (lambda (section)
             (concat "\n\n" (cdr section) "\n"
                     (mapconcat (lambda (edge)
                                  (concat "#" (alist-get 'id edge) "\nReason: "
                                          (alist-get 'reason edge)))
                                (alist-get (car section) draft) "\n")))
           '((waiting_on . "Waiting on") (blocking . "Blocking")) "")
          "\n"))

(provide 'isled-editor-form)
;;; isled-editor-form.el ends here
