;;; bookmark-activities-graphical.el --- Optional Activities restore check -*- lexical-binding: t; -*-

;;; Commentary:
;; Run with the private graphical runner and explicit Activities dependencies.
;;; Code:
(setq load-prefer-newer t)
(require 'isled-bookmark-test)
(require 'activities)
(require 'activities-tabs)
(setq isled-test-program (getenv "ISLED_TEST_PROGRAM"))

(defun isled-bookmark-activities--views ()
  "Return the two displayed Isled buffers, or nil while restoring."
  (let ((buffers (mapcar #'window-buffer (window-list))))
    (and (= (length buffers) 2)
         (seq-every-p (lambda (buffer)
                       (with-current-buffer buffer (derived-mode-p 'isled-mode))) buffers)
         buffers)))

(defun isled-bookmark-activities--check ()
  "Check independent filters, folds and cursor positions in the restored layout."
  (isled-native-refresh--wait "Activities layout" #'isled-bookmark-activities--views)
  (dolist (buffer (isled-bookmark-activities--views))
    (isled-bookmark-test--wait buffer))
  (dolist (window (window-list))
    (with-selected-window window
      (let ((id (if (eq isled--filter 'open) "0001" "0002")))
        (should (memq isled--filter '(open all)))
        (should (equal (isled-sections-expanded-ids) (list id)))
        (should (equal (isled-sections-point-state) (cons id 2)))))))

(defun isled-bookmark-activities-run ()
  "Save and restore two independent views through Activities."
  (condition-case failure
      (progn
        (let ((stats (ert-run-tests-batch
                      'isled-bookmark-restores-position-inside-an-expanded-body)))
          (unless (zerop (ert-stats-completed-unexpected stats))
            (error "Expanded body bookmark restoration failed")))
        (activities-mode 1)
        (activities-tabs-mode 1)
        (isled-bookmark-test--with-ledger
          (delete-other-windows)
          (let* ((first (isled-bookmark-test--save root "First" "0001"))
                 (second (isled-bookmark-test--save root "Second" "0002")))
            (isled-filter-all)
            (isled-bookmark-test--wait second)
            (isled-sections-goto-id "0002")
            (forward-char 2)
            (delete-other-windows)
            (switch-to-buffer first)
            (set-window-buffer (split-window-right) second)
            (with-selected-window (get-buffer-window second)
              (isled-sections-goto-id "0002") (forward-char 2))
            (activities-define "Issue views")
            (activities-save-all :persistp t)
            (activities-suspend (activities-named "Issue views"))
            (kill-buffer first)
            (kill-buffer second)
            (activities-resume (activities-named "Issue views"))
            (isled-bookmark-activities--check)
            (let ((restored (isled-bookmark-activities--views)))
              (activities-revert (activities-named "Issue views"))
              (isled-bookmark-activities--check)
              (should (seq-set-equal-p restored (isled-bookmark-activities--views))))))
        (with-temp-file (getenv "PI_RESULT") (insert "(:passed t)\n"))
        (kill-emacs 0))
    (error
     (with-temp-file (getenv "PI_RESULT") (insert (format "failed: %S\n" failure)))
     (kill-emacs 1))))

(run-at-time 0.2 nil #'isled-bookmark-activities-run)
;;; bookmark-activities-graphical.el ends here
