;;; isled-work-test.el --- Work tracking contracts -*- lexical-binding: t; -*-

;;; Commentary:
;; Check validated wire data and issue actions without contacting a working editor.

;;; Code:
(require 'ert)
(require 'isled-browser)
(require 'isled-work)

(defun isled-work-test--wire ()
  "Return a complete work projection with one completed and one running span."
  '((state . "in-progress") (reason . :json-null) (question . :json-null)
    (recorded_seconds . 1800) (running_since . "2026-10-06 10:00:00")
    (spans . (((started . "2026-10-06 09:00:00")
               (stopped . "2026-10-06 09:30:00") (activity . "Implementation"))
              ((started . "2026-10-06 10:00:00")
               (stopped . :json-null) (activity . "Review"))))))

(ert-deftest isled-work-decoder-retains-span-history-and-computes-elapsed-time ()
  (let ((work (isled-work-data-decode (isled-work-test--wire) t)))
    (should (= (length (isled-work-data-spans work)) 2))
    (should (= (isled-work-data-seconds work
               (isled-work-data--time "2026-10-06 10:15:00")) 2700))
    (should (equal (isled-work-data-label work) "  [In progress · 30m 00s]"))
    (should (equal (isled-work-data-duration 2700) "45m 00s"))
    (should (equal (isled-work-data-label (isled-work-data-create)) ""))))

(ert-deftest isled-work-decoder-rejects-lost-fields-and-inconsistent-timing ()
  (should-error (isled-work-data-decode '((state . "queued"))) :type 'isled-work-data-error)
  (let ((wire (copy-tree (isled-work-test--wire))))
    (setf (alist-get 'recorded_seconds wire) 0)
    (should-error (isled-work-data-decode wire t) :type 'isled-work-data-error))
  (let ((wire (copy-tree (isled-work-test--wire))))
    (setf (alist-get 'state wire) "awaiting-owner"
          (alist-get 'reason wire) "clarification"
          (alist-get 'running_since wire) :json-null)
    (should-error (isled-work-data-decode wire) :type 'isled-work-data-error)))

(ert-deftest isled-work-filter-is-separate-from-lifecycle ()
  (let ((criteria (isled-filter-query-criteria "s:open w:awaiting-owner k:feature")))
    (should (equal (alist-get 'status criteria) "open"))
    (should (equal (alist-get 'work_state criteria) "awaiting-owner")))
  (should-error (isled-filter-query-criteria "w:unknown") :type 'user-error))

(ert-deftest isled-work-actions-use-the-selected-issue-and-refresh-on-success ()
  (with-temp-buffer
    (setq major-mode 'isled-mode)
    (setq-local isled--root "/project")
    (let ((row (make-isled-row :issue (isled-issue-create :id "0042"))) commands (refreshes 0))
      (cl-letf (((symbol-function 'isled-row-at) (lambda (&rest _) row))
                ((symbol-function 'isled-process-command)
                 (lambda (root args input callback)
                   (should (equal root "/project")) (should-not input)
                   (push args commands)
                   (funcall callback (isled-command-result-create :status 0 :stdout "Updated" :stderr ""))))
                ((symbol-function 'isled-refresh) (lambda () (cl-incf refreshes))))
        (isled-work-queue)
        (isled-work-start "Implementation")
        (isled-work-pause "2026-10-06 09:30:00")
        (isled-work-start-without-timing)
        (isled-work-await-clarification "Which target?")
        (isled-work-await-review)
        (should (= refreshes 6))
        (should (member '("--root" "/project" "work" "start" "0042" "--no-clock") commands))
        (should (member '("--root" "/project" "work" "await" "0042" "--reason" "clarification"
                          "--question" "Which target?") commands))
        (should-error (isled-work-await-clarification " ") :type 'user-error)))))

(ert-deftest isled-work-failed-action-never-refreshes-or-retries ()
  (with-temp-buffer
    (setq major-mode 'isled-mode)
    (setq-local isled--root "/project")
    (cl-letf (((symbol-function 'isled-row-at)
               (lambda (&rest _) (make-isled-row :issue (isled-issue-create :id "0042"))))
              ((symbol-function 'isled-refresh) (lambda () (ert-fail "Refreshed after failure")))
              ((symbol-function 'isled-process-command)
               (lambda (_root _args _input callback)
                 (funcall callback (isled-command-result-create :status 1 :stdout "" :stderr "Rejected")))))
      (isled-work-start))))

(ert-deftest isled-work-heading-updates-when-state-changes ()
  (let* ((issue (isled-issue-create :id "0042" :status "open" :ready t :kind "feature" :title "Work"))
         (row (make-isled-row :issue issue :heading-key (isled-rows-heading-key issue))))
    (setf (isled-issue-work issue) (isled-work-data-create :state "queued"))
    (should-not (isled-rows-heading-matches-p row issue))
    (should (string-match-p "Queued" (isled-sections--heading issue)))))

(ert-deftest isled-work-pending-question-updates-heading-help ()
  (let* ((work (isled-work-data-create :state "awaiting-owner" :reason "clarification"
                                      :question "First question?"))
         (issue (isled-issue-create :id "0042" :status "open" :ready t :kind "feature"
                                   :title "Work" :work work))
         (row (make-isled-row :issue issue :heading-key (isled-rows-heading-key issue))))
    (setf (isled-work-data-question work) "Changed question?")
    (should-not (isled-rows-heading-matches-p row issue))
    (let* ((heading (isled-sections--heading issue))
           (position (string-match "Question" heading)))
      (should (equal (get-text-property position 'help-echo heading) "Changed question?"))
      (should (eq (get-text-property position 'face heading) 'isled-issue-work-face)))))

(ert-deftest isled-work-actions-roundtrip-through-the-real-cli ()
  (let* ((directory (make-temp-file "isled-work-test-" t))
         (isled-program (or isled-test-program
                            (expand-file-name "target/debug/isled" default-directory))))
    (unwind-protect
        (progn
          (should (zerop (call-process isled-program nil nil nil "--root" directory "init")))
          (should (zerop (call-process isled-program nil nil nil "--root" directory
                                      "add" "Track work" "A concern." "--kind" "feature")))
          (with-temp-buffer
            (setq major-mode 'isled-mode)
            (setq-local isled--root directory)
            (let ((row (make-isled-row :issue (isled-issue-create :id "0001")))
                  (refreshes 0))
              (cl-letf (((symbol-function 'isled-row-at) (lambda (&rest _) row))
                        ((symbol-function 'isled-refresh) (lambda () (cl-incf refreshes))))
                (dolist (action (list #'isled-work-queue #'isled-work-start
                                     (lambda () (isled-work-await-clarification "Which target?"))))
                  (let ((expected (1+ refreshes)) (deadline (+ (float-time) 5)))
                    (funcall action)
                    (while (and (< refreshes expected) (< (float-time) deadline))
                      (accept-process-output nil 0.02))
                    (should (= refreshes expected)))))))
          (with-temp-buffer
            (should (zerop (call-process isled-program nil t nil "--root" directory "snapshot")))
            (let* ((snapshot (isled-snapshot-decode (buffer-string)))
                   (work (isled-issue-work (car (isled-snapshot-issues snapshot)))))
              (should (equal (isled-work-data-state work) "awaiting-owner"))
              (should (equal (isled-work-data-question work) "Which target?"))
              (should-not (isled-work-data-running-since work))
              (should (= (length (isled-work-data-spans work)) 1))
              (should (isled-work-span-stopped (car (isled-work-data-spans work)))))))
      (delete-directory directory t))))

(ert-deftest isled-work-current-summary-does-not-inherit-stale-detail-spans ()
  (let* ((current (isled-work-data-create :state "awaiting-owner" :reason "review"
                                         :recorded-seconds 2700))
         (summary (isled-issue-create :id "0042" :work current))
         (body (isled-issue-create :id "0042" :content "Retained body"
                                  :work (isled-work-data-decode (isled-work-test--wire) t)))
         (merged (isled-data--merge summary (isled-detail-create :id "0042" :issue body))))
    (should (eq (isled-issue-work merged) current))
    (should-not (isled-work-data-spans (isled-issue-work merged)))
    (should (equal (isled-issue-content merged) "Retained body"))))

(provide 'isled-work-test)
;;; isled-work-test.el ends here
