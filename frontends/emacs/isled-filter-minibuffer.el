;;; isled-filter-minibuffer.el --- Whole-query minibuffer suggestions -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Assisted-by: Codex:GPT-6
;; Keywords: tools

;;; Commentary:
;; Complete one whole query with stock minibuffer completion or Vertico.
;;; Code:
(require 'isled-filter-display)

(defun isled-filter-minibuffer-table (choices string predicate action)
  "Complete STRING using CHOICES and standard PREDICATE and ACTION."
  (if (eq action 'metadata)
      '(metadata (category . isled-filter))
    (let* ((choices (if (functionp choices) (funcall choices) choices))
           (token (car (last (isled-filter-query-tokens string t))))
           (start (if (and token (= (cadr token) (length string))) (car token)
                    (length string)))
           (part (substring string start))
           (choices (isled-filter-completion-choices part choices)))
      (completion-table-with-context
       (substring string 0 start)
       (apply-partially #'completion-table-with-terminator " " choices)
       part predicate action))))

(defvar vertico--input)
(defvar vertico--total)
(declare-function vertico-insert "vertico")
(declare-function vertico--update "vertico")

(defun isled-filter-minibuffer-insert ()
  "Insert the selected candidate while preserving later query terms.
Use standard completion when this minibuffer is not managed by Vertico."
  (interactive)
  ;; Vertico refreshes synchronously only for its own named commands.  Its
  ;; interruptible display hook may have skipped updates while input was queued.
  (when (and (local-variable-p 'vertico--input)
             (bound-and-true-p vertico--input)
             (fboundp 'vertico--update))
    (vertico--update))
  (if (and (local-variable-p 'vertico--input)
           (bound-and-true-p vertico--input)
           (boundp 'vertico--total) (> vertico--total 0)
           (fboundp 'vertico-insert))
      (let* ((before (buffer-substring-no-properties (minibuffer-prompt-end) (point)))
             (after (buffer-substring-no-properties (point) (point-max)))
             (bounds (completion-boundaries before minibuffer-completion-table
                                            minibuffer-completion-predicate after))
             (suffix (substring after (cdr bounds))))
        (vertico-insert)
        (save-excursion (goto-char (point-max)) (insert suffix))
        (isled-filter-completion-status-exit
         (buffer-substring-no-properties (minibuffer-prompt-end) (point)) 'finished))
    (minibuffer-complete)))

(defvar-local isled-filter-minibuffer--context nil
  "Last stock display context: modification tick and point.")
(defvar-local isled-filter-minibuffer--window nil
  "Stock completion window used by this filter prompt.")

(defun isled-filter-minibuffer-stop ()
  "Dismiss this prompt's stock completion display on exit."
  (when (and (window-live-p isled-filter-minibuffer--window)
             (eq (window-buffer isled-filter-minibuffer--window)
                 (get-buffer "*Completions*")))
    (quit-window nil isled-filter-minibuffer--window))
  (setq isled-filter-minibuffer--window nil))

(defun isled-filter-minibuffer--show ()
  "Refresh stock choices using the normal completion window display policy."
  (let* ((text (minibuffer-contents-no-properties))
         (matches (completion-all-completions
                   text minibuffer-completion-table minibuffer-completion-predicate
                   (- (point) (minibuffer-prompt-end)))))
    (if (or (null matches)
            (and (not (consp (cdr matches))) (equal (car matches) text)))
        ;; Standard help hides its window for these states.  Keep the existing
        ;; display stable, and remove obsolete selectable candidates instead.
        (with-current-buffer (get-buffer-create "*Completions*")
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert (if matches "Already complete.\n" "No matching choices.\n"))
            (completion-list-mode))
          (display-buffer (current-buffer)))
      (let ((completion-fail-discreetly t))
        (minibuffer-completion-help)))
    (setq isled-filter-minibuffer--window
          (get-buffer-window "*Completions*"))))

(defun isled-filter-minibuffer-changed ()
  "Refresh stock choices once per text or cursor change in this prompt.
An explicitly dismissed display stays dismissed until that context changes."
  (when (and (eq (isled-filter-display-owner) 'stock)
             (eq (current-buffer) (window-buffer (minibuffer-window))))
    (let ((context (cons (buffer-chars-modified-tick) (point))))
      (unless (equal context isled-filter-minibuffer--context)
        (setq isled-filter-minibuffer--context context)
        (isled-filter-minibuffer--show)))))

(defun isled-filter-minibuffer-refresh ()
  "Refresh this prompt's dynamic choices without changing query text or point."
  (when (eq (current-buffer) (window-buffer (minibuffer-window)))
    (when (and (not (isled-filter-display-vertico))
               (eq (isled-filter-display-owner) 'stock))
      (let ((context (cons (buffer-chars-modified-tick) (point))))
        (unless (and (equal context isled-filter-minibuffer--context)
                     isled-filter-minibuffer--window
                     (not (and (window-live-p isled-filter-minibuffer--window)
                               (eq (window-buffer isled-filter-minibuffer--window)
                                   (get-buffer "*Completions*")))))
          (setq isled-filter-minibuffer--context context)
          (isled-filter-display-stock #'isled-filter-minibuffer--show))))))

(defun isled-filter-minibuffer-setup (_choices)
  "Install this prompt's whole-query completion keys and display hooks.
_CHOICES is supplied by the common adapter interface; the reader owns its table."
  (setq-local completion-no-auto-exit t
              completion-extra-properties
              '(:exit-function isled-filter-completion-status-exit))
  (add-hook 'isled-filter-completion-update-hook
            #'isled-filter-minibuffer-refresh nil t)
  (when (isled-filter-display-owner)
    (let ((map (make-sparse-keymap)))
      (set-keymap-parent map (current-local-map))
      (define-key map (kbd "TAB") #'isled-filter-minibuffer-insert)
      (define-key map (kbd "<tab>") #'isled-filter-minibuffer-insert)
      (define-key map [remap vertico-insert] #'isled-filter-minibuffer-insert)
      (use-local-map map)))
  (when (eq (isled-filter-display-owner) 'stock)
    (local-set-key (kbd "M-v") #'switch-to-completions)
    (add-hook 'post-command-hook #'isled-filter-minibuffer-changed nil t)
    (add-hook 'minibuffer-exit-hook #'isled-filter-minibuffer-stop nil t)
    (isled-filter-minibuffer-changed)))

(defvar isled-filter-history)

(defun isled-filter-minibuffer-read (initial _choices)
  "Read the whole query from INITIAL; _CHOICES is replaced by live prompt data.
The common caller installs the one-shot setup hook and owns acceptance."
  ;; Orderless ignores point when computing all completions.  This whole-query
  ;; table needs a style which respects the current field instead.
  (let ((completion-category-overrides
         (cons '(isled-filter (styles basic)) completion-category-overrides)))
    (completing-read "Filter issues: "
                     (apply-partially #'isled-filter-minibuffer-table
                                      (lambda () isled-filter-completion-values))
                     nil nil initial 'isled-filter-history)))

(provide 'isled-filter-minibuffer)
;;; isled-filter-minibuffer.el ends here
