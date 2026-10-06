;;; isled-work-data.el --- Typed work state and timing -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Assisted-by: Codex:GPT-6
;; Keywords: tools

;;; Commentary:
;; Validate work projections once and keep elapsed-time formatting independent
;; of subprocesses and browser positions.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'time-date)

(define-error 'isled-work-data-error "Invalid Isled work data")

(cl-defstruct (isled-work-data (:constructor isled-work-data-create))
  "Validated work summary with an optional complete span history."
  (state "not-queued") reason question (recorded-seconds 0) running-since spans)

(cl-defstruct (isled-work-span (:constructor isled-work-span-create))
  "One validated UTC work span."
  started stopped activity)

(defun isled-work-data--field (wire key)
  "Read required KEY from WIRE, decoding JSON null as nil."
  (unless (and (listp wire) (assq key wire))
    (signal 'isled-work-data-error (list (format "Missing work field: %s" key))))
  (let ((value (alist-get key wire))) (unless (eq value :json-null) value)))

(defun isled-work-data--time (text)
  "Decode canonical UTC TEXT, or signal invalid work data."
  (unless (and (stringp text)
               (string-match-p "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\} [0-9]\\{2\\}:[0-9]\\{2\\}:[0-9]\\{2\\}\\'" text))
    (signal 'isled-work-data-error '("Invalid UTC work time")))
  (let ((time (condition-case nil
                  (date-to-time (concat (replace-regexp-in-string " " "T" text) "Z"))
                (error (signal 'isled-work-data-error '("Invalid UTC work date"))))))
    (unless (equal text (format-time-string "%Y-%m-%d %H:%M:%S" time t))
      (signal 'isled-work-data-error '("Invalid UTC work date")))
    time))

(defun isled-work-data-decode (wire &optional complete)
  "Decode WIRE into typed work data; COMPLETE requires validated spans."
  (let* ((state (isled-work-data--field wire 'state))
         (reason (isled-work-data--field wire 'reason))
         (question (isled-work-data--field wire 'question))
         (seconds (isled-work-data--field wire 'recorded_seconds))
         (running (isled-work-data--field wire 'running_since)))
    (unless (and (member state '("not-queued" "queued" "in-progress" "awaiting-owner"))
                 (natnump seconds)
                 (if (equal state "awaiting-owner")
                     (or (and (equal reason "review") (null question))
                         (and (equal reason "clarification") (stringp question)
                              (not (string-empty-p (string-trim question)))
                              (not (string-match-p "[\n\r\0]" question))))
                   (and (null reason) (null question)))
                 (or (null running) (equal state "in-progress")))
      (signal 'isled-work-data-error '("Invalid work summary")))
    (let ((work (isled-work-data-create
                 :state state :reason reason :question question
                 :recorded-seconds seconds
                 :running-since (and running (isled-work-data--time running)))))
      (when complete
        (setf (isled-work-data-spans work)
              (isled-work-data--spans (isled-work-data--field wire 'spans) work)))
      work)))

(defun isled-work-data--spans (wire work)
  "Decode WIRE spans and verify their timing agrees with WORK."
  (unless (or (listp wire) (vectorp wire))
    (signal 'isled-work-data-error '("Work spans must be an array")))
  (let ((seconds 0) previous-end previous-start spans)
    (seq-doseq (item wire)
      (let* ((start (isled-work-data--time (isled-work-data--field item 'started)))
             (stop-text (isled-work-data--field item 'stopped))
             (stop (and stop-text (isled-work-data--time stop-text)))
             (activity (isled-work-data--field item 'activity)))
        (unless (and (stringp activity) (not (string-match-p "[\n\r\0|]" activity))
                     (equal activity (string-trim activity))
                     (or (null stop) (not (time-less-p stop start)))
                     (or (null previous-start)
                         (and previous-end (not (time-less-p start previous-end)))))
          (signal 'isled-work-data-error '("Invalid or overlapping work spans")))
        (when stop (cl-incf seconds (round (float-time (time-subtract stop start)))))
        (setq previous-start start previous-end stop)
        (push (isled-work-span-create :started start :stopped stop :activity activity) spans)))
    (unless (and (= seconds (isled-work-data-recorded-seconds work))
                 (equal (and previous-start (null previous-end) previous-start)
                        (isled-work-data-running-since work)))
      (signal 'isled-work-data-error '("Work totals disagree with span history")))
    (nreverse spans)))

(defun isled-work-data-seconds (work &optional now)
  "Return elapsed seconds for WORK at NOW, defaulting to the current time."
  (+ (isled-work-data-recorded-seconds work)
     (if-let ((start (isled-work-data-running-since work)))
         (max 0 (floor (float-time (time-subtract (or now (current-time)) start))))
       0)))

(defun isled-work-data-duration (seconds)
  "Format elapsed SECONDS as a compact human-readable duration."
  (if (>= seconds 3600) (format "%dh %02dm" (/ seconds 3600) (% (/ seconds 60) 60))
    (format "%dm %02ds" (/ seconds 60) (% seconds 60))))

(defun isled-work-data-label (work)
  "Return a compact state and nonzero completed time for WORK.
Running elapsed time is available in Work history without a presentation timer."
  (if (null work) ""
    (let* ((state (isled-work-data-state work))
           (label (pcase state
                    ("not-queued" "") ("queued" "Queued")
                    ("in-progress" "In progress")
                    ("awaiting-owner" (if (equal (isled-work-data-reason work) "review")
                                          "Review" "Question"))))
           (seconds (isled-work-data-recorded-seconds work))
           (timed (> seconds 0)))
      (if (and (string-empty-p label) (not timed)) ""
        (concat "  [" label (if (and timed (not (string-empty-p label))) " · " "")
                (when timed (isled-work-data-duration seconds)) "]")))))

(provide 'isled-work-data)
;;; isled-work-data.el ends here
