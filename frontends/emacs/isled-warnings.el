;;; isled-warnings.el --- Navigate retained ledger warnings -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Keywords: tools

;;; Commentary:
;; Cycle Rust's known findings using ordinary window/view jump history.

;;; Code:
(require 'isled-frontend)
(require 'isled-navigation)
(require 'isled-rows)

(defvar-local isled-warnings-target nil "First known warning target reported by Rust.")
(defvar-local isled-warnings-targets nil "Ordered known warning targets from Rust.")
(defvar isled-loading-active)
(declare-function isled--capture-view-state "isled-browser")
(declare-function isled--visit-issue "isled-browser")
(declare-function isled-loading-request "isled-loading")

(defun isled-warnings-accept (response)
  "Retain the ledger-wide finding from validated RESPONSE."
  (setq isled-warnings-target (isled-response-first-warning response)
        isled-warnings-targets (or (isled-response-warning-targets response)
                                  (and isled-warnings-target (list isled-warnings-target))))
  (force-mode-line-update t))

(defun isled-warnings-click (event)
  "Jump to a known warning in the window clicked by EVENT."
  (interactive "e")
  (with-selected-window (posn-window (event-start event))
    (isled-jump-to-warning)))

(defvar-keymap isled-warnings-map
  "<header-line> <mouse-1>" #'isled-warnings-click
  "<header-line> <mouse-2>" #'isled-warnings-click)

(defun isled-warnings-indicator ()
  "Return a clickable indicator when Rust has a known ledger finding."
  (when isled-warnings-target
    (propertize "⚠ Known warnings  " 'face 'isled-warning-face
                'mouse-face 'mode-line-highlight 'keymap isled-warnings-map
                'help-echo "Jump to a known warning (!); M-, returns to this view")))

(defun isled-warnings--focus (target &optional index)
  "Move to TARGET's diagnostic INDEX (default zero), returning non-nil on success."
  (let ((position
         (if (isled-issue-p target)
             (when-let ((row (and isled-rows-index
                                  (gethash (isled-issue-id target) isled-rows-index))))
               (text-property-any (isled-row-content row) (isled-row-end row)
                                  'isled-warning-index (or index 0)))
           (text-property-any (point-min) (point-max) 'isled-warning-id
                              (isled-unavailable-id target)))))
    (when position (goto-char position) t)))

(defun isled-warnings--target-id (target)
  "Return the issue identity of warning TARGET."
  (if (isled-issue-p target) (isled-issue-id target) (isled-unavailable-id target)))

(defun isled-warnings--next ()
  "Choose the next target and warning ordinal from the current location."
  (let* ((targets (or isled-warnings-targets (list isled-warnings-target)))
         (row (isled-row-at))
         (index (get-text-property (point) 'isled-warning-index))
         (id (or (and index row (isled-row-value row))
                 (get-text-property (point) 'isled-warning-id)))
         (tail (and id (member (seq-find (lambda (target)
                                          (equal id (isled-warnings--target-id target)))
                                        targets) targets))))
    (if (and tail index row
             (< (1+ index) (length (isled-issue-warnings (isled-row-issue row)))))
        (cons (car tail) (1+ index))
      (cons (or (cadr tail) (car targets)) 0))))

(defun isled-jump-to-warning ()
  "Reveal the next known warning, wrapping in issue order, using jump history."
  (interactive nil isled-mode)
  (unless isled-warnings-target (user-error "No known ledger warnings"))
  (isled-navigation-with-window
   (let* ((destination (isled-warnings--next))
          (target (car destination))
          (index (cdr destination))
          (origin (isled--capture-view-state)))
     (cl-labels
         ((remember () (isled-navigation-record origin))
          (focus () (if (isled-warnings--focus target index)
                       (remember)
                     (message "The selected warning is no longer present"))))
       (if (isled-issue-p target)
           (isled--visit-issue
            target
            (lambda ()
              (if (isled-warnings--focus target index)
                  (remember)
                (if isled-loading-active
                    (isled-loading-request 'details nil #'focus)
                  (focus)))))
         (if (isled-warnings--focus target index)
             (remember)
           (isled-loading-request
            'view nil (lambda () (when (isled-warnings--focus target index) (remember))))))))))

(provide 'isled-warnings)
;;; isled-warnings.el ends here
