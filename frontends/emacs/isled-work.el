;;; isled-work.el --- Issue work actions and history -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Assisted-by: Codex:GPT-6
;; Keywords: tools

;;; Commentary:
;; Small asynchronous actions for the issue at point.  Rust owns transitions,
;; clock invariants and publication; this module owns interaction and history.

;;; Code:
(require 'isled-process)
(require 'isled-rows)
(require 'isled-work-data)
(require 'transient)

(defvar isled--root)
(declare-function isled-refresh "isled-browser")

(defun isled-work--target ()
  "Return the issue at point, or explain the required browser context."
  (unless (and (derived-mode-p 'isled-mode) isled--root)
    (user-error "Open an Isled issue view first"))
  (if-let ((row (isled-row-at))) (isled-row-issue row)
    (user-error "Move to an issue first")))

(defun isled-work--run (arguments &optional history)
  "Run work ARGUMENTS on the issue at point; HISTORY displays the result."
  (let* ((issue (isled-work--target)) (id (isled-issue-id issue))
         (root isled--root) (origin (current-buffer))
         (command (append (list "--root" root "work" (car arguments) id) (cdr arguments))))
    (isled-process-command
     root command nil
     (lambda (result)
       (if (not (zerop (isled-command-result-status result)))
           (message "Isled work: %s" (string-trim (isled-command-result-stderr result)))
         (if history
             (isled-work--history root id (isled-command-result-stdout result))
           (when (buffer-live-p origin)
             (with-current-buffer origin (isled-refresh)))
           (message "%s" (string-trim (isled-command-result-stdout result)))))))))

(defun isled-work--history (root id text)
  "Display persistent work history TEXT for ID under ROOT."
  (let ((buffer (get-buffer-create (format "*Isled work #%s: %s*" id root))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t)) (erase-buffer) (insert text) (goto-char (point-min)))
      (special-mode))
    (display-buffer buffer)))

(defun isled-work-queue ()
  "Queue the issue at point without timing."
  (interactive) (isled-work--run '("queue")))

(defun isled-work-unqueue ()
  "Return the issue at point to Not queued, stopping its clock."
  (interactive) (isled-work--run '("unqueue")))

(defun isled-work-start (&optional activity)
  "Start or resume timing the issue at point with optional ACTIVITY.
With a prefix argument, prompt for a short activity label."
  (interactive (list (when current-prefix-arg (read-string "Activity (optional): "))))
  (isled-work--run (append '("start") (when (and activity (not (string-empty-p activity)))
                                      (list "--activity" activity)))))

(defun isled-work-start-without-timing ()
  "Start working on the issue at point without timing."
  (interactive) (isled-work--run '("start" "--no-clock")))

(defun isled-work-pause (&optional at)
  "Pause timing the issue at point at UTC time AT, leaving its state unchanged.
With a prefix argument, prompt for the actual stop time of a forgotten clock."
  (interactive (list (when current-prefix-arg
                       (read-string "Actual stop (UTC, YYYY-MM-DD HH:MM:SS): "))))
  (isled-work--run (append '("pause") (when at (list "--at" at)))))

(defun isled-work-await-review ()
  "Stop timing and mark the issue at point ready for owner review."
  (interactive) (isled-work--run '("await" "--reason" "review")))

(defun isled-work-await-clarification (question)
  "Stop timing and wait for the owner to answer QUESTION."
  (interactive (list (progn (isled-work--target) (read-string "Question for owner: "))))
  (when (string-empty-p (string-trim question)) (user-error "A question is required"))
  (isled-work--run (list "await" "--reason" "clarification" "--question" question)))

(defun isled-work-show ()
  "Show the issue's work state, pending question and complete span history."
  (interactive) (isled-work--run '("show") t))

(defun isled-work-correct-stop (span stop)
  "Correct numbered SPAN's actual STOP time for the issue at point."
  (interactive (progn (isled-work--target)
                      (list (read-number "Span number (see Work history): ")
                            (read-string "Actual stop (UTC, YYYY-MM-DD HH:MM:SS): "))))
  (unless (and (integerp span) (> span 0)) (user-error "Span numbers start at 1"))
  (isled-work--run (list "correct" (number-to-string span) "--stop" stop)))

(transient-define-prefix isled-work ()
  "Show work actions for the issue at point."
  [["Work"
    ("q" "Queue" isled-work-queue)
    ("u" "Not queued" isled-work-unqueue)
    ("s" "Start / resume" isled-work-start)
    ("n" "Start without timing" isled-work-start-without-timing)
    ("p" "Pause clock" isled-work-pause)]
   ["Owner"
    ("r" "Ready for review" isled-work-await-review)
    ("a" "Ask a question" isled-work-await-clarification)]
   ["Time"
    ("h" "Work history" isled-work-show)
    ("c" "Correct stop time" isled-work-correct-stop)]]
  (interactive) (isled-work--target) (transient-setup 'isled-work))

(provide 'isled-work)
;;; isled-work.el ends here
