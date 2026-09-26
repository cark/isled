;;; isled-data-test.el --- Retained projection checks  -*- lexical-binding: t; -*-

;;; Commentary:

;; Check bounded detail work and recovery without depending on renderer internals.

;;; Code:

(require 'ert)
(require 'isled-data)

(defun isled-data-test--view (count)
  "Return a full typed view containing COUNT simple summaries."
  (isled-response-create
   :root "/tmp/example" :view-hash "0000000000000001"
   :view (isled-snapshot-create
          :root "/tmp/example"
          :issues (cl-loop for n from 1 to count collect
                           (isled-issue-create
                            :id (format "%04d" n) :title "Fixture"
                            :kind "feature" :status "open")))))

(defun isled-data-test--detail (id type &optional title)
  "Return typed detail ID of TYPE, with optional TITLE for valid issues."
  (isled-response-create
   :root "/tmp/example"
   :changes (list (isled-detail-create
                   :id id :hash "0000000000000002" :type type
                   :issue (when (eq type 'issue)
                            (isled-issue-create
                             :id id :title (or title "Updated") :kind "feature"
                             :status "open" :content "# Updated\n"))
                   :unavailable (when (eq type 'problem)
                                  (list (isled-unavailable-create
                                         :id id :path "/tmp/example/.issues/fixture.md"
                                         :error "Unreadable fixture")))))))

(ert-deftest isled-data-details-touch-only-requested-identity ()
  (dolist (size '(100 1000 5000))
    (with-temp-buffer
      (let* ((snapshot (isled-data-accept (isled-data-test--view size)))
             (spine (isled-snapshot-issues snapshot))
             (tail (last spine))
             (targets (isled-snapshot-targets snapshot))
             (update (symbol-function 'isled-data--update))
             visited)
        (cl-letf (((symbol-function 'isled-data-snapshot)
                   (lambda () (ert-fail "Detail reply rebuilt the full snapshot")))
                  ((symbol-function 'isled-data--update)
                   (lambda (id rows invalid)
                     (push id visited) (funcall update id rows invalid))))
          (should (eq snapshot (isled-data-accept
                                (isled-data-test--detail "0001" 'issue)))))
        (should (equal visited '("0001")))
        (should (eq spine (isled-snapshot-issues snapshot)))
        (should (eq tail (last (isled-snapshot-issues snapshot))))
        (should (eq targets (isled-snapshot-targets snapshot)))))))

(ert-deftest isled-data-full-view-establishes-recovered-membership ()
  (dolist (type '(deleted problem))
    (with-temp-buffer
      (isled-data-accept (isled-data-test--view 3))
      (isled-data-accept (isled-data-test--detail "0002" type))
      (should (equal (mapcar #'isled-issue-id
                            (isled-snapshot-issues isled-data--projection))
                     '("0001" "0003")))
      (should (eq (not (null (isled-snapshot-unavailable isled-data--projection)))
                  (eq type 'problem)))
      ;; Targeted recovery refreshes metadata but cannot invent filter membership.
      (isled-data-accept (isled-data-test--detail "0002" 'issue "Recovered"))
      (should (= 2 (length (isled-snapshot-issues isled-data--projection))))
      (let ((snapshot (isled-data-accept (isled-data-test--view 3))))
        (should (= 3 (length (isled-snapshot-issues snapshot))))
        (should-not (isled-snapshot-unavailable snapshot))
        (should (equal (isled-issue-content
                        (gethash "0002" (isled-snapshot-targets snapshot)))
                       "# Updated\n"))))))

(provide 'isled-data-test)
;;; isled-data-test.el ends here
