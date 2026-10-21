;;; isled-work-display-test.el --- Live heading clock tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Exercise deterministic clock values, real row/window boundaries, lifecycle
;; and refresh integration in an isolated Emacs, without ledger writes.

;;; Code:
(require 'isled-windows-test)
(require 'isled-work-display)

(defmacro isled-work-display-test--with-view (&rest body)
  "Run BODY with a displayed view of 250 running issues."
  (declare (indent 0) (debug t))
  `(isled-windows-test--with-view
     (setq isled--expanded-ids nil isled--selected-id "0001")
     (dolist (issue (isled-snapshot-issues isled--snapshot))
       (setf (isled-issue-work issue)
             (isled-work-data-create :state "in-progress" :running-since (seconds-to-time 1000))))
     (isled--render)
     (isled-windows-test--point (selected-window) "0001")
     ,@body))

(defun isled-work-display-test--label (id)
  "Return the displayed work label for issue ID, or nil."
  (when-let ((overlay (and isled-work-display--overlays
                           (gethash (gethash id isled-rows-index)
                                    isled-work-display--overlays))))
    (overlay-get overlay 'display)))

(ert-deftest isled-work-display-duration-boundaries-and-recorded-spans ()
  (let ((work (isled-work-data-create :state "in-progress" :running-since (seconds-to-time 1000))))
    (dolist (example '((0 . "0m 00s") (59 . "0m 59s") (60 . "1m 00s")
                       (3599 . "59m 59s") (3600 . "1h 00m 00s") (3661 . "1h 01m 01s")))
      (should (equal (isled-work-data-label work (seconds-to-time (+ 1000 (car example))))
                     (concat "  [In progress · " (cdr example) "]"))))
    (should (equal (isled-work-data-label work (seconds-to-time 999))
                   "  [In progress · 0m 00s]"))
    (setf (isled-work-data-recorded-seconds work) 3600)
    (should (equal (isled-work-data-label work (seconds-to-time 1061))
                   "  [In progress · 1h 01m 01s]"))
    ;; Change detection is independent of wall time.
    (should (equal (isled-work-data-label work) "  [In progress · 1h 00m]"))
    (setf (isled-work-data-running-since work) nil)
    (should (equal (isled-work-data-label work (seconds-to-time 999999))
                   "  [In progress · 1h 00m]"))))

(ert-deftest isled-work-display-ticks-preserve-text-navigation-and-do-no-io ()
  (isled-work-display-test--with-view
    (let* ((now 1059)
           (row (gethash "0001" isled-rows-index))
           (text (buffer-string))
           (tick (buffer-chars-modified-tick))
           (positions (mapcar (lambda (item) (list (isled-row-start item)
                                                   (isled-row-content item) (isled-row-end item)))
                              (append isled-rows nil)))
           (point (point)) (start (window-start))
           (selected isled--selected-id))
      (set-mark (+ (point) 5))
      (setq mark-active t)
      (cl-letf (((symbol-function 'current-time) (lambda () (seconds-to-time now)))
                ((symbol-function 'isled-process-command) (lambda (&rest _) (ert-fail "Process on tick")))
                ((symbol-function 'isled-process-run) (lambda (&rest _) (ert-fail "Process on tick")))
                ((symbol-function 'write-region) (lambda (&rest _) (ert-fail "Write on tick")))
                ((symbol-function 'isled--render) (lambda (&rest _) (ert-fail "Render on tick")))
                ((symbol-function 'isled-rows-write-heading) (lambda (&rest _) (ert-fail "Heading rewrite"))))
        (isled-work-display-update)
        (should (equal (isled-work-display-test--label "0001") "  [In progress · 0m 59s]"))
        ;; A delayed callback calculates time instead of counting missed ticks.
        (setq now 4661)
        (cancel-timer isled-work-display--timer)
        (isled-work-display--tick (current-buffer))
        (should (equal (isled-work-display-test--label "0001") "  [In progress · 1h 01m 01s]")))
      (should (equal text (buffer-string)))
      (should (= tick (buffer-chars-modified-tick)))
      (should (= point (point)))
      (should (= (+ point 5) (mark)))
      (should mark-active)
      (should (= start (window-start)))
      (should (equal selected isled--selected-id))
      (should (isled-row-hidden row))
      (should-not (buffer-modified-p))
      (should (isled-rows-heading-matches-p row (isled-row-issue row)))
      (should (equal positions
                     (mapcar (lambda (item) (list (isled-row-start item)
                                                   (isled-row-content item) (isled-row-end item)))
                             (append isled-rows nil)))))))

(ert-deftest isled-work-display-bounds-updates-to-the-union-of-visible-headings ()
  (isled-work-display-test--with-view
    (let ((other (split-window-below)))
      (isled-windows-test--point other "0200")
      (isled-work-display-update)
      (should (isled-work-display-test--label "0001"))
      (should (isled-work-display-test--label "0200"))
      (should-not (isled-work-display-test--label "0100"))
      (should (< (hash-table-count isled-work-display--overlays) 50))
      (isled-windows-test--point other "0001")
      (isled-work-display-update)
      (should-not (isled-work-display-test--label "0200"))
      (should (isled-work-display-test--label "0001"))
      ;; Expanding a long body can hide every running heading below the top.
      (let ((row (gethash "0001" isled-rows-index)))
        (isled-sections-show row)
        (isled-rows-write-body row (make-string 2000 ?\n))
        (delete-window other)
        (set-window-start (selected-window) (+ (isled-row-content row) 10))
        (goto-char (+ (isled-row-content row) 10))
        (isled-work-display-update)
        (should-not isled-work-display--overlays)
        (should-not isled-work-display--timer)))))

(ert-deftest isled-work-display-observer-stops-hidden-clocks-and-catches-up-on-return ()
  (isled-work-display-test--with-view
    (let ((view (current-buffer)) (now 1000))
      (cl-letf (((symbol-function 'current-time) (lambda () (seconds-to-time now))))
        (isled-windows-track #'isled-loading--display-changed)
        (funcall pre-redisplay-function t)
        (should (equal (isled-work-display-test--label "0001") "  [In progress · 0m 00s]"))
        (let ((timer isled-work-display--timer))
          (with-temp-buffer
            (set-window-buffer (selected-window) (current-buffer))
            (funcall pre-redisplay-function t)
            (with-current-buffer view
              (should-not isled-work-display--timer)
              (should-not isled-work-display--overlays))
            (should-not (memq timer timer-list))
            (setq now 1075)
            (set-window-buffer (selected-window) view)
            (funcall pre-redisplay-function t)))
        (should (equal (isled-work-display-test--label "0001") "  [In progress · 1m 15s]"))
        (let ((timer isled-work-display--timer)
              (overlay (gethash (gethash "0001" isled-rows-index) isled-work-display--overlays)))
          (fundamental-mode)
          (should-not isled-work-display--timer)
          (should-not (memq timer timer-list))
          (should-not (overlay-buffer overlay)))))))

(ert-deftest isled-work-display-refresh-handles-pause-resume-correction-and-removal ()
  (isled-work-display-test--with-view
    (let ((issue (car (isled-snapshot-issues isled--snapshot))))
      ;; Restrict to one issue so a paused view has no other running clocks.
      (setf (isled-snapshot-issues isled--snapshot) (list issue))
      (cl-letf (((symbol-function 'current-time) (lambda () (seconds-to-time 5000))))
        (isled-loading--present (isled--capture-view-state) (isled--window-anchors))
        (should (equal (isled-work-display-test--label "0001") "  [In progress · 1h 06m 40s]"))
        (setf (isled-issue-work issue) (isled-work-data-create :state "in-progress" :recorded-seconds 3600))
        (isled-loading--present (isled--capture-view-state) (isled--window-anchors))
        (should-not isled-work-display--timer)
        (should-not isled-work-display--overlays)
        (should (string-match-p "In progress · 1h 00m]" (buffer-string)))
        ;; Resume without changing any static heading input.
        (setf (isled-work-data-running-since (isled-issue-work issue)) (seconds-to-time 4990))
        (let ((tick (buffer-chars-modified-tick)))
          (isled-loading--present (isled--capture-view-state) (isled--window-anchors))
          (should (= tick (buffer-chars-modified-tick))))
        (should (equal (isled-work-display-test--label "0001") "  [In progress · 1h 00m 10s]"))
        (setf (isled-work-data-recorded-seconds (isled-issue-work issue)) 1800)
        (isled-loading--present (isled--capture-view-state) (isled--window-anchors))
        (should (equal (isled-work-display-test--label "0001") "  [In progress · 30m 10s]"))
        (let ((overlay (gethash (gethash "0001" isled-rows-index) isled-work-display--overlays)))
          (setf (isled-snapshot-issues isled--snapshot) nil)
          (isled-loading--present (isled--capture-view-state) (isled--window-anchors))
          (should-not (overlay-buffer overlay))
          (should-not isled-work-display--timer))))))

(ert-deftest isled-work-display-killing-view-releases-timer-and-overlays ()
  (let (timer overlay)
    (isled-work-display-test--with-view
      (isled-work-display-update)
      (setq timer isled-work-display--timer
            overlay (gethash (gethash "0001" isled-rows-index) isled-work-display--overlays)))
    (should (timerp timer))
    (should-not (memq timer timer-list))
    (should-not (overlay-buffer overlay))))

(provide 'isled-work-display-test)
;;; isled-work-display-test.el ends here
