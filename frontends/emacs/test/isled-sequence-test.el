;;; isled-sequence-test.el --- Indexed list invariants  -*- lexical-binding: t; -*-

;;; Commentary:

;; Removal preserves successor indexing and does not mutate the input list.

;;; Code:

(require 'ert)
(require 'isled-sequence)

(ert-deftest isled-sequence-removes-boundaries-without-losing-successors ()
  (let* ((issues (cl-loop for n from 1 to 4 collect
                           (isled-issue-create :id (format "%04d" n))))
         (sequence (isled-sequence-index issues)))
    (dolist (id '("0001" "0003" "0004")) (isled-sequence-remove sequence id))
    (should (equal (mapcar #'isled-issue-id (isled-sequence-list sequence))
                   '("0002")))
    (should (eq (isled-sequence-get sequence "0002") (nth 1 issues)))
    (isled-sequence-remove sequence "0002")
    (should-not (isled-sequence-list sequence))
    (should (= (length issues) 4))))

(provide 'isled-sequence-test)
;;; isled-sequence-test.el ends here
