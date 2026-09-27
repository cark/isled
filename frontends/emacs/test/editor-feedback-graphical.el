;;; editor-feedback-graphical.el --- Draft display and actual watch checks -*- lexical-binding: t; -*-
(require 'isled)
(require 'isled-editor)
(setq isled-use-development-cli t
      isled-program (getenv "ISLED_EDITOR_PROGRAM"))
(defvar isled-feedback-test-root (make-temp-file "isled-feedback-" t))
(defvar isled-feedback-test-view nil)
(defvar isled-feedback-test-draft nil)
(defvar isled-feedback-test-fields nil)
(defvar isled-feedback-test-deadline (+ (float-time) 15))

(defun isled-feedback-test-finish (error)
  (with-temp-file (getenv "ISLED_GRAPHICAL_RESULT")
    (insert (if error (format "failed: %S\n" error) "passed\n")))
  (kill-emacs (if error 1 0)))

(defun isled-feedback-test-step (stage)
  (condition-case failure
      (progn
        (when (> (float-time) isled-feedback-test-deadline) (error "Timed out at %s" stage))
        (pcase stage
          ('load
           (with-current-buffer isled-feedback-test-draft
             (if isled-editor-busy
                 (run-at-time 0.05 nil #'isled-feedback-test-step stage)
               (unless (isled-editor-record-version isled-editor-record) (error "No saved baseline"))
               (goto-char (widget-field-start (cdr (assoc "statement" isled-editor-fields))))
               (insert "Draft ")
               (setq isled-feedback-test-fields (isled-editor-form-draft))
               (kill-buffer isled-feedback-test-view)
               (unless (buffer-live-p (isled-session-owner isled-editor-session)) (error "Lost shared watch"))
               (unless (zerop (call-process isled-program nil nil nil "--root" isled-feedback-test-root
                                            "statement" "append" "0001" "External change"))
                 (error "External edit failed"))
               (run-at-time 0.1 nil #'isled-feedback-test-step 'changed))))
          ('changed
           (with-current-buffer isled-feedback-test-draft
             (if (not isled-editor-conflict)
                 (run-at-time 0.1 nil #'isled-feedback-test-step stage)
               (unless (equal isled-feedback-test-fields (isled-editor-form-draft)) (error "Watch replaced draft"))
               (unless (= (point) (+ 6 (widget-field-start (cdr (assoc "statement" isled-editor-fields)))))
                 (error "Watch moved point"))
               (unless (string-match-p "Changed on disk" (format "%S" (isled-editor-header)))
                 (error "Missing disk state"))
               (isled-editor-save)
               (run-at-time 0.05 nil #'isled-feedback-test-step 'save))))
          ('save
           (with-current-buffer isled-feedback-test-draft
             (if isled-editor-busy
                 (run-at-time 0.05 nil #'isled-feedback-test-step stage)
               (unless isled-editor-save-failed (error "Expected save conflict"))
               (unless (= (point) (+ 6 (widget-field-start (cdr (assoc "statement" isled-editor-fields)))))
                 (error "Save conflict moved point"))
               (redisplay t)
               (when-let ((file (getenv "ISLED_EDITOR_SCREENSHOT")))
                 (with-temp-file file
                   (set-buffer-multibyte nil)
                   (insert (x-export-frames nil 'png))))
               (set-buffer-modified-p nil)
               (kill-buffer (current-buffer))
               (when (gethash isled-feedback-test-root isled-session--sessions) (error "Watch leaked"))
               (delete-directory isled-feedback-test-root t)
               (isled-feedback-test-finish nil))))))
    (error (isled-feedback-test-finish failure))))

(condition-case failure
    (progn
      (set-frame-size (selected-frame) 120 45)
      (call-process isled-program nil nil nil "--root" isled-feedback-test-root "init")
      (call-process isled-program nil nil nil "--root" isled-feedback-test-root "add" "Watched issue"
                    "--kind" "task" "Saved statement")
      (setq isled-feedback-test-view (isled isled-feedback-test-root))
      (with-current-buffer isled-feedback-test-view
        (setq isled-feedback-test-draft (isled-editor-open isled-feedback-test-root nil)))
      (unless (= (window-point (selected-window))
                 (with-current-buffer isled-feedback-test-draft
                   (widget-field-start (cdr (assoc "title" isled-editor-fields)))))
        (error "New draft did not select Title"))
      (delete-other-windows)
      (with-current-buffer isled-feedback-test-draft
        (goto-char (widget-field-start (cdr (assoc "statement" isled-editor-fields))))
        (isled-editor-form-highlight)
        (isled-editor-form-statement-height)
        (redisplay t)
        (unless (<= (cdr (posn-object-width-height (posn-at-point)))
                    (* 1.5 (frame-char-height)))
          (error "Statement cursor row is oversized"))
        (let* ((widget (cdr (assoc "statement" isled-editor-fields)))
               (start (posn-at-point (widget-field-start widget)))
               (after (posn-at-point (+ 1 (widget-field-end widget)))))
          (unless (and start after (>= (- (cdr (posn-x-y after)) (cdr (posn-x-y start)))
                                      (* 3 (frame-char-height))))
            (error "Empty Statement is not three lines tall: %S %S" start after)))
        (setq isled-editor-record (isled-editor-record-create :id "0001" :status "loading"))
        (isled-editor-load "0001"))
      (run-at-time 0.05 nil #'isled-feedback-test-step 'load))
  (error (isled-feedback-test-finish failure)))
