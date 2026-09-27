;;; isled-download-test.el --- Release transport boundaries -*- lexical-binding: t; -*-

;;; Commentary:
;; Exercise the production URL handler with controlled asynchronous HTTP replies.

;;; Code:
(require 'ert)
(require 'isled-download)

(defun isled-download-test--wait (predicate)
  "Wait at most two seconds for PREDICATE to become true."
  (let ((deadline (+ 2 (float-time))))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.01)))
  (should (funcall predicate)))

(defmacro isled-download-test--with-http (replies &rest body)
  "Run BODY with asynchronous HTTP REPLIES, recording requested URLs."
  (declare (indent 1) (debug t))
  `(let ((responses ,replies) calls buffers timers)
     (unwind-protect
         (cl-letf (((symbol-function 'url-retrieve)
                    (lambda (url callback _arguments _silent inhibit-cookies)
                      (should inhibit-cookies)
                      (should-not url-registered-auth-schemes)
                      (should gnutls-verify-error)
                      (should (= url-max-redirections 0))
                      (push url calls)
                      (let ((response (pop responses)) (buffer (generate-new-buffer " *isled-http-test*")))
                        (push buffer buffers)
                        (when response
                          (push (run-at-time
                                 0 nil
                                 (lambda ()
                                   (when (buffer-live-p buffer)
                                     (with-current-buffer buffer
                                       (set-buffer-multibyte nil)
                                       (insert (format "HTTP/1.1 %d Test\r\n" (car response)))
                                       (when (nth 2 response) (insert "Location: " (nth 2 response) "\r\n"))
                                       (insert "\r\n")
                                       (setq-local url-http-end-of-headers (copy-marker (1- (point)))
                                                   url-http-response-status (car response))
                                       (insert (cadr response))
                                       (funcall callback (nth 3 response)))))) timers))
                        buffer))))
           ,@body)
       (dolist (timer timers) (cancel-timer timer))
       (dolist (buffer buffers) (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest isled-download-verifies-redirects-before-fetching ()
  (isled-download-test--with-http
      '((302 "" "https://release-assets.githubusercontent.com/asset") (200 "\0\377payload"))
    (let (result)
      (isled-download "0.32.0" "asset.zip" 100 (lambda (bytes error) (setq result (list bytes error))))
      (isled-download-test--wait (lambda () result))
      (should (equal result '("\0\377payload" nil))) (should (= (length calls) 2)))))

(ert-deftest isled-download-rejects-untrusted-and-insecure-origins ()
  (dolist (address '("http://github.com/asset" "https://evil.example/asset"
                     "https://github.com.evil.example/asset" "https://github.com:444/asset"
                     "https://user:secret@github.com/asset" "file:///tmp/asset"))
    (should-not (isled-download--allowed-url-p address))
    (isled-download-test--with-http (list (list 302 "" address))
      (let (result)
        (isled-download "0.32.0" "asset.zip" 100 (lambda (bytes error) (setq result (list bytes error))))
        (isled-download-test--wait (lambda () result))
        (should-not (car result)) (should (cadr result)) (should (= (length calls) 1))))))

(ert-deftest isled-download-reports-missing-interrupted-and-oversize-responses ()
  (dolist (response '((404 "Missing") (200 "partial" nil (:error (error "Connection lost"))) (200 "too big")))
    (isled-download-test--with-http (list response)
      (let (result)
        (isled-download "0.32.0" "asset.zip" 3 (lambda (bytes error) (setq result (list bytes error))))
        (isled-download-test--wait (lambda () result))
        (should-not (car result)) (should (cadr result))))))

(ert-deftest isled-download-cancellation-releases-response-and-notifies-once ()
  (isled-download-test--with-http '(nil)
    (let ((count 0) failure)
      (let ((cancel (isled-download "0.32.0" "asset.zip" 100
                                    (lambda (_bytes error) (cl-incf count) (setq failure error)))))
        (funcall cancel) (funcall cancel)
        (should (= count 1)) (should (string-match-p "cancelled" failure))
        (should-not (seq-some #'buffer-live-p buffers))))))

(ert-deftest isled-download-timeout-cleans-up ()
  (isled-download-test--with-http '(nil)
    (let ((timer-function (symbol-function 'run-at-time)) result)
      (cl-letf (((symbol-function 'run-at-time)
                 (lambda (time repeat function &rest args)
                   (apply timer-function (if (equal time 120) 0.01 time) repeat function args))))
        (isled-download "0.32.0" "asset.zip" 100 (lambda (bytes error) (setq result (list bytes error)))))
      (isled-download-test--wait (lambda () result))
      (should (string-match-p "timed out" (cadr result)))
      (should-not (seq-some #'buffer-live-p buffers)))))

(provide 'isled-download-test)
;;; isled-download-test.el ends here
