;;; isled-buffers-test.el --- Independent view creation -*- lexical-binding: t; -*-

;;; Commentary:
;; Exercise duplication through public commands with isolated view buffers.
;;; Code:
(require 'ert)
(require 'isled-browser)
(require 'isled-view-test)

(ert-deftest isled-duplicate-display-splits-below-automatic-thresholds ()
  (save-window-excursion
    (delete-other-windows)
    (let* ((left (selected-window))
           (left-buffer (window-buffer left))
           (right (split-window-right))
           (source (generate-new-buffer " *split-source*"))
           (duplicate (generate-new-buffer " *split-duplicate*"))
           (split-window-preferred-function #'split-window-sensibly)
           (split-height-threshold 80)
           (split-width-threshold 160))
      (unwind-protect
          (progn
            (select-window right)
            (switch-to-buffer source)
            (should-not (split-window-sensibly right))
            (isled-buffers--display duplicate)
            (should (= (length (window-list)) 3))
            (should (eq (window-buffer left) left-buffer))
            (should (eq (window-buffer right) source))
            (should (eq (window-buffer) duplicate))
            (should-not (eq (selected-window) right))
            (should (= split-height-threshold 80))
            (should (= split-width-threshold 160)))
        (kill-buffer source)
        (kill-buffer duplicate)))))

(ert-deftest isled-duplicate-display-falls-back-when-too-small ()
  (save-window-excursion
    (let ((duplicate (generate-new-buffer " *small-duplicate*"))
          (window (selected-window))
          (split-window-preferred-function #'split-window-sensibly)
          (window-min-height (frame-height))
          (window-min-width (frame-width)))
      (unwind-protect
          (progn
            (isled-buffers--display duplicate)
            (should (eq (selected-window) window))
            (should (eq (window-buffer) duplicate)))
        (kill-buffer duplicate)))))

(ert-deftest isled-duplicate-shares-data-with-independent-folding ()
  (save-window-excursion
    (let ((source (generate-new-buffer " *duplicate-source*")) duplicate
          (isled-auto-revert nil))
      (unwind-protect
          (progn
            (switch-to-buffer source)
            (isled-mode)
            (setq isled--root "/tmp/example"
                  isled-loading-filter 'open isled-loading-intent 'open
                  isled-data-view (isled-view-test--open-snapshot "0001" "0002"))
            (isled-session-attach)
            (setq isled--snapshot
                  (isled-data-accept
                   (isled-response-create :root isled--root :view isled-data-view)))
            (isled--render)
            (isled-sections-goto-id "0002")
            (isled--toggle-issue)
            (set-window-dedicated-p (selected-window) t)
            (cl-letf (((symbol-function 'split-window-sensibly) (lambda (&rest _) nil)))
              (setq duplicate (isled-duplicate-view)))
            (should (eq (window-buffer) duplicate))
            (should (window-dedicated-p))
            (should (equal (isled-sections-point-state) '("0002" . 0)))
            (should (equal (isled-sections-expanded-ids) '("0002")))
            (should (eq isled-data-details (buffer-local-value 'isled-data-details source)))
            (should-not (eq isled-data-view (buffer-local-value 'isled-data-view source)))
            (isled-collapse-all)
            (with-current-buffer source
              (should (equal (isled-sections-expanded-ids) '("0002"))))
            (kill-buffer source)
            (should (buffer-live-p duplicate))
            (should (= (length (isled-session-views isled-session)) 1)))
        (dolist (view (list source duplicate)) (when (buffer-live-p view) (kill-buffer view)))))))

(provide 'isled-buffers-test)
;;; isled-buffers-test.el ends here
