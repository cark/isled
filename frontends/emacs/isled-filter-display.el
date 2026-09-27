;;; isled-filter-display.el --- Refresh asynchronous completion displays -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Assisted-by: Codex:GPT-6
;; Keywords: tools

;;; Commentary:
;; Standard tables supply candidates.  These narrow optional UI bridges invalidate
;; caches that otherwise key only on input text and point, preserving selection.
;;; Code:
(require 'isled-filter-completion)
(require 'text-property-search)

(defvar vertico--index)
(defvar vertico--candidates)
(defvar corfu--index)
(defvar corfu--candidates)
(defvar completion-reference-buffer)

(defun isled-filter-display-owner (&optional inline)
  "Identify a supported UI for this prompt, or nil for another owner.
INLINE checks completion in region; otherwise check minibuffer completion.
Default dispatch alone is insufficient: built-in Icomplete and some optional
UIs enhance it through modes instead of replacing the dispatch function."
  (if inline
      (unless (or (bound-and-true-p company-mode)
                  (bound-and-true-p auto-complete-mode)
                  (bound-and-true-p completion-preview-mode)
                  (and (bound-and-true-p icomplete-mode)
                       (bound-and-true-p icomplete-in-buffer)))
        (cond
         ((and (bound-and-true-p corfu-mode)
               (eq completion-in-region-function 'corfu--in-region)) 'corfu)
         ((eq completion-in-region-function 'completion--in-region) 'stock)))
    (unless (or (bound-and-true-p icomplete-mode) (bound-and-true-p mct-mode)
                (bound-and-true-p ivy-mode) (bound-and-true-p helm-mode)
                (bound-and-true-p ido-ubiquitous-mode))
      (when (eq completing-read-function 'completing-read-default)
        (if (local-variable-p 'vertico--input) 'vertico 'stock)))))

(defun isled-filter-display-candidate (&optional inline)
  "Return this prompt's selected supported candidate, without changing its UI.
INLINE selects the in-buffer completion ownership boundary."
  (pcase (isled-filter-display-owner inline)
    ('vertico
     (when (and (boundp 'vertico--index) (boundp 'vertico--candidates)
                (integerp vertico--index) (>= vertico--index 0))
       (nth vertico--index vertico--candidates)))
    ('corfu
     (when (and completion-in-region-mode
                (boundp 'corfu--candidates)
                (markerp (car completion-in-region--data))
                (eq (marker-buffer (car completion-in-region--data)) (current-buffer))
                (boundp 'corfu--index) (integerp corfu--index) (>= corfu--index 0))
       (nth corfu--index corfu--candidates)))
    ('stock
     (let ((prompt (current-buffer)))
       (when-let ((window (get-buffer-window "*Completions*")))
         (with-current-buffer (window-buffer window)
           (when (eq completion-reference-buffer prompt)
             (get-text-property (window-point window) 'completion--string))))))))

(defvar-local isled-filter-display--selection nil
  "Last selected candidate, retained while contextual choices are pending.")
(defvar-local isled-filter-display--selection-context nil
  "Completion context owning the retained candidate selection.")

(defun isled-filter-display--sync-selection-context ()
  "Synchronize retained selection with the current completion context.
Return non-nil when the retained display context is still current."
  (let ((same (eq isled-filter-display--selection-context
                  isled-filter-completion-context)))
    (unless same
      (setq isled-filter-display--selection nil
            isled-filter-display--selection-context
            isled-filter-completion-context))
    same))

(defvar vertico--input)
(declare-function vertico--update "vertico")
(declare-function vertico--exhibit "vertico")

(defun isled-filter-display-vertico ()
  "Refresh an active compatible Vertico prompt without editing its input.
Return non-nil when this optional integration handled the display."
  (when (and (eq (isled-filter-display-owner) 'vertico)
             (local-variable-p 'vertico--input)
             (boundp 'vertico--index) (boundp 'vertico--candidates)
             (fboundp 'vertico--update) (fboundp 'vertico--exhibit))
    (when (and (isled-filter-display--sync-selection-context)
               (>= vertico--index 0))
      (setq isled-filter-display--selection
            (nth vertico--index vertico--candidates)))
    (setq vertico--input nil)
    (vertico--update)
    (when-let ((index (seq-position vertico--candidates
                                    isled-filter-display--selection #'equal)))
      (setq vertico--index index))
    (vertico--exhibit)
    t))

(defvar corfu-on-exact-match)
(declare-function corfu-quit "corfu")
(declare-function corfu--auto-complete-deferred "corfu")
(declare-function corfu--exhibit "corfu")

(defun isled-filter-display-corfu ()
  "Refresh an active compatible Corfu prompt without inserting a candidate.
Return non-nil when this optional integration handled the display."
  (when (and (eq (isled-filter-display-owner t) 'corfu)
             (bound-and-true-p corfu-mode)
             (boundp 'corfu--index) (boundp 'corfu--candidates)
             (fboundp 'corfu-quit) (fboundp 'corfu--auto-complete-deferred)
             (fboundp 'corfu--exhibit))
    (when (and (isled-filter-display--sync-selection-context)
               completion-in-region-mode (>= corfu--index 0))
      (setq isled-filter-display--selection
            (nth corfu--index corfu--candidates)))
    ;; Reestablish the CAPF's current token range as well as its choice table.
    (when completion-in-region-mode (corfu-quit))
    (unless isled-filter-completion-pending
      (let ((corfu-on-exact-match 'show))
        (corfu--auto-complete-deferred)
        (when (and completion-in-region-mode
                   isled-filter-display--selection)
          (when-let ((index (seq-position corfu--candidates
                                          isled-filter-display--selection #'equal)))
            (setq corfu--index index)
            (corfu--exhibit)))))
    t))

(defun isled-filter-display-stock (show)
  "Call SHOW and retain the selected stock completion when it remains valid."
  (let ((choice (when (and (isled-filter-display--sync-selection-context)
                           (get-buffer "*Completions*"))
                  (with-current-buffer "*Completions*"
                    (get-text-property (point) 'completion--string)))))
    (when choice (setq isled-filter-display--selection choice)))
  (let ((selected isled-filter-display--selection))
    (setq completion-all-sorted-completions nil)
    (funcall show)
    (when (and selected (get-buffer "*Completions*"))
      (with-current-buffer "*Completions*"
        (goto-char (point-min))
        (when-let ((match (text-property-search-forward 'completion--string selected t)))
          (goto-char (prop-match-beginning match)))))))

(provide 'isled-filter-display)
;;; isled-filter-display.el ends here
