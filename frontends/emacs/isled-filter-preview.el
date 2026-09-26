;;; isled-filter-preview.el --- Highlighted filter result previews -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Keywords: tools

;;; Commentary:
;; Observe an owned completion session without inserting its selected candidate.
;; The existing loading queue coalesces previews and rejects obsolete replies.
;;; Code:
(require 'isled-filter-display)

(defvar isled-filter--origin)
(defvar isled-filter--view)
(defvar isled-filter--last)
(defvar isled-filter--criteria)
(defvar isled-filter-active)
(defvar isled-filter-feedback)
(declare-function isled-filter--request "isled-filter")
(declare-function isled--capture-view-state "isled-browser")
(declare-function isled-loading-request "isled-loading")

(defvar-local isled-filter-preview--timer nil
  "Observation timer owned by this outer filter prompt.")
(defvar-local isled-filter-preview--query nil
  "Last temporary candidate query, or nil when showing typed input.")
(defvar-local isled-filter-preview--baseline nil
  "View state before the first candidate preview for the current typed input.")
(defvar-local isled-filter-preview--picker-origin nil
  "Outer filter prompt when this buffer is its recursive token picker.")
(defvar-local isled-filter-preview--interface nil
  "Completion interface belonging to this filter prompt.")

(defun isled-filter-preview-query (context candidate)
  "Replace CONTEXT's token with CANDIDATE, preserving surrounding query text.
Status candidates remove other status tokens just as actual insertion does."
  (let* ((text (isled-filter-context-text context))
         (start (isled-filter-context-start context))
         (end (isled-filter-context-end context))
         (status (string-prefix-p "s:" candidate)))
    (if (not status)
        (concat (substring text 0 start) candidate (substring text end))
      (let ((result text))
        (dolist (token (reverse (isled-filter-query-tokens text t)))
          (when (and (not (nth 3 token)) (string-prefix-p "s:" (nth 2 token))
                     (not (= (car token) start)))
            (setq result (concat (substring result 0 (car token))
                                 (substring result (cadr token))))
            (when (< (car token) start)
              (let ((length (- (cadr token) (car token))))
                (setq start (- start length) end (- end length))))))
        (concat (substring result 0 start) candidate (substring result end))))))

(defun isled-filter-preview--candidate (prompt)
  "Read the selected candidate belonging to PROMPT's active completion UI."
  (when-let ((active (active-minibuffer-window)))
    (let ((buffer (window-buffer active)))
      (when (or (eq buffer prompt)
                (eq (buffer-local-value 'isled-filter-preview--picker-origin buffer)
                    prompt))
        (with-current-buffer buffer
          (let* ((inline (and (eq buffer prompt)
                              (eq isled-filter-preview--interface 'inline-suggestions)))
                 (candidate (isled-filter-display-candidate inline)))
            ;; Whole-query completion UIs may include the unchanged query prefix.
            (when (stringp candidate)
              (nth 2 (car (last (isled-filter-query-tokens candidate t)))))))))))

(defun isled-filter-preview--apply (candidate)
  "Preview CANDIDATE or restore typed input in this prompt's owning view."
  (let* ((window isled-filter--origin)
         (view isled-filter--view)
         (context isled-filter-completion-context)
         (query (and candidate context
                     (not isled-filter-completion-pending)
                     (member candidate isled-filter-completion-values)
                     (equal (isled-filter-context-text context)
                            (minibuffer-contents-no-properties))
                     (= (isled-filter-context-point context)
                        (- (point) (minibuffer-prompt-end)))
                     (isled-filter-preview-query context candidate)))
         (typed isled-filter--last)
         (criteria isled-filter--criteria)
         (baseline isled-filter-preview--baseline))
    (when (and (not (equal query isled-filter-preview--query))
               (window-live-p window) (buffer-live-p view)
               (eq (window-buffer window) view)
               (buffer-local-value 'isled-filter-active view))
      (when (and query (not isled-filter-preview--query))
        (setq baseline
              (with-selected-window window
                (isled--capture-view-state))
              isled-filter-preview--baseline baseline))
      (setq isled-filter-preview--query query)
      (with-selected-window window
        (cond
         (query (isled-filter--request query))
         (criteria (isled-filter--request typed criteria))
         (baseline (isled-loading-request 'view baseline)))))))

(defun isled-filter-preview-observe (prompt)
  "Observe PROMPT's highlight after completion frameworks have updated display."
  (when (buffer-live-p prompt)
    (with-current-buffer prompt
      (when isled-filter-preview--timer
        (isled-filter-preview--apply
         (isled-filter-preview--candidate prompt))))))

(defun isled-filter-preview-stop ()
  "Stop this prompt's observer; the filter controller owns final restoration."
  (when (timerp isled-filter-preview--timer)
    (cancel-timer isled-filter-preview--timer))
  (setq isled-filter-preview--timer nil
        isled-filter-preview--query nil
        isled-filter-preview--baseline nil))

(defun isled-filter-preview-setup (interface)
  "Observe the selected candidate for INTERFACE until this filter prompt exits.
The small timer also observes stock completion windows and asynchronous popup
updates without global advice or hooks in unrelated completion sessions."
  (setq-local isled-filter-preview--interface interface
              isled-filter-preview--query nil
              isled-filter-preview--baseline nil
              isled-filter-preview--timer
              (when (isled-filter-display-owner (eq interface 'inline-suggestions))
                (run-at-time 0.1 0.1 #'isled-filter-preview-observe (current-buffer))))
  (add-hook 'minibuffer-exit-hook #'isled-filter-preview-stop nil t)
  (add-hook 'kill-buffer-hook #'isled-filter-preview-stop nil t))

(provide 'isled-filter-preview)
;;; isled-filter-preview.el ends here
