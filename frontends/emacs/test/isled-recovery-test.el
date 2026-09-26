;;; isled-recovery-test.el --- Recovery positioning tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Warning actions must retain issue identity, not obsolete generated offsets.

;;; Code:

(require 'ert)
(require 'isled-browser)
(require 'isled-view-test)

(defun isled-recovery-test--warning (target)
  "Return a missing-target warning for TARGET."
  (isled-warning-create
   :code "RELATION_MISSING" :message (concat "Missing " target)
   :source-id "0001" :target-id target :related-ids (list target)))

(ert-deftest isled-recovery-lands-on-warning-then-heading ()
  (with-temp-buffer
    (isled-mode)
    (let* ((snapshot (isled-view-test--snapshot))
           (issue (car (isled-snapshot-issues snapshot))))
      (setq isled--snapshot snapshot
            isled--root "/tmp/example"
            isled--selected-id "0001"
            isled--expanded-ids '("0001"))
      (setf (isled-issue-warnings issue)
            (list (isled-recovery-test--warning "0098")
                  (isled-recovery-test--warning "0099")))
      (isled--render)
      (search-forward "[Remove relation]")
      (backward-char 1)
      (cl-letf (((symbol-function 'isled--load-snapshot)
                 (lambda (_root) snapshot)))
        (setf (isled-issue-warnings issue)
              (cdr (isled-issue-warnings issue)))
        (isled--refresh-after-warning)
        (should (equal (isled-sections-id-at-point) "0001"))
        (should (equal (get-text-property (point) 'isled-warning-action)
                       '(remove "0001" "0099")))
        (setf (isled-issue-warnings issue) nil)
        (isled--refresh-after-warning)
        (should (looking-at-p "#0001"))
        (should (equal isled--selected-id "0001"))))))

(ert-deftest isled-recovery-keeps-window-anchor-and-clamps-at-start ()
  (save-window-excursion
    (with-temp-buffer
      (switch-to-buffer (current-buffer))
      (isled-mode)
      (setq isled--snapshot (isled-view-test--snapshot)
            isled--filter 'all
            isled--selected-id "0002"
            isled--expanded-ids '("0001" "0002"))
      (isled--render)
      (isled-sections-goto-id "0002")
      (let ((window (selected-window)))
        (set-window-start window (save-excursion (vertical-motion -2) (point)))
        (let ((anchors (isled--window-anchors "0002")))
          ;; Removing earlier content changes absolute positions, not the anchor.
          (setq isled--expanded-ids '("0002"))
          (isled--render)
          (isled--restore-window-anchors anchors)
          (should (equal (nth 1 (car (isled--window-anchors "0002"))) "0002"))
          ;; Not enough preceding text: clamp instead of manufacturing top space.
          (should (= (window-start window) (point-min)))
          (should (looking-at-p "#0002")))))))

(ert-deftest isled-recovery-keeps-heading-row-when-space-allows ()
  (save-window-excursion
    (with-temp-buffer
      (switch-to-buffer (current-buffer))
      (isled-mode)
      (setq isled--snapshot (isled-view-test--snapshot)
            isled--filter 'all
            isled--selected-id "0002"
            isled--expanded-ids '("0001" "0002"))
      (let ((first (car (isled-snapshot-issues isled--snapshot))))
        (setf (isled-issue-content first)
              (concat "# First\n\n" (apply #'concat (make-list 40 "Text.\n")))
              (isled-issue-references first) nil)
        (isled--render)
        (isled-sections-goto-id "0002")
        (set-window-start (selected-window)
                          (save-excursion (vertical-motion -2) (point)))
        (let ((anchors (isled--window-anchors "0002")))
          (setf (isled-issue-content first)
                (concat "# First\n\n" (apply #'concat (make-list 20 "Text.\n"))))
          (isled--render)
          (isled--restore-window-anchors anchors)
          (should (equal (nth 2 (car anchors))
                         (nth 2 (car (isled--window-anchors "0002"))))))))))

(ert-deftest isled-recovery-background-refresh-keeps-window-point ()
  (save-window-excursion
    (with-temp-buffer
      (let ((buffer (current-buffer))
            (other (selected-window))
            (window (split-window-right)))
        (set-window-buffer window buffer)
        (with-selected-window window
          (isled-mode)
          (setq isled--root "/tmp/example"
                isled--snapshot (isled-view-test--snapshot)
                isled--filter 'all
                isled--selected-id "0002"
                isled--expanded-ids '("0001" "0002"))
          (isled--render)
          (isled-sections-goto-id "0002")
          (set-window-point window (point)))
        (select-window other)
        (with-current-buffer buffer
          (let ((snapshot isled--snapshot))
            (cl-letf (((symbol-function 'isled--load-snapshot)
                       (lambda (_) snapshot)))
              (isled--refresh t)))
          (should (equal (isled-sections-id-at-point (window-point window))
                         "0002")))))))

(provide 'isled-recovery-test)
;;; isled-recovery-test.el ends here
