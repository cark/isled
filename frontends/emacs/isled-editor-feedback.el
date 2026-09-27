;;; isled-editor-feedback.el --- Non-disruptive draft feedback -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Assisted-by: Codex:GPT-6
;; Keywords: tools

;;; Commentary:
;; Present draft/save state and compare watched saved versions without reloading.

;;; Code:
(require 'isled-editor-form)
(require 'isled-header)
(require 'isled-session)
(defvar isled-editor-mode-map)

(defun isled-editor-header ()
  "Return a width-aware identity, state and Help header for the draft."
  (let* ((binding (where-is-internal 'isled-editor-help isled-editor-mode-map t))
         (help (propertize (format "[%s] Help" (if binding (key-description binding) "M-x isled-editor-help"))
                           'face 'isled-help-key-face))
         (state (string-join
                 (delq nil (list (when isled-editor-closing "Closing issue")
                                 (when (or (buffer-modified-p) (not isled-editor-record)) "Not saved")
                                 (when isled-editor-conflict "Changed on disk")
                                 (when isled-editor-save-failed "Save failed")
                                 (when isled-editor-uncertain "Check saved state")
                                 (when isled-editor-disk-error "Disk check failed")
                                 (when isled-editor-busy "Working…"))) " · "))
         (identity (format "Isled · %s · %s"
                           (file-name-nondirectory (directory-file-name (or isled-editor-root default-directory)))
                           (if isled-editor-record
                               (format "#%s" (isled-editor-record-id isled-editor-record)) "New issue")))
         (width (window-body-width))
         (room (max 0 (- width (string-width help) 1)))
         (status (propertize state 'face (if (or isled-editor-closing (buffer-modified-p) (not isled-editor-record)
                                                isled-editor-conflict isled-editor-save-failed
                                                isled-editor-uncertain isled-editor-disk-error)
                                            'warning 'isled-header-count-face)))
         (left (if (>= (string-width status) room) (truncate-string-to-width status room)
                 (concat (propertize (isled-header--truncate identity
                                                            (- room (string-width status) (if (string-empty-p state) 0 3)))
                                     'face 'isled-header-title-face)
                         (unless (string-empty-p state) " · ") status))))
    (isled-header-mode-line
     (if (<= width (string-width help)) (truncate-string-to-width help width)
       (concat left (make-string (max 1 (- width (string-width left) (string-width help))) ?\s) help)))))

(defun isled-editor-disk-check ()
  "Check the current saved version after a shared ledger notification."
  (when isled-editor-record
    (if (or isled-editor-busy isled-editor-disk-checking)
        (setq isled-editor-disk-again t)
      (let ((buffer (current-buffer)) (baseline isled-editor-record))
        (setq isled-editor-disk-checking t isled-editor-disk-again nil)
        (isled-editor-request
         isled-editor-root "load" baseline nil
         (lambda (response)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (setq isled-editor-disk-checking nil)
               (when (and (eq baseline isled-editor-record) (not isled-editor-busy))
                 (if (eq (alist-get 'ok response) t)
                     (let ((current (alist-get 'record response)))
                       (setq isled-editor-disk-error nil
                             isled-editor-conflict
                             (unless (equal (isled-editor-record-version baseline)
                                            (isled-editor-record-version current)) current)))
                   (setq isled-editor-disk-error t)))
               (force-mode-line-update)
               (when isled-editor-disk-again (isled-editor-disk-check))))))))))

(defun isled-editor-report-save-failure (response)
  "Display RESPONSE without moving point; announce an explicit save failure."
  (setq isled-editor-save-failed t)
  (isled-editor-form-errors (alist-get 'errors response))
  (force-mode-line-update)
  (message "%s; draft kept.  %s for details and actions"
           (cond (isled-editor-uncertain "Save may have changed the ledger; inspect saved state")
                 ((equal (alist-get 'code response) "conflict") "Issue changed on disk")
                 (t (concat "Not saved: " (or (alist-get 'message (car (append (alist-get 'errors response) nil)))
                                              "save failed"))))
           (substitute-command-keys "\\[isled-editor-help]")))

(defun isled-editor-next-error ()
  "Move explicitly to the next diagnostic, wrapping after the last one."
  (interactive)
  (let* ((positions (sort (mapcar #'overlay-start isled-editor-errors) #'<))
         (next (or (seq-find (lambda (position) (> position (point))) positions) (car positions))))
    (unless next (user-error "No field errors; use Compare for changes on disk"))
    (goto-char next)))

(provide 'isled-editor-feedback)
;;; isled-editor-feedback.el ends here
