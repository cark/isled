;;; isled-fold-test.el --- Search reveal lifecycle  -*- lexical-binding: t; -*-

;;; Commentary:

;; Preview only exposes retained text; acceptance follows normal expansion.

;;; Code:

(require 'ert)
(require 'isled-browser)
(require 'isled-view-test)

(ert-deftest isled-fold-preview-does-not-expand-or-load ()
  (with-temp-buffer
    (isled-mode)
    (let ((inhibit-read-only t))
      (isled-sections-insert (isled-view-test--snapshot) 'all '("0001")))
    (let* ((row (aref isled-rows 0))
           (body (1+ (isled-row-content row)))
           scheduled)
      (isled-sections-hide row)
      (cl-letf (((symbol-function 'isled-loading-schedule)
                 (lambda () (setq scheduled t))))
        (isled-fold-preview (isled-row-fold row) nil)
        (isled-fold-update row)
        (should (isled-row-hidden row))
        (should-not (isled-sections-expanded-ids))
        (should-not (overlay-get (isled-row-fold row) 'invisible))
        (should-not scheduled)
        (isled-fold-preview (isled-row-fold row) t)
        (should (invisible-p body))
        (should-not scheduled)
        (isled-fold-open (isled-row-fold row))
        (should (equal (isled-sections-expanded-ids) '("0001")))
        (should scheduled)))))

(ert-deftest isled-fold-materialized-content-survives-collapse ()
  (with-temp-buffer
    (isled-mode)
    (let ((inhibit-read-only t))
      (isled-sections-insert (isled-view-test--snapshot) 'all nil))
    (let ((row (aref isled-rows 0)))
      (should-not (string-match-p "Body\\." (buffer-string)))
      (isled-sections-show row)
      (let ((text (buffer-string)))
        (isled-sections-hide row)
        (should (equal text (buffer-string))))
      (should (isled-row-materialized row)))))

(provide 'isled-fold-test)
;;; isled-fold-test.el ends here
