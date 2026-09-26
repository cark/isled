;;; isled-session-test.el --- Shared ledger tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Shared lifetime and serialized transport must not depend on one view surviving.
;;; Code:
(require 'ert)
(require 'isled-browser)
(require 'isled-loading-test)

(ert-deftest isled-session-shares-cache-and-releases-last-view ()
  (let ((a (generate-new-buffer " *session-a*"))
        (b (generate-new-buffer " *session-b*")) session)
    (unwind-protect
        (progn
          (dolist (view (list a b))
            (with-current-buffer view
              (isled-mode)
              (setq isled--root "/tmp/pi-session-fixture")
              (isled-session-attach)))
          (setq session (buffer-local-value 'isled-session a))
          (should (eq session (buffer-local-value 'isled-session b)))
          (should (eq (buffer-local-value 'isled-data-details a)
                      (buffer-local-value 'isled-data-details b)))
          (kill-buffer a)
          (should (equal (isled-session-views session) (list b)))
          (kill-buffer b)
          (should-not (gethash "/tmp/pi-session-fixture" isled-session--sessions))
          (should-not (isled-session-details session)))
      (dolist (view (list a b)) (when (buffer-live-p view) (kill-buffer view))))))

(ert-deftest isled-session-serializes-and-discards-closed-origin ()
  (let ((a (generate-new-buffer " *session-a*"))
        (b (generate-new-buffer " *session-b*")) calls delivered)
    (unwind-protect
        (let ((isled-process-function
               (lambda (_root request callback) (push (cons request callback) calls))))
          (dolist (view (list a b))
            (with-current-buffer view
              (isled-mode)
              (setq isled--root "/tmp/pi-serial-fixture")
              (isled-session-attach)
              (isled-session-submit
               isled--root "{\"mode\":\"view\"}"
               (lambda (_) (push (current-buffer) delivered)))))
          (should (= (length calls) 1))
          (kill-buffer a)
          (funcall (cdar calls) nil)
          (should (= (length calls) 2))
          (should-not delivered)
          (funcall (cdar calls) nil)
          (should (equal delivered (list b))))
      (dolist (view (list a b)) (when (buffer-live-p view) (kill-buffer view))))))

(ert-deftest isled-session-one-timer-survives-view-removal ()
  (cl-letf (((symbol-function 'isled-viewport-work-p) (lambda () t)))
  (save-window-excursion
    (let ((a (generate-new-buffer " *timer-a*"))
          (b (generate-new-buffer " *timer-b*")) session timer)
      (unwind-protect
          (progn
            (dolist (view (list a b))
              (with-current-buffer view
                (isled-mode)
                (setq isled--root "/tmp/pi-timer-fixture")
                (isled-session-attach)))
            (set-window-buffer (selected-window) a)
            (set-window-buffer (split-window-right) b)
            (setq session (buffer-local-value 'isled-session a))
            (isled-session-schedule session)
            (setq timer (isled-session-timer session))
            (should (timerp timer))
            (should (eq timer (buffer-local-value 'isled-loading-timer a)))
            (should (eq timer (buffer-local-value 'isled-loading-timer b)))
            (isled-session-schedule session)
            (should (eq timer (isled-session-timer session)))
            (should (memq timer timer-list))
            (kill-buffer a)
            (setq timer (isled-session-timer session))
            (should (memq timer timer-list))
            (kill-buffer b)
            (should-not (memq timer timer-list)))
        (dolist (view (list a b)) (when (buffer-live-p view) (kill-buffer view))))))))

(ert-deftest isled-session-refresh-updates-survivor-after-origin-closes ()
  (let* ((a (generate-new-buffer " *refresh-a*"))
         (b (generate-new-buffer " *refresh-b*")) calls
         (isled-process-function
          (lambda (_root request callback) (push (list request callback) calls))))
    (unwind-protect
        (progn
          (dolist (view (list a b))
            (with-current-buffer view
              (isled-mode)
              (setq isled--root "/tmp/example")
              (isled-session-attach)))
          (with-current-buffer a
            (isled-session-submit isled--root "{\"mode\":\"refresh\"}" #'ignore))
          (kill-buffer a)
          (isled-loading-test--reply (pop calls) 'refresh)
          (should (= (length calls) 1))
          (should (equal (alist-get 'mode (json-parse-string (caar calls) :object-type 'alist)) "view"))
          (isled-loading-test--reply (pop calls) 'view)
          (with-current-buffer b
            (should isled--snapshot)
            (should-not isled--auto-revert-error)))
      (dolist (view (list a b)) (when (buffer-live-p view) (kill-buffer view))))))

(ert-deftest isled-session-queued-details-recheck-demand-before-dispatch ()
  (let* ((buffer (generate-new-buffer " *queued-demand*")) calls (demand t) discarded
         (isled-process-function
          (lambda (_root request callback) (push (cons request callback) calls))))
    (unwind-protect
        (with-current-buffer buffer
          (isled-mode)
          (setq isled--root "/tmp/queued-demand")
          (isled-session-attach)
          (isled-session-submit isled--root "{\"mode\":\"view\"}" #'ignore)
          (isled-session-submit
           isled--root "{\"mode\":\"details\"}"
           (lambda (_) (setq discarded isled-session-discarded))
           (lambda () (and demand "{\"mode\":\"details\"}")))
          (setq demand nil)
          (funcall (cdar calls) nil)
          (should discarded)
          (should (= (length calls) 1))
          (should-not (isled-session-running isled-session)))
      (kill-buffer buffer))))

(ert-deftest isled-session-refresh-coalescing-does-not-disable-later-refresh ()
  (let* ((buffer (generate-new-buffer " *coalesced-refresh*")) calls
         (isled-process-function
          (lambda (_root request callback) (push (cons request callback) calls))))
    (unwind-protect
        (with-current-buffer buffer
          (isled-mode)
          (setq isled--root "/tmp/coalesced-refresh")
          (isled-session-attach)
          (dotimes (_ 2)
            (isled-session-submit isled--root "{\"mode\":\"refresh\"}" #'ignore))
          (funcall (cdar calls) nil)
          (should (equal (alist-get 'mode (json-parse-string (caar calls) :object-type 'alist)) "view"))
          (funcall (cdar calls) nil)
          (isled-session-submit isled--root "{\"mode\":\"refresh\"}" #'ignore)
          (should (equal (alist-get 'mode (json-parse-string (caar calls) :object-type 'alist)) "refresh"))
          (funcall (cdar calls) nil)
          (should-not (isled-session-running isled-session)))
      (kill-buffer buffer))))

(provide 'isled-session-test)
;;; isled-session-test.el ends here
