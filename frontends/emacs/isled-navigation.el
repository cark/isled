;;; isled-navigation.el --- Window-owned browsing state -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Keywords: tools

;;; Commentary:
;; Keep navigation memories for each window/view pair across buffer switches.
;; Async destinations retain their origin rather than borrowing current focus.

;;; Code:
(require 'cl-lib)

(defvar isled--back-history)
(defvar isled--forward-history)
(defvar isled--saved-view-states)
(defvar isled--last-collapse-by-filter)
(defvar isled--selected-id)
(defvar-local isled-navigation--states nil
  "Window-keyed navigation state for this view.")
(defvar isled-navigation--window nil
  "Originating window during one navigation operation.")

(declare-function isled--capture-view-state "isled-browser")
(declare-function isled--view-state-filter "isled-browser")
(declare-function isled--view-state-graph-direction "isled-browser" (state))
(declare-function isled--view-state-point-state "isled-browser")
(declare-function isled--view-state-selected-id "isled-browser")
(declare-function isled--view-state-ledger-point "isled-browser")

(defun isled-navigation--location (state)
  "Return STATE's semantic location, independent of fold presentation."
  (when state
    (list (isled--view-state-filter state)
          (isled--view-state-graph-direction state)
          (isled--view-state-point-state state)
          (isled--view-state-ledger-point state)
          (unless (or (isled--view-state-point-state state)
                      (isled--view-state-ledger-point state))
            (isled--view-state-selected-id state)))))

(defun isled-navigation-record (origin &optional direction)
  "Record ORIGIN after a successful jump, suppressing duplicate locations.
DIRECTION is `back' or `forward' during history traversal; nil starts a new
branch.  An unchanged destination preserves both existing history stacks."
  (unless (equal (isled-navigation--location origin)
                 (isled-navigation--location (isled--capture-view-state)))
    (when origin
      (let* ((stack (if (eq direction 'back)
                        'isled--forward-history 'isled--back-history))
             (entries (symbol-value stack)))
        (unless (equal (isled-navigation--location origin)
                       (isled-navigation--location (car entries)))
          (set stack (cons origin entries)))))
    (unless direction (setq isled--forward-history nil))))

(defun isled-navigation--capture ()
  "Return the currently bound navigation memories."
  (list isled--back-history isled--forward-history
        isled--saved-view-states isled--last-collapse-by-filter
        isled--selected-id))

(defun isled-navigation-prune ()
  "Detach memories of deleted windows from this view."
  (when isled-navigation--states
    (maphash (lambda (window _) (unless (window-live-p window)
                                 (remhash window isled-navigation--states)))
             isled-navigation--states)))

(defun isled-navigation-call (function &optional window)
  "Call FUNCTION with navigation memories belonging to WINDOW and this view."
  (let ((window (or window isled-navigation--window (selected-window))))
    (if (or isled-navigation--window
            (not (eq (window-buffer window) (current-buffer))))
        (funcall function)
      (unless isled-navigation--states
        (setq isled-navigation--states (make-hash-table :test #'eq)))
      (isled-navigation-prune)
      (let* ((buffer (current-buffer))
             (table isled-navigation--states)
             (state (or (gethash window isled-navigation--states)
                        (isled-navigation--capture)))
             (isled-navigation--window window)
             (isled--back-history (nth 0 state))
             (isled--forward-history (nth 1 state))
             (isled--saved-view-states (copy-tree (nth 2 state)))
             (isled--last-collapse-by-filter (copy-tree (nth 3 state)))
             (isled--selected-id (nth 4 state)))
        (unwind-protect (funcall function)
          (when (buffer-live-p buffer)
            (with-current-buffer buffer
              (puthash window (isled-navigation--capture) table))))))))

(defmacro isled-navigation-with-window (&rest body)
  "Run BODY with the invoking window's independent navigation memories."
  (declare (indent 0) (debug t))
  `(isled-navigation-call (lambda () ,@body)))

(defun isled-navigation-origin ()
  "Capture the originating window, view and point for asynchronous navigation."
  (let ((window (or isled-navigation--window (selected-window))))
    (when (eq (window-buffer window) (current-buffer))
      (list window (current-buffer) (copy-marker (window-point window))))))

(defun isled-navigation-valid-p (origin)
  "Return whether ORIGIN still denotes the invoking view and unchanged point."
  (or (null origin)
      (pcase-let ((`(,window ,buffer ,point) origin))
        (and (window-live-p window) (buffer-live-p buffer)
             (eq (window-buffer window) buffer)
             (= (window-point window) point)))))

(defun isled-navigation-at-origin (origin function)
  "Call FUNCTION with ORIGIN's window selected, preserving the user's focus."
  (if (not origin) (funcall function)
    (let ((window (car origin)))
      (with-selected-window window
        (isled-navigation-call function window)))))

(provide 'isled-navigation)
;;; isled-navigation.el ends here
