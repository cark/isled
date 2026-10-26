;;; isled-graph-glyphs-test.el --- Final glyph path tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Read the painted characters independently of the route representation.
;; Horizontal and vertical channels at a crossing must never exchange paths.

;;; Code:
(require 'ert)
(require 'isled-graph-glyphs)
(require 'isled-graph-fixtures)

(defun isled-graph-glyphs-test--lines (plan)
  "Return every physical glyph line painted for PLAN."
  (vconcat
   (cl-loop for index below (length (isled-graph-plan-rows plan))
            for glyphs = (isled-graph-glyphs-render plan index)
            append (cons (isled-graph-glyphs-heading glyphs)
                         (when (isled-graph-glyphs-connector glyphs)
                           (split-string (isled-graph-glyphs-connector glyphs) "\n"))))))

(defun isled-graph-glyphs-test--ports (glyph column)
  "Read GLYPH's ports independently; COLUMN zero nodes never connect vertically."
  (cond ((memq glyph '(?○ ?•)) (if (zerop column) '(east west) '(north east south west)))
        (t (cdr (assq glyph '((?\s) (?│ north south) (?─ west east)
                              (?╮ west south) (?╭ east south) (?╰ north east) (?╯ north west)
                              (?┬ west east south) (?┴ west east north)
                              (?├ north east south) (?┤ north west south)
                              (?╪ north south west east)))))))

(defun isled-graph-glyphs-test--neighbor (lines y x direction)
  "Find the neighboring cell in LINES from Y, X along DIRECTION."
  (let* ((ny (+ y (pcase direction ('north -1) ('south 1) (_ 0))))
         (nx (+ x (pcase direction ('west -1) ('east 1) (_ 0)))))
    (when (and (<= 0 ny) (< ny (length lines)) (<= 0 nx) (< nx (length (aref lines ny))))
      (cons ny nx))))

(defun isled-graph-glyphs-test--connected (lines y x direction)
  "Read a reciprocal connection from Y, X in LINES along DIRECTION."
  (let ((neighbor (isled-graph-glyphs-test--neighbor lines y x direction))
        (reverse (pcase direction ('north 'south) ('south 'north) ('west 'east) ('east 'west))))
    (when (and neighbor
               (memq reverse (isled-graph-glyphs-test--ports
                              (aref (aref lines (car neighbor)) (cdr neighbor)) (cdr neighbor))))
      neighbor)))

(defun isled-graph-glyphs-test--read (lines plan)
  "Verify LINES' ports and exact direct paths against PLAN's semantic edges."
  (let ((nodes (make-hash-table :test #'equal)) (row 0) (positions nil))
    (cl-loop for line across lines for y from 0 do
             (dotimes (x (length line))
               (let* ((glyph (aref line x)) (ports (isled-graph-glyphs-test--ports glyph x)))
                 (should (= (string-width (char-to-string glyph)) 1))
                 (should-not (= glyph ?┼))
                 (if (memq glyph '(?○ ?•))
                     (progn (push (cons y x) positions) (puthash (cons y x) row nodes) (setq row (1+ row)))
                   (unless (= glyph ?\s)
                     (should (or (memq 'north ports) (memq 'west ports)))
                     (should (or (memq 'east ports) (memq 'south ports)))
                     (dolist (direction ports)
                       (should (isled-graph-glyphs-test--connected lines y x direction))))))))
    (should (= row (length (isled-graph-plan-rows plan))))
    (cl-loop for position in (nreverse positions) for source from 0 do
             (let ((pending (list (list (car position) (cdr position) nil t)))
                   (seen (make-hash-table :test #'equal)) (found nil))
               (while pending
                 (pcase-let* ((`(,y ,x ,arrival ,start) (pop pending))
                              (key (list y x arrival))
                              (glyph (aref (aref lines y) x))
                              (node (gethash (cons y x) nodes)))
                   (unless (gethash key seen)
                     (puthash key t seen)
                     (if (and node (not start)) (cl-pushnew node found)
                       (dolist (direction (if (= glyph ?╪) (list arrival) '(east south)))
                         (when (memq direction (isled-graph-glyphs-test--ports glyph x))
                           (when-let* ((neighbor (isled-graph-glyphs-test--connected lines y x direction)))
                             (push (list (car neighbor) (cdr neighbor) direction nil) pending))))))))
               (should (equal (sort found #'<)
                              (isled-graph-row-targets (aref (isled-graph-plan-rows plan) source))))))))

(ert-deftest isled-graph-glyphs-case-library-preserves-exact-direct-paths ()
  (dolist (case (isled-graph-fixtures-cases))
    (ert-info ((format "%s %s" (alist-get 'case case) (alist-get 'direction case)))
      (let ((plan (isled-graph-fixtures-decode (alist-get 'plan case))))
        (isled-graph-glyphs-test--read (isled-graph-glyphs-test--lines plan) plan)))))

(ert-deftest isled-graph-glyphs-government-branches-and-shared-fork-stay-readable ()
  (dolist (case '(("government-cabinets" "○─┬─╮" "  │ ○─╮" "  │ │ ○" "  ○─┤ │" "    ○─┤" "      ○")
                  ("shared-set" "○─╮" "○─┤" "  ├─╮" "  │ ○" "  ○")
                  ("long-span" "○─┬─╮" "  │ ○" "  │ ○" "  │ ○" "  ╰─○")))
    (should (equal (mapcar #'string-trim-right
                          (append (isled-graph-glyphs-test--lines (isled-graph-fixtures-plan (car case))) nil))
                   (cdr case)))))

(ert-deftest isled-graph-glyphs-oracle-rejects-lost-crossing-and-invented-join ()
  (let* ((plan (isled-graph-fixtures-plan "overlapping-pairs"))
         (lines (isled-graph-glyphs-test--lines plan))
         (line (seq-position lines (seq-find (lambda (s) (string-match-p "╪" s)) lines)))
         (column (string-match "╪" (aref lines line))))
    (dolist (replacement '(?─ ?┼ ?\s))
      (let ((broken (vconcat (mapcar #'copy-sequence (append lines nil)))))
        (aset (aref broken line) column replacement)
        (should-error (isled-graph-glyphs-test--read broken plan))))))

(ert-deftest isled-graph-glyphs-crosses-between-consecutive-chain-nodes ()
  ;; Deliberately interleave two components to stress painting, not ordering.
  (let* ((lanes '(0 1 1 0 1 1 1 2))
         (targets '((1) (2) (4) (7) (5) (6) nil nil))
         (starts '(:json-null 0 1 :json-null 2 4 5 3))
         (wire `((lanes . 3)
                 (rows . ,(cl-loop for lane in lanes for to in targets for start in starts for i from 0
                                   collect `((id . ,(format "%04d" (1+ i))) (lane . ,lane)
                                             (start . ,start) (targets . ,to))))
                 (drawing . ((version . 1) (lanes . 3)
                             (steps . ,(cl-loop for lane in lanes for i from 0
                                               collect `((row . ,i) (lane . ,lane))))
                             (routes . ,(cl-loop for to in targets for source from 0 when to
                                                collect `((source . ,source) (target . ,(car to))
                                                          (lane . ,(nth (car to) lanes)))))))))
         (plan (isled-graph-fixtures-decode wire))
         (lines (isled-graph-glyphs-test--lines plan)))
    (should (equal (mapcar #'string-trim-right (append lines nil))
                   '("○─╮" "  ○" "  ○" "○─╪─╮" "  ○ │" "  ○ │" "  ○ │" "    ○")))
    (isled-graph-glyphs-test--read lines plan)))

(provide 'isled-graph-glyphs-test)
;;; isled-graph-glyphs-test.el ends here
