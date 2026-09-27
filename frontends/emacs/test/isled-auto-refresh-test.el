;;; isled-auto-refresh-test.el --- Notification lifecycle tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Cover watch setup, polling fallback, coalescing, and cleanup through the view.

;;; Code:

(require 'ert)
(require 'isled-browser)

(ert-deftest isled-command-prefers-directory-notifications ()
  (let ((isled-auto-revert t)
        (file-notify--library 'inotify)
        (snapshot-count 0)
        added-watch removed-watches callback buffer)
    (cl-letf (((symbol-function 'file-notify-add-watch)
               (lambda (path flags function)
                 (setq added-watch (list path flags)
                       callback function)
                 'test-watch))
              ((symbol-function 'file-notify-rm-watch)
               (lambda (descriptor)
                 (push descriptor removed-watches))))
      (let ((isled-snapshot-runner-function
             (lambda (directory)
               (cl-incf snapshot-count)
               (isled-command-result-create
                :status 0
                :stderr ""
                :stdout
                (json-serialize
                 `((schema_version . 3)
                   (root . ((encoding . "utf-8") (value . ,directory)))
                   (issues . [])))))))
        (unwind-protect
            (save-window-excursion
              (setq buffer (isled-buffers-open "/tmp/notification-first" "/tmp/notification-first" nil nil))
              (with-current-buffer buffer
                (should (equal added-watch
                               `(,(expand-file-name "/tmp/notification-first/.issues")
                                 (change attribute-change))))
                (should (functionp callback))
                (should (eq (buffer-local-value 'isled--notification-watch
                                               (isled-session-owner isled-session))
                            'test-watch))
                (should (memq #'isled--stop-auto-refresh
                              change-major-mode-hook))
                (should (memq #'isled--stop-auto-refresh
                              kill-buffer-hook))
                (should-not auto-revert-mode)
                (should-not (isled--buffer-stale-p))
                (should-not isled--auto-refresh-warning)
                ;; The initial load is reconciled once after installing the
                ;; watch; an unchanged stale check launches nothing.
                (should (= snapshot-count 2))
                (should (eq (isled-buffers-open "/tmp/notification-first" "/tmp/notification-first" nil nil)
                            buffer))
                ;; Reuse needs neither discovery nor another reconciliation.
                (should (= snapshot-count 2))))
          (when (buffer-live-p buffer)
            (kill-buffer buffer))))
      (should (equal removed-watches '(test-watch))))))

(ert-deftest isled-command-falls-back-to-auto-revert-polling ()
  (let ((isled-auto-revert t)
        (file-notify--library 'kqueue)
        (isled-snapshot-runner-function
         (lambda (directory)
           (isled-command-result-create
            :status 0
            :stderr ""
            :stdout
            (json-serialize
             `((schema_version . 3)
               (root . ((encoding . "utf-8") (value . ,directory)))
               (issues . []))))))
        buffer)
    (unwind-protect
        (save-window-excursion
          (setq buffer (isled-buffers-open "/tmp/auto-revert" "/tmp/auto-revert" nil nil))
          (with-current-buffer buffer
            (should-not auto-revert-mode)
            (with-current-buffer (isled-session-owner isled-session)
              (should auto-revert-mode)
              (should-not isled--notification-watch)
              (should (eq (isled--buffer-stale-p) 'fast)))
            (should (string-match-p
                     "kqueue cannot observe"
                     isled--auto-refresh-warning))
            (should (string-match-p
                     "Auto-refresh using polling"
                     (isled--header-line)))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest isled-auto-revert-customization-disables-the-view ()
  (let ((isled-auto-revert nil)
        (global-auto-revert-mode nil)
        (global-auto-revert-non-file-buffers nil)
        (isled-snapshot-runner-function
         (lambda (directory)
           (isled-command-result-create
            :status 0
            :stderr ""
            :stdout
            (json-serialize
             `((schema_version . 3)
               (root . ((encoding . "utf-8") (value . ,directory)))
               (issues . []))))))
        buffer)
    (unwind-protect
        (save-window-excursion
          (setq buffer (isled-buffers-open "/tmp/no-auto-revert" "/tmp/no-auto-revert" nil nil))
          (with-current-buffer buffer
            (should-not auto-revert-mode)
            (should-not isled--notification-watch)
            (should-not (isled--buffer-stale-p))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest isled-notifications-coalesce-visible-ledger-events ()
  (let ((buffer (generate-new-buffer " *isled-notifications*"))
        (isled-auto-revert t)
        scheduled canceled refreshes)
    (unwind-protect
        (with-current-buffer buffer
          (isled-mode)
          (setq isled--root "/tmp/example"
                isled--notification-watch 'test-watch)
          (cl-letf (((symbol-function 'run-with-idle-timer)
                     (lambda (seconds repeat function &rest arguments)
                       (let ((timer (list 'test-timer (length scheduled))))
                         (push (list seconds repeat function arguments timer)
                               scheduled)
                         timer)))
                    ((symbol-function 'timerp)
                     (lambda (value)
                       (eq (car-safe value) 'test-timer)))
                    ((symbol-function 'cancel-timer)
                     (lambda (timer)
                       (push timer canceled)))
                    ((symbol-function 'isled--refresh)
                     (lambda (automatic)
                       (push automatic refreshes))))
            (isled--handle-notification
             buffer '(test-watch created
                                 "/tmp/example/.issues/.isled-lock"))
            (should-not scheduled)
            (isled--handle-notification
             buffer '(test-watch changed
                                 "/tmp/example/.issues/0001-example.md"))
            (let ((superseded (car scheduled)))
              (isled--handle-notification
               buffer '(test-watch renamed
                                   "/tmp/example/.issues/.0001.tmp"
                                   "/tmp/example/.issues/0001-example.md"))
              (should (= (length scheduled) 2))
              (should (= (length canceled) 1))
              (should (= (caar scheduled)
                         isled--notification-delay))
              (apply (nth 2 superseded) (nth 3 superseded))
              (should-not refreshes)
              (let ((current (car scheduled)))
                (apply (nth 2 current) (nth 3 current))))
            (should (equal refreshes '(t)))
            (should-not isled--notification-timer)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest isled-stopped-watch-recovers-through-polling ()
  (let ((buffer (generate-new-buffer " *isled-watch-recovery*"))
        (isled-auto-revert t)
        (file-notify--library 'inotify)
        can-start)
    (unwind-protect
        (with-current-buffer buffer
          (isled-mode)
          (setq isled--root "/tmp/example"
                isled--notification-watch 'old-watch)
          (cl-letf (((symbol-function 'file-notify-add-watch)
                     (lambda (_path _flags _callback)
                       (if can-start
                           'new-watch
                         (signal 'file-notify-error '("watch stopped")))))
                    ((symbol-function 'file-notify-rm-watch) #'ignore))
            (isled--handle-notification
             buffer '(old-watch stopped "/tmp/example/.issues"))
            (should-not isled--notification-watch)
            (should auto-revert-mode)
            (should (string-match-p
                     "watch stopped" isled--auto-refresh-warning))
            (setq can-start t)
            (should (eq (isled--buffer-stale-p) 'fast))
            (should (eq isled--notification-watch 'new-watch))
            (should-not auto-revert-mode)
            (should-not isled--auto-refresh-warning)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest isled-disabling-refresh-cleans-watch-and-timer ()
  (let ((buffer (generate-new-buffer " *isled-watch-cleanup*"))
        removed canceled)
    (unwind-protect
        (with-current-buffer buffer
          (isled-mode)
          (setq isled--root "/tmp/example"
                isled--notification-watch 'test-watch
                isled--notification-timer '(test-timer)
                isled-auto-revert nil)
          (cl-letf (((symbol-function 'file-notify-rm-watch)
                     (lambda (descriptor)
                       (setq removed descriptor)))
                    ((symbol-function 'timerp)
                     (lambda (value)
                       (equal value '(test-timer))))
                    ((symbol-function 'cancel-timer)
                     (lambda (timer)
                       (setq canceled timer))))
            (isled--configure-auto-refresh))
          (should (eq removed 'test-watch))
          (should (equal canceled '(test-timer)))
          (should-not isled--notification-watch)
          (should-not isled--notification-timer)
          (should-not auto-revert-mode))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(provide 'isled-auto-refresh-test)
;;; isled-auto-refresh-test.el ends here
