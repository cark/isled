;;; isled-download.el --- Cancellable release downloads -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Assisted-by: Codex:GPT-6
;; Keywords: tools

;;; Commentary:
;; Fetch one GitHub release asset with strict HTTPS redirects and bounded waits.

;;; Code:
(require 'cl-lib)
(require 'url-http)
(require 'gnutls)
(require 'url-auth)
(require 'mail-utils)
(require 'isled-release)

(defvar url-http-response-status)
(defvar url-http-end-of-headers)

(defun isled-download--allowed-url-p (address)
  "Return non-nil for an HTTPS ADDRESS on GitHub's release delivery hosts."
  (let ((url (url-generic-parse-url address)))
    (and (equal (url-type url) "https")
         (member (downcase (or (url-host url) ""))
                 '("github.com" "release-assets.githubusercontent.com" "objects.githubusercontent.com"))
         (= (url-port url) 443) (not (url-user url)) (not (url-password url)))))

(defun isled-download (version asset limit callback)
  "Fetch ASSET of VERSION, at most LIMIT bytes, then call CALLBACK.
CALLBACK receives unibyte content and nil, or nil and an error message.
Return a cancellation function.  No authentication or cookies are sent."
  (isled-release-validate-version version)
  (unless (string-match-p "\\`[A-Za-z0-9][A-Za-z0-9._-]*\\'" asset)
    (error "Unsafe Isled release asset name"))
  (let (buffer timeout progress finished)
    (cl-labels
        ((dispose ()
           (when (buffer-live-p buffer)
             (when-let ((process (get-buffer-process buffer))) (delete-process process))
             (kill-buffer buffer)))
         (finish (content failure)
           (unless finished
             (setq finished t)
             (when timeout (cancel-timer timeout))
             (when progress (cancel-timer progress))
             (dispose)
             (funcall callback content failure)))
         (start (address redirects)
           (unless (isled-download--allowed-url-p address)
             (error "Rejected non-GitHub or non-HTTPS Isled download redirect"))
           (let ((url-max-redirections 0) (url-request-method "GET")
                 (url-request-data nil)
                 (url-request-extra-headers '(("Pragma" . "no-cache") ("Cache-Control" . "no-cache")))
                 (url-registered-auth-schemes nil)
                 (url-privacy-level 'paranoid) (gnutls-verify-error t))
             (setq buffer
                   (url-retrieve
                    address
                    (lambda (status)
                      (unless finished
                        (condition-case failure
                            (let ((code url-http-response-status))
                              (cond
                               ((memq code '(301 302 303 307 308))
                                (when (>= redirects 3) (error "Too many Isled download redirects"))
                                (let ((next (save-restriction
                                              (narrow-to-region (point-min) url-http-end-of-headers)
                                              (mail-fetch-field "Location"))))
                                  (unless next (error "Missing Isled redirect destination"))
                                  (dispose)
                                  (start next (1+ redirects))))
                               ((or (plist-get status :error) (not (eql code 200)))
                                (error "Cannot download %s (HTTP %s); check connectivity or release availability and retry"
                                       asset (or code "unavailable")))
                               (t
                                (unless url-http-end-of-headers (error "Missing HTTP headers"))
                                (let ((bytes (buffer-substring-no-properties
                                              (1+ url-http-end-of-headers) (point-max))))
                                  (when (> (length bytes) limit) (error "Isled download exceeds size limit"))
                                  (finish bytes nil)))))
                          ((error quit) (finish nil (error-message-string failure))))))
                    nil t t))
             (unless (buffer-live-p buffer) (error "Cannot start Isled download; check connectivity and retry"))
             ;; url.el reads this when the asynchronous response arrives.
             (with-current-buffer buffer
               (setq-local url-max-redirections 0 url-registered-auth-schemes nil)))))
      (condition-case failure
          (progn
            (message "Downloading Isled %s: %s (M-x isled-cancel-setup to cancel)" version asset)
            (setq timeout (run-at-time 120 nil (lambda () (finish nil "Isled download timed out; retry when online")))
                  progress (run-at-time
                            1 1 (lambda ()
                                  (when (and (not finished) (buffer-live-p buffer))
                                    (let ((size (buffer-size buffer)))
                                      (if (> size (+ limit 65536))
                                          (finish nil "Isled download exceeds size limit")
                                        (message "Downloading %s: %d KiB (M-x isled-cancel-setup to cancel)"
                                                 asset (/ size 1024))))))))
            (start (format "https://github.com/cark/isled/releases/download/v%s/%s" version asset) 0))
        ((error quit) (finish nil (error-message-string failure))))
      (lambda () (finish nil "Isled setup cancelled; invoke the command again to retry")))))

(provide 'isled-download)
;;; isled-download.el ends here
