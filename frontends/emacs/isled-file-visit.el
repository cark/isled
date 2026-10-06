;;; isled-file-visit.el --- Validated issue-file navigation -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Assisted-by: Codex:GPT-6
;; Keywords: tools

;;; Commentary:
;; Ask Rust to validate issue targets before visiting their source, then use normal
;; ledger navigation.  Late replies cannot redirect changed source or views.

;;; Code:
(require 'isled-file-routing)
(require 'isled-browser)
(require 'isled-buffers)

(cl-defstruct (isled-file-visit--request
               (:constructor isled-file-visit--request-create))
  root id file serial buffer window point tick attributes view generation view-state origin-state display fallback)

(defvar isled-file-visit--pending nil
  "Latest file validation whose source origin is still being observed.")

(defun isled-file-visit--observe ()
  "Cancel pending routing after movement away from the source location."
  (when-let ((request isled-file-visit--pending))
    (unless (and isled-file-routing
                 (eq (selected-window) (isled-file-visit--request-window request))
                 (eq (window-buffer) (isled-file-visit--request-buffer request))
                 (= (window-point) (isled-file-visit--request-point request)))
      (setq isled-file-visit--pending nil
            isled-file-routing--serial (1+ isled-file-routing--serial))
      (remove-hook 'post-command-hook #'isled-file-visit--observe))))

(defun isled-file-visit--file-stamp (file)
  "Return FILE identity and content-change metadata, ignoring access time."
  (let ((attributes (file-attributes file)))
    (list (file-attribute-modification-time attributes)
          (file-attribute-status-change-time attributes)
          (file-attribute-size attributes)
          (file-attribute-inode-number attributes))))

(defun isled-file-visit--current-p (request)
  "Return whether REQUEST still belongs to unchanged source and view state."
  (let ((buffer (isled-file-visit--request-buffer request))
        (window (isled-file-visit--request-window request))
        (view (isled-file-visit--request-view request))
        (file (isled-file-visit--request-file request)))
    (and isled-file-routing
         (= isled-file-routing--serial (isled-file-visit--request-serial request))
         (buffer-live-p buffer) (window-live-p window)
         (eq window (selected-window)) (eq (window-buffer window) buffer)
         (with-current-buffer buffer
           (if (isled-file-visit--request-origin-state request)
               (equal (isled--capture-view-state)
                      (isled-file-visit--request-origin-state request))
             (and (= (window-point window) (isled-file-visit--request-point request))
                  (= (buffer-chars-modified-tick) (isled-file-visit--request-tick request)))))
         (not (when-let ((source (find-buffer-visiting file))) (buffer-modified-p source)))
         (equal (isled-file-visit--file-stamp file) (isled-file-visit--request-attributes request))
         (equal file (file-truename file))
         (eq view (isled--buffer-for-root (isled-file-visit--request-root request)))
         (or (not view)
             (with-current-buffer view
               (and (eq isled-loading-generation
                       (isled-file-visit--request-generation request))
                    (equal (isled--capture-view-state)
                           (isled-file-visit--request-view-state request))))))))

(defun isled-file-visit--decode (request result)
  "Validate RESULT as REQUEST's complete canonical issue, or signal an error."
  (unless (eql (isled-command-result-status result) 0)
    (error "%s" (isled-snapshot--failure-message result)))
  (let* ((response (isled-frontend-decode (isled-command-result-stdout result)))
         (changes (isled-response-changes response))
         (issue (and (= (length changes) 1) (isled-detail-issue (car changes)))))
    (unless (and issue
                 (not (isled-response-view response))
                 (equal (isled-response-root response)
                        (isled-file-visit--request-root request))
                 (equal (isled-issue-id issue) (isled-file-visit--request-id request))
                 (equal (isled-issue-path issue) (isled-file-visit--request-file request)))
      (error "File is not a well-formed canonical issue record"))
    issue))

(defun isled-file-visit--reveal (request issue)
  "Reveal validated ISSUE for REQUEST without visiting its Markdown source."
  (when (isled-buffers-display-root
         (isled-file-visit--request-root request)
         (isled-file-visit--request-display request))
    (isled-navigation-with-window
      (let ((origin (and isled-data-view (isled--capture-view-state))))
        (isled--visit-issue
         issue
         (lambda ()
           (isled-navigation-record origin)))))))

(defun isled-file-visit--fallback (request failure)
  "Open REQUEST's original file destination after FAILURE."
  (message "Isled: opening Markdown (%s)" (error-message-string failure))
  (let ((isled-inhibit-file-routing t))
    (funcall (isled-file-visit--request-fallback request))))

(defun isled-file-visit--receive (request result)
  "Route current REQUEST on valid RESULT; otherwise open its original file."
  (when (eq request isled-file-visit--pending)
    (setq isled-file-visit--pending nil)
    (remove-hook 'post-command-hook #'isled-file-visit--observe))
  (when (isled-file-visit--current-p request)
    (with-current-buffer (isled-file-visit--request-buffer request)
      (condition-case failure
          (let ((issue (isled-file-visit--decode request result)))
            (isled-file-visit--reveal request issue))
        (error (isled-file-visit--fallback request failure))))))

(defun isled-file-visit (candidate serial display fallback)
  "Validate CANDIDATE for open SERIAL asynchronously before DISPLAY or FALLBACK."
  (pcase-let* ((`(,root ,id ,file) candidate)
               (view (isled--buffer-for-root root))
               (request
                (isled-file-visit--request-create
                 :root root :id id :file file :serial serial :display display :fallback fallback
                 :buffer (current-buffer) :window (selected-window) :point (copy-marker (point))
                 :tick (buffer-chars-modified-tick) :attributes (isled-file-visit--file-stamp file)
                 :view view
                 :origin-state (and (derived-mode-p 'isled-mode)
                                    (isled--capture-view-state))
                 :generation (and view (buffer-local-value 'isled-loading-generation view))
                 :view-state (and view (with-current-buffer view (isled--capture-view-state))))))
    (setq isled-file-visit--pending request)
    (add-hook 'post-command-hook #'isled-file-visit--observe)
    (condition-case failure
        (funcall isled-process-function root
                 (json-serialize `((schema_version . 5) (mode . "details")
                                   (details . [((id . ,id) (hash . :null))])))
                 (lambda (result) (isled-file-visit--receive request result)))
      (error
       (setq isled-file-visit--pending nil)
       (remove-hook 'post-command-hook #'isled-file-visit--observe)
       (isled-file-visit--fallback request failure)))))

(provide 'isled-file-visit)
;;; isled-file-visit.el ends here
