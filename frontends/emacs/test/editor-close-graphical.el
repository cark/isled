;;; editor-close-graphical.el --- Real graphical close/save/return check -*- lexical-binding: t; -*-
(require 'isled)
(require 'isled-editor)
(setq isled-use-development-cli t
      isled-program (getenv "ISLED_EDITOR_PROGRAM"))
(defvar isled-close-test-root (make-temp-file "isled-close-test-" t))
(defvar isled-close-test-view nil)
(defvar isled-close-test-editor nil)
(defvar isled-close-test-deadline (+ (float-time) 12))
(defun isled-close-test-step (stage)
  (condition-case failure
      (progn
        (when (> (float-time) isled-close-test-deadline) (error "Close test timed out: %s" stage))
        (pcase stage
          ('view
           (with-current-buffer isled-close-test-view
             (if (not isled-data-view)
                 (run-at-time 0.05 nil #'isled-close-test-step stage)
               (isled--visit-issue (isled-issue-create :id "0001" :status "open"))
               (call-interactively (key-binding (kbd "c")))
               (setq isled-close-test-editor (window-buffer (selected-window)))
               (run-at-time 0.05 nil #'isled-close-test-step 'draft))))
          ('draft
           (with-current-buffer isled-close-test-editor
             (if isled-editor-busy
                 (run-at-time 0.05 nil #'isled-close-test-step stage)
               (unless isled-editor-closing (error "Close key did not retain intent"))
               (let ((widget (cdr (assoc "outcome" isled-editor-fields))))
                 (unless (= (point) (widget-field-start widget)) (error "Close did not focus Outcome"))
                 (delete-region (widget-field-start widget) (widget-field-end widget))
                 (insert "Completed."))
               (call-interactively (key-binding (kbd "C-c C-c")))
               (run-at-time 0.05 nil #'isled-close-test-step 'saved))))
          ('saved
           (if (buffer-live-p isled-close-test-editor)
               (run-at-time 0.05 nil #'isled-close-test-step stage)
             (unless (eq (window-buffer (selected-window)) isled-close-test-view)
               (error "Save and close did not return to ledger"))
             (with-temp-buffer
               (unless (zerop (call-process isled-program nil t nil "--root" isled-close-test-root "show" "0001"))
                 (error "Cannot inspect closed record"))
               (unless (string-match-p "Status:\\*\\* closed" (buffer-string)) (error "Record was not closed")))
             (kill-buffer isled-close-test-view)
             (delete-directory isled-close-test-root t)
             (with-temp-file (getenv "ISLED_GRAPHICAL_RESULT") (insert "passed\n"))
             (kill-emacs 0)))))
    (error
     (with-temp-file (getenv "ISLED_GRAPHICAL_RESULT") (insert (format "failed: %S\n" failure)))
     (kill-emacs 1))))
(call-process isled-program nil nil nil "--root" isled-close-test-root "init")
(call-process isled-program nil nil nil "--root" isled-close-test-root "add" "Closure preview" "--kind" "task" "Statement.")
(call-process isled-program nil nil nil "--root" isled-close-test-root "evidence" "add" "0001" "Verified.")
(setq isled-close-test-view (isled isled-close-test-root))
(run-at-time 0.05 nil #'isled-close-test-step 'view)
