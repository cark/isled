;;; isled-auto-refresh-integration-test.el --- Native refresh tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Change disposable ledger files without Isled mutations, then wait for the
;; normal OS watch or Auto Revert fallback to update a real CLI-backed view.

;;; Code:

(require 'ert)
(require 'isled-browser)
(defvar isled-test-program)

(defun isled-native-refresh--wait (phase predicate)
  "Wait at most ten seconds for PREDICATE during PHASE.
An untimed `read-event' lets Emacs enter idle and dispatch real notifications,
process replies and idle timers.  The observer timer never requests refresh."
  (let ((tag (make-symbol "isled-native-refresh-ready")) timer)
    (unwind-protect
        (catch tag
          (setq timer (run-at-time
                       0.02 0.02
                       (lambda () (when (funcall predicate) (throw tag t)))))
          (with-timeout (10 (ert-fail (format "Native refresh timed out: %s (%s)"
                                             phase file-notify--library)))
            (while t (read-event))))
      (when timer (cancel-timer timer)))))

(defun isled-native-refresh--settled-p (view)
  "Return whether VIEW has loaded and its normal request queue is idle."
  (with-current-buffer view
    (and isled-data-view isled-session
         (not isled-loading-running) (not isled-loading-pending)
         (not (isled-session-running isled-session))
         (not (isled-session-queue isled-session))
         (not isled--auto-revert-error)
         (when-let ((owner (isled-session-owner isled-session)))
           (and (buffer-live-p owner)
                (not (buffer-local-value 'isled--notification-timer owner)))))))

(defun isled-native-refresh--issue (view id)
  "Return ID's currently displayed issue summary in VIEW."
  (with-current-buffer view
    (seq-find (lambda (issue) (equal id (isled-issue-id issue)))
              (and isled-data-view (isled-snapshot-issues isled-data-view)))))

(defun isled-native-refresh--write (path text)
  "Write TEXT directly to PATH, without visiting it or notifying Isled."
  (let ((coding-system-for-write 'utf-8-unix))
    (with-temp-buffer
      (insert text)
      (write-region (point-min) (point-max) path nil 'silent))))

(ert-deftest isled-auto-refresh-observes-native-filesystem-changes ()
  (should (and isled-test-program (file-executable-p isled-test-program)))
  (let* ((root (file-truename (make-temp-file "isled-native-refresh-" t)))
         (first (expand-file-name ".issues/0001-first.md" root))
         (second (expand-file-name ".issues/0002-second.md" root))
         (renamed (expand-file-name ".issues/0002-renamed.md" root))
         (replacement (expand-file-name ".issues/.replacement" root))
         (isled-program isled-test-program)
         (isled-process-function #'isled-process-start)
         (isled-auto-revert t)
         (auto-revert-interval 0.2)
         view session owner descriptor original)
    (unwind-protect
        (save-window-excursion
          (dolist (arguments '(("init") ("add" "First" "--kind" "task" "Original body.")))
            (let ((result (isled-snapshot--run-process root arguments)))
              (ert-info ((isled-command-result-stderr result))
                (should (zerop (isled-command-result-status result))))))
          (setq original (with-temp-buffer (insert-file-contents first) (buffer-string))
                view (isled-buffers-open root root nil root))
          (isled-native-refresh--wait
           "initial reconciliation" (lambda () (isled-native-refresh--settled-p view)))
          (setq session (buffer-local-value 'isled-session view)
                owner (isled-session-owner session)
                descriptor (buffer-local-value 'isled--notification-watch owner))
          (with-current-buffer owner
            (if (memq file-notify--library '(nil kqueue))
                (progn (should auto-revert-mode) (should-not descriptor))
              (should (file-notify-valid-p descriptor))
              (should-not auto-revert-mode)))
          (message "Native Isled refresh: backend=%s mechanism=%s"
                   file-notify--library (if descriptor 'notifications 'polling))
          ;; Nothing below requests refresh or invokes notification callbacks.
          (isled-native-refresh--write
           first (replace-regexp-in-string "First" "Edited" original t t))
          (isled-native-refresh--wait
           "in-place edit"
           (lambda ()
             (and (isled-native-refresh--settled-p view)
                  (equal (isled-issue-title (isled-native-refresh--issue view "0001"))
                         "Edited"))))
          (isled-native-refresh--write
           replacement (replace-regexp-in-string "First" "Replaced" original t t))
          (rename-file replacement first t)
          (isled-native-refresh--wait
           "atomic replacement"
           (lambda ()
             (and (isled-native-refresh--settled-p view)
                  (equal (isled-issue-title (isled-native-refresh--issue view "0001"))
                         "Replaced"))))
          (isled-native-refresh--write
           second (replace-regexp-in-string "0001 — First" "0002 — Second" original t t))
          (isled-native-refresh--wait
           "creation"
           (lambda ()
             (and (isled-native-refresh--settled-p view)
                  (isled-native-refresh--issue view "0002"))))
          (rename-file second renamed)
          (isled-native-refresh--wait
           "rename"
           (lambda ()
             (and (isled-native-refresh--settled-p view)
                  (equal (isled-issue-path (isled-native-refresh--issue view "0002"))
                         renamed))))
          (delete-file renamed)
          (isled-native-refresh--wait
           "deletion"
           (lambda ()
             (and (isled-native-refresh--settled-p view)
                  (not (isled-native-refresh--issue view "0002")))))
          (with-current-buffer view
            (should (equal (mapcar #'isled-issue-id (isled-snapshot-issues isled-data-view))
                           '("0001")))
            (should (string-match-p "Replaced" (buffer-string)))))
      (when (buffer-live-p view) (kill-buffer view))
      ;; Closing the final view must release the shared owner and OS watch.
      (should-not (gethash root isled-session--sessions))
      (should-not (buffer-live-p owner))
      (when descriptor (should-not (file-notify-valid-p descriptor)))
      (delete-directory root t))))

(provide 'isled-auto-refresh-integration-test)
;;; isled-auto-refresh-integration-test.el ends here
