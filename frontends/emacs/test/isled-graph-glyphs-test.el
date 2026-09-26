;;; isled-graph-glyphs-test.el --- Dependency routing geometry tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Small inspectable graphs exercise directional junctions and non-joining crossings.

;;; Code:
(require 'ert)
(require 'isled-graph-glyphs)

(ert-deftest isled-graph-glyphs-route-corners-crossings-and-shared-targets ()
  (let* ((plan (isled-graph--decode-plan
                '((lanes . 3)
                  (rows . (((filtered_prerequisites . 0) (filtered_dependents . 0) (id . "0001") (lane . 0) (start . :json-null) (targets . (1 2)))
                           ((filtered_prerequisites . 0) (filtered_dependents . 0) (id . "0002") (lane . 0) (start . 0) (targets . (3)))
                           ((filtered_prerequisites . 0) (filtered_dependents . 0) (id . "0003") (lane . 1) (start . 0) (targets . (4)))
                           ((filtered_prerequisites . 0) (filtered_dependents . 0) (id . "0004") (lane . 2) (start . 1) (targets . (4)))
                           ((filtered_prerequisites . 0) (filtered_dependents . 0) (id . "0005") (lane . 0) (start . 2) (targets . nil)))))))
         (expected '(("○      " "├─╮    " "│ │    ")
                     ("○ │    " "╰───╮  " "  │ │  ")
                     ("  ○ │  " "╭─╯ │  " "│   │  ")
                     ("│   ○  " "├───╯  " "│      ")
                     ("○      " nil "       "))))
    (cl-loop for index from 0 for lines in expected
             for glyphs = (isled-graph-glyphs-render plan index)
             do (should (equal (list (isled-graph-glyphs-heading glyphs)
                                    (isled-graph-glyphs-connector glyphs)
                                    (isled-graph-glyphs-continuing glyphs)) lines)))))

(ert-deftest isled-graph-glyphs-join-existing-tracks-on-both-sides ()
  (let* ((plan (isled-graph--decode-plan
                '((lanes . 3)
                  (rows . (((filtered_prerequisites . 0) (filtered_dependents . 0) (id . "0001") (lane . 0) (start . :json-null) (targets . (1 2 3)))
                           ((filtered_prerequisites . 0) (filtered_dependents . 0) (id . "0002") (lane . 1) (start . 0) (targets . (2 3)))
                           ((filtered_prerequisites . 0) (filtered_dependents . 0) (id . "0003") (lane . 0) (start . 0) (targets . nil))
                           ((filtered_prerequisites . 0) (filtered_dependents . 0) (id . "0004") (lane . 2) (start . 0) (targets . nil)))))))
         (root (isled-graph-glyphs-render plan 0))
         (join (isled-graph-glyphs-render plan 1)))
    (should (equal (isled-graph-glyphs-connector root) "├─┬─╮  "))
    (should (equal (isled-graph-glyphs-heading join) "│ ○ │  "))
    (should (equal (isled-graph-glyphs-connector join) "├─┤ │  \n│ ╰─┤  "))))

(ert-deftest isled-graph-glyphs-compact-chain-reserves-first-column-for-starts ()
  (let* ((plan (isled-graph--decode-plan
                '((lanes . 2)
                  (rows . (((filtered_prerequisites . 0) (filtered_dependents . 0) (id . "0001") (lane . 0) (start . :json-null) (targets . nil))
                           ((filtered_prerequisites . 0) (filtered_dependents . 0) (id . "0002") (lane . 0) (start . :json-null) (targets . (2)))
                           ((filtered_prerequisites . 0) (filtered_dependents . 0) (id . "0003") (lane . 1) (start . 1) (targets . (3)))
                           ((filtered_prerequisites . 0) (filtered_dependents . 0) (id . "0004") (lane . 1) (start . 2) (targets . nil))
                           ((filtered_prerequisites . 0) (filtered_dependents . 0) (id . "0005") (lane . 0) (start . :json-null) (targets . nil)))))))
         (expected '(("•    " nil "     ")
                     ("○    " "╰─╮  " "  │  ")
                     ("  ○  " nil "  │  ")
                     ("  ○  " nil "     ")
                     ("•    " nil "     "))))
    (cl-loop for index from 0 for lines in expected
             for glyphs = (isled-graph-glyphs-render plan index)
             do (should (equal (list (isled-graph-glyphs-heading glyphs)
                                    (isled-graph-glyphs-connector glyphs)
                                    (isled-graph-glyphs-continuing glyphs)) lines)))))

(provide 'isled-graph-glyphs-test)
;;; isled-graph-glyphs-test.el ends here
