;;; isled-view-test.el --- View tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused ERT coverage for filtering, selection, and rendering.

;;; Code:

(require 'ert)

(let ((test-directory
       (file-name-directory (or load-file-name buffer-file-name))))
  (add-to-list 'load-path test-directory)
  (add-to-list 'load-path
               (file-name-directory (directory-file-name test-directory))))

(require 'isled-snapshot-test)
(require 'isled-view)

(defun isled-view-test--snapshot ()
  "Return the standard test snapshot."
  (isled-snapshot-decode
   (isled-test--fixture "snapshot-v5.json")))

(defun isled-view-test--open-snapshot (&rest ids)
  "Return a snapshot containing one open issue for every ID in IDS."
  (isled-snapshot-create
   :root "/tmp/example"
   :issues
   (mapcar
    (lambda (id)
      (isled-issue-create
       :id id
       :status "open"
       :ready t
       :kind "feature"
       :title (format "Issue %s" id)
       :path (format "/tmp/example/.issues/%s-issue.md" id)
       :content (format "# %s — Issue %s\n\nBody %s.\n" id id id)
       :references nil))
    ids)))

(ert-deftest isled-view-filters-open-and-closed ()
  (let ((snapshot (isled-view-test--snapshot)))
    (should (equal
             (mapcar #'isled-issue-id
                     (isled-view-visible-issues snapshot 'open))
             '("0001")))
    (should (equal
             (mapcar #'isled-issue-id
                     (isled-view-visible-issues snapshot 'closed))
             '("0002")))))

(ert-deftest isled-view-selection-retains-or-falls-back ()
  (let ((issues (isled-snapshot-issues
                 (isled-view-test--snapshot))))
    (should (equal (isled-view-select-id issues "0002") "0002"))
    (should (equal (isled-view-select-id issues "9999") "0001"))
    (should-not (isled-view-select-id nil "0001"))))

(ert-deftest isled-view-replacement-prefers-successor-then-predecessor ()
  (let ((issues
         (isled-snapshot-issues
          (isled-view-test--open-snapshot
           "0001" "0003" "0005"))))
    (should (equal (isled-view-replacement-id issues "0002")
                   "0003"))
    (should (equal (isled-view-replacement-id issues "0003")
                   "0005"))
    (should (equal (isled-view-replacement-id issues "0006")
                   "0005"))
    (should-not (isled-view-replacement-id nil "0001"))))

(provide 'isled-view-test)
;;; isled-view-test.el ends here
