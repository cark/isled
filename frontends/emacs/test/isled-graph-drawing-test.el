;;; isled-graph-drawing-test.el --- Shared routing contract tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Check the accepted merge-then-split sketch and reject misleading shared routes.

;;; Code:
(require 'ert)
(require 'isled-graph-drawing)
(require 'isled-graph-glyphs)
(require 'isled-graph-test)

(defun isled-graph-drawing-test--semantic ()
  "Return five semantic rows with two shared prerequisites."
  (isled-graph--decode-plan
   '((lanes . 4)
     (rows . (((filtered_prerequisites . 0) (filtered_dependents . 0) (id . "0001") (lane . 0) (start . :json-null) (targets . (1 2)))
              ((filtered_prerequisites . 0) (filtered_dependents . 0) (id . "0002") (lane . 1) (start . 0) (targets . (3 4)))
              ((filtered_prerequisites . 0) (filtered_dependents . 0) (id . "0004") (lane . 2) (start . 0) (targets . (3 4)))
              ((filtered_prerequisites . 0) (filtered_dependents . 0) (id . "0008") (lane . 1) (start . 1) (targets . nil))
              ((filtered_prerequisites . 0) (filtered_dependents . 0) (id . "0005") (lane . 3) (start . 1) (targets . nil)))))))

(defun isled-graph-drawing-test--wire ()
  "Return sparse routing metadata for the accepted sketch."
  '((lanes . 4)
    (steps . (((row . 0) (lane . 0) (start . :json-null))
               ((row . 1) (lane . 2) (start . 0) (join . 3))
               ((row . 2) (lane . 1) (start . 0) (join . 3))
               ((row . :json-null) (lane . 2) (start . 1) (targets . (3 4)))
               ((row . 3) (lane . 3) (start . 3))
               ((row . 4) (lane . 2) (start . 3))))))

(defun isled-graph-drawing-test--plan ()
  "Return the complete shared drawing fixture."
  (let ((plan (isled-graph-drawing-test--semantic)))
    (setf (isled-graph-plan-drawing plan)
          (isled-graph-drawing-decode (isled-graph-drawing-test--wire) plan))
    plan))

(ert-deftest isled-graph-drawing-separates-the-shared-merge-and-split ()
  (let* ((plan (isled-graph-drawing-test--plan))
         (lines (cl-loop for index from 0 below 5
                         for glyphs = (isled-graph-glyphs-render plan index)
                         append (cons (string-trim-right (isled-graph-glyphs-heading glyphs))
                                      (when (isled-graph-glyphs-connector glyphs)
                                        (mapcar #'string-trim-right
                                                (split-string (isled-graph-glyphs-connector glyphs) "\n")))))))
    (should (equal lines '("○" "╰─┬─╮" "  │ ○" "  ○ │" "  ╰─┤" "    ├─╮" "    │ ○" "    ○")))
    (should (= (isled-graph-glyphs-line-count plan 2) 2))
    (should-not (string-match-p "[┼╪]" (string-join lines "\n")))))

(ert-deftest isled-graph-drawing-rejects-invented-dependencies-and-invalid-tracks ()
  (dolist (mutation '((3 targets (4)) (1 join 5) (3 start 0) (2 lane 2)
                      (4 row 4) (4 start 1) (3 targets (3 5))))
    (let* ((wire (copy-tree (isled-graph-drawing-test--wire)))
           (step (nth (car mutation) (alist-get 'steps wire))))
      (setf (alist-get (cadr mutation) step) (nth 2 mutation))
      (should-error (isled-graph-drawing-decode wire (isled-graph-drawing-test--semantic))
                    :type 'isled-snapshot-error))))

(ert-deftest isled-graph-drawing-retired-gutters-preserve-multiple-routing-lines ()
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
      (should (equal (substring-no-properties painted) " \n \n"))
      (should (string-match-p "╰─┤" (get-text-property start 'display)))
      (cl-letf (((symbol-function 'isled-windows-visible) (lambda () nil)))
        (isled-graph-gutter-update))
      (should-not (gethash row isled-graph-gutter--painted))
      (should (equal (buffer-substring-no-properties start end) " \n \n"))
      (should (= (length (get-text-property start 'display)) 1))
      (should (= (length (get-text-property (+ start 2) 'display)) 1))
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
                                                     (isled-row-content row)) " \n \n"))
      (should (= (overlay-end (isled-row-heading-background row)) (1- (isled-row-heading-end row))))
      (should (= (overlay-start (isled-row-fold row)) (isled-row-content row)))
      (should (= (isled-row-end row) (isled-row-start next)))
      (should (eq (isled-row-at (isled-row-heading-end row)) row))
      (isled-sections-hide row)
      (should-not (invisible-p (isled-row-heading-end row)))
      (should (invisible-p (isled-row-content row))))))

(provide 'isled-graph-drawing-test)
;;; isled-graph-drawing-test.el ends here
