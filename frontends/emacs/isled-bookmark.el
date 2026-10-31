;;; isled-bookmark.el --- Persistent semantic view bookmarks -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Assisted-by: Codex:GPT-6
;; Keywords: tools

;;; Commentary:
;; Store readable locations and presentation choices, reusing the browser's
;; view restoration.  Buffer identity keeps independently saved views apart.

;;; Code:
(require 'bookmark)
(require 'isled-context)
(require 'isled-view-state)
(require 'isled-navigation)
(require 'isled-filter-query)
(require 'isled-viewport)

(defvar isled--root)
(defvar isled--snapshot)
(defvar isled-loading-initializer)
(defvar isled-buffers-fresh)
(defvar isled-loading-generation)
(defvar isled-loading-dirty)
(defvar-local isled-bookmark--pending-point nil
  "Generation and semantic point awaiting an expanded body.")
(defvar-local isled-bookmark--identity nil "Persistent identity of this view.")
(declare-function isled-mode "isled-browser")
(declare-function isled--capture-view-state "isled-browser")
(declare-function isled--buffer-name "isled-browser")
(declare-function isled--opened "isled-buffers")
(declare-function isled-loading-request "isled-loading")
(declare-function isled-entry-ledger "isled-entry")
(declare-function isled-sections-restore-point-state "isled-sections")

(defun isled-bookmark-make-record ()
  "Return a bookmark record for the current semantic view."
  (unless (and isled--root isled--snapshot)
    (user-error "Wait for the Isled view to load before bookmarking it"))
  (unless isled-bookmark--identity
    (setq isled-bookmark--identity (make-temp-name "isled-view-")))
  (isled-navigation-with-window
    (let ((state (isled--capture-view-state)))
      `(,(format "Isled: %s" (file-name-nondirectory (isled-context-current)))
        (handler . isled-bookmark-jump)
        (isled-version . 1)
        (isled-root . ,isled--root)
        (isled-location . ,(isled-context-current))
        (isled-identity . ,isled-bookmark--identity)
        (isled-state
         (filter . ,(isled--view-state-filter state))
         (graph . ,(isled--view-state-graph-direction state))
         (order . ,(isled--view-state-flat-order state))
         (selected . ,(isled--view-state-selected-id state))
         (expanded . ,(copy-sequence (isled--view-state-expanded-ids state)))
         (point . ,(isled--view-state-point-state state))
         (ledger-point . ,(isled--view-state-ledger-point state)))))))

(defun isled-bookmark--id-p (value)
  "Return whether VALUE is an issue identifier."
  (and (stringp value) (string-match-p "\\`[0-9]\\{4\\}\\'" value)))

(defun isled-bookmark--point-p (value &optional ledger)
  "Return whether VALUE is an optional semantic point, allowing LEDGER targets."
  (or (null value)
      (and (consp value)
           (if ledger (stringp (car value)) (isled-bookmark--id-p (car value)))
           (natnump (cdr value)))))

(defun isled-bookmark--decode (record)
  "Validate RECORD and return its internal view state."
  (let* ((data (bookmark-prop-get record 'isled-state))
         (filter (alist-get 'filter data))
         (graph (alist-get 'graph data))
         (order (alist-get 'order data))
         (selected (alist-get 'selected data))
         (expanded (alist-get 'expanded data))
         (point (alist-get 'point data))
         (ledger-point (alist-get 'ledger-point data)))
    (unless (and (eql (bookmark-prop-get record 'isled-version) 1)
                 (proper-list-p data) (seq-every-p #'consp data)
                 (or (memq filter '(open closed all)) (stringp filter))
                 (memq graph '(nil prerequisites dependents))
                 (memq order '(id oldest-first))
                 (or (null selected) (isled-bookmark--id-p selected))
                 (proper-list-p expanded) (seq-every-p #'isled-bookmark--id-p expanded)
                 (isled-bookmark--point-p point)
                 (isled-bookmark--point-p ledger-point t))
      (user-error "Invalid or unsupported Isled bookmark"))
    ;; Reject an invalid query before replacing a visible destination.
    (isled-filter-query-criteria filter)
    (isled--view-state-create :filter filter :graph-direction graph :flat-order order
                              :selected-id selected :expanded-ids (copy-sequence expanded)
                              :point-state point :ledger-point ledger-point)))

(defun isled-bookmark--directory (record property)
  "Return the canonical existing directory in RECORD's PROPERTY."
  (let ((path (bookmark-prop-get record property)))
    (unless (and (stringp path) (file-name-absolute-p path) (not (file-remote-p path)))
      (user-error "Invalid Isled bookmark directory"))
    (let ((canonical (isled-context-canonical path)))
      (unless (equal canonical (directory-file-name path))
        (user-error "Isled bookmark directory now points elsewhere: %s" path))
      canonical)))

(defun isled-bookmark--buffer (identity root location)
  "Find the living view with IDENTITY, ROOT and LOCATION."
  (seq-find
   (lambda (buffer)
     (with-current-buffer buffer
       (and (derived-mode-p 'isled-mode)
            (equal isled-bookmark--identity identity)
            (equal isled--root root)
            (equal (isled-context-current) location))))
   (buffer-list)))

(defun isled-bookmark--cancel-point ()
  "Cancel the outstanding bookmark cursor restoration."
  (setq isled-bookmark--pending-point nil)
  (remove-hook 'post-command-hook #'isled-bookmark--cancel-point t)
  (remove-hook 'isled-viewport-update-hook #'isled-bookmark--finish-point t))

(defun isled-bookmark--finish-point ()
  "Restore a saved body position once formatting is available."
  (when isled-bookmark--pending-point
    (pcase-let* ((`(,generation . ,target) isled-bookmark--pending-point)
                 (row (and isled-rows-index (gethash (car target) isled-rows-index))))
      (cond
       ((not (eq generation isled-loading-generation))
        (isled-bookmark--cancel-point))
       ;; A hidden view has accepted data but has not rendered its rows yet.
       (isled-loading-dirty nil)
       ((null row) (isled-bookmark--cancel-point))
       ((and (isled-row-rich row) (isled-issue-content (isled-row-issue row)))
        (isled-bookmark--cancel-point)
        (isled-sections-restore-point-state target)
        (dolist (window (get-buffer-window-list (current-buffer) nil t))
          (set-window-point window (point))))))))

(defun isled-bookmark--defer-point (state)
  "Retain STATE's expanded-body cursor until its text has arrived."
  (isled-bookmark--cancel-point)
  (let ((target (isled--view-state-point-state state)))
    (when (and target (member (car target) (isled--view-state-expanded-ids state)))
      (setq isled-bookmark--pending-point (cons isled-loading-generation target))
      (add-hook 'isled-viewport-update-hook #'isled-bookmark--finish-point nil t)
      (add-hook 'post-command-hook #'isled-bookmark--cancel-point nil t)
      (isled-bookmark--finish-point))))

(defun isled-bookmark--restore (record)
  "Select RECORD's destination buffer and start asynchronous restoration."
  (require 'isled-browser)
  (require 'isled-entry)
  (let* ((state (isled-bookmark--decode record))
         (root (isled-bookmark--directory record 'isled-root))
         (location (isled-bookmark--directory record 'isled-location))
         (identity (bookmark-prop-get record 'isled-identity)))
    (unless (and (stringp identity) (not (string-empty-p identity)))
      (user-error "Invalid Isled bookmark view identity"))
    (unless (equal root (isled-entry-ledger root))
      (user-error "Isled bookmark ledger is unavailable: %s" root))
    (let* ((local (isled-entry-ledger location))
           (existing (isled-bookmark--buffer identity root location))
           (buffer (or existing (generate-new-buffer (isled--buffer-name location)))))
      ;; bookmark-jump and Activities need the buffer now, not in a callback.
      ;; Let the bookmark caller display it; never pop another window here.
      (set-buffer buffer)
      (unless existing
        (isled-mode)
        (setq isled--root root isled-context-location location
              isled-context-local-ledger local
              isled-buffers-fresh t isled-bookmark--identity identity
              default-directory (file-name-as-directory root)
              isled-loading-initializer #'isled--opened)
        (let ((inhibit-read-only t)) (insert "Loading project issues…\n")))
      ;; Capture no temporary window origin: Activities may replace its layout
      ;; before the reply.  Request generations still fence newer view changes.
      (isled-loading-request 'refresh state
                             (lambda () (isled-bookmark--defer-point state)) nil nil t)
      (set-buffer buffer))))

;;;###autoload
(defun isled-bookmark-jump (record)
  "Restore the Isled bookmark RECORD without exposing expected failures."
  (let ((origin (current-buffer)))
    (condition-case failure
        (isled-bookmark--restore record)
      ((user-error file-error wrong-type-argument)
       (set-buffer origin)
       (message "Isled bookmark: %s" (error-message-string failure))))))

(provide 'isled-bookmark)
;;; isled-bookmark.el ends here
