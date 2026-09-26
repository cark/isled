;;; isled-row-update-test.el --- Stable incremental text checks  -*- lexical-binding: t; -*-

;;; Commentary:

;; Unchanged rows and external markers survive a neighboring detail update.

;;; Code:

(require 'ert)
(require 'isled-browser)
(require 'isled-view-test)

(ert-deftest isled-row-update-preserves-unaffected-body-and-markers ()
  (with-temp-buffer
    (isled-mode)
    (let* ((snapshot (isled-view-test--snapshot))
           (expanded '("0001" "0002"))
           (inhibit-read-only t))
      (isled-sections-render snapshot 'all expanded)
      (let* ((row (gethash "0002" isled-rows-index))
             (overlay (isled-row-heading-background row))
             (marker (copy-marker (isled-row-content row)))
             (original (symbol-function 'isled-sections--materialize))
             updates)
        (unwind-protect
            (progn
              (setf (isled-issue-content (car (isled-snapshot-issues snapshot)))
                    "# Replacement\n\nA longer replacement body.\n"
                    (isled-issue-references (car (isled-snapshot-issues snapshot))) nil)
              (cl-letf (((symbol-function 'isled-sections--materialize)
                         (lambda (changed) (push (isled-row-value changed) updates)
                           (funcall original changed))))
                (isled-sections-render snapshot 'all expanded))
              (should (equal updates '("0001")))
              (should (eq row (gethash "0002" isled-rows-index)))
              (should (eq overlay (isled-row-heading-background row)))
              (should (= marker (isled-row-content row)))
              (let ((tick (buffer-chars-modified-tick)))
                (isled-sections-render snapshot 'all expanded)
                (should (= tick (buffer-chars-modified-tick)))))
          (set-marker marker nil))))))

(provide 'isled-row-update-test)
;;; isled-row-update-test.el ends here
