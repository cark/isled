;;; isled-graph-drawing-test.el --- Shared routing contract tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Check the accepted merge-then-split sketch and reject misleading shared routes.

;;; Code:
(require 'ert)
(require 'isled-graph-drawing)
(require 'isled-graph-glyphs)
(require 'isled-graph-test)

(require 'isled-graph-fixtures)

(defun isled-graph-drawing-test--plan ()
  "Return the complete shared drawing fixture."
  (isled-graph-fixtures-plan "shared-after-fork"))

(ert-deftest isled-graph-drawing-rejects-legacy-or-corrupt-geometry ()
  (dolist (mutation '((version 99) (version nil) (lanes 1)))
    (let* ((wire (isled-graph-fixtures-wire "shared-after-fork"))
           (drawing (alist-get 'drawing wire)))
      (setf (alist-get (car mutation) drawing) (cadr mutation))
      (should-error (isled-graph-fixtures-decode wire) :type 'isled-snapshot-error)))
  (dolist (mutation '((0 source 1) (0 target 4) (0 lane 0) (1 lane 2)))
    (let* ((wire (isled-graph-fixtures-wire "diamond"))
           (route (nth (car mutation) (alist-get 'routes (alist-get 'drawing wire)))))
      (setf (alist-get (cadr mutation) route) (nth 2 mutation))
      (should-error (isled-graph-fixtures-decode wire) :type 'isled-snapshot-error))))

(ert-deftest isled-graph-drawing-retired-gutters-preserve-routing-lines ()
  (isled-loading-test--with-displayed-buffer
    (isled-mode)
    (setq isled--snapshot (isled-view-test--open-snapshot "0001" "0002" "0004" "0008" "0005")
          isled-graph-direction 'prerequisites
          isled-graph-layout (isled-graph-drawing-test--plan))
    (isled--render)
    (cl-letf (((symbol-function 'isled-windows-visible) (lambda () (list (selected-window)))))
      (isled-graph-gutter-update))
    (let* ((row (aref isled-rows 2))
           (start (isled-row-heading-end row))
           (end (isled-row-content row))
           (painted (buffer-substring start end))
           (tick (buffer-chars-modified-tick)))
      (should (equal (substring-no-properties painted) " \n"))
      (should (string-match-p "├─╮" (get-text-property start 'display)))
      (cl-letf (((symbol-function 'isled-windows-visible) (lambda () nil)))
        (isled-graph-gutter-update))
      (should-not (gethash row isled-graph-gutter--painted))
      (should (equal (buffer-substring-no-properties start end) " \n"))
      (should (= (length (get-text-property start 'display)) 1))
      (cl-letf (((symbol-function 'isled-windows-visible) (lambda () (list (selected-window)))))
        (isled-graph-gutter-update))
      (should (equal-including-properties (buffer-substring start end) painted))
      (should (= tick (buffer-chars-modified-tick))))))

(ert-deftest isled-graph-drawing-routing-survives-heading-and-body-edits ()
  (with-temp-buffer
    (isled-mode)
    (setq isled--snapshot (isled-view-test--open-snapshot "0001" "0002" "0004" "0008" "0005")
          isled-graph-direction 'prerequisites
          isled-graph-hash "0000000000000001"
          isled-graph-layout (isled-graph-drawing-test--plan))
    (isled--render)
    (let* ((row (aref isled-rows 2))
           (next (aref isled-rows 3))
           (issue (isled-row-issue row))
           (inhibit-read-only t))
      (setf (isled-issue-title issue) "A much longer replacement title"
            (isled-issue-content issue) "## Statement\n\nReplacement body.\n")
      (isled-sections-render isled--snapshot 'open '("0004"))
      (should (eq row (aref isled-rows 2)))
      (should (string-match-p "replacement title\n\\'"
                             (buffer-substring-no-properties (isled-row-start row)
                                                             (isled-row-heading-end row))))
      (should (equal (buffer-substring-no-properties (isled-row-heading-end row)
                                                     (isled-row-content row)) " \n"))
      (should (= (overlay-end (isled-row-heading-background row)) (1- (isled-row-heading-end row))))
      (should (= (overlay-start (isled-row-fold row)) (isled-row-content row)))
      (should (= (isled-row-end row) (isled-row-start next)))
      (should (eq (isled-row-at (isled-row-heading-end row)) row))
      (isled-sections-hide row)
      (should-not (invisible-p (isled-row-heading-end row)))
      (should (invisible-p (isled-row-content row))))))

(ert-deftest isled-graph-drawing-keeps-a-needed-merge-line-before-the-fork ()
  (let* ((plan (isled-graph-fixtures-plan "shared-with-separate-merge"))
         (index (gethash "0004" (isled-graph-plan-index plan))))
    (should (= (isled-graph-glyphs-line-count plan index) 2))
    (should (= (length (split-string (isled-graph-glyphs-connector
                                      (isled-graph-glyphs-render plan index)) "\n")) 2))))

(provide 'isled-graph-drawing-test)
;;; isled-graph-drawing-test.el ends here
