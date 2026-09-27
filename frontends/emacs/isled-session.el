;;; isled-session.el --- Shared ledger lifetime -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Assisted-by: Codex:GPT-6
;; Keywords: tools

;;; Commentary:

;; One ledger owns its detail cache and serialized process queue.  Views retain
;; their filtered projections and navigation state independently.

;;; Code:

(require 'cl-lib)
(require 'isled-data)
(require 'isled-windows)

(defvar isled--root)
(defvar isled-session-discarded nil
  "Non-nil while completing a queued job that no longer has demand.")
(defvar isled-session-delivered-mode nil
  "Actual serialized request mode while delivering a response.")
(defvar isled-loading-range)
(defvar isled-loading-pending)
(declare-function isled-viewport-work-p "isled-viewport")
(declare-function isled-viewport-prefetch "isled-viewport")
(defvar isled-loading-timer)
(declare-function isled-loading--request-needed "isled-loading")
(defvar isled-process-function)
(declare-function isled-loading-request "isled-loading")
(declare-function isled-loading-share "isled-loading")
(declare-function isled-loading--failure "isled-loading")
(declare-function isled-expansion-clear "isled-expansion")
(declare-function isled--stop-auto-refresh "isled-auto-refresh")
(declare-function isled--configure-auto-refresh "isled-auto-refresh")
(declare-function isled--refresh "isled-browser")
(declare-function isled--buffer-stale-p "isled-auto-refresh")
(defvar isled-session-owner-p nil)
(defvar isled-auto-revert)
(defvar isled--auto-refresh-warning)

(cl-defstruct (isled-session (:constructor isled-session--create))
  "Shared runtime resources for one canonical ledger."
  root views details targets queue running owner running-mode timer listeners)

(defvar isled-session--sessions (make-hash-table :test #'equal)
  "Live sessions indexed by canonical ledger root.")
(defvar-local isled-session nil "Ledger session owning this view.")

(defun isled-session-for-root (root &optional details targets)
  "Return ROOT's session, seeding a new session with DETAILS and TARGETS."
  (or (gethash root isled-session--sessions)
      (let ((session (isled-session--create
                      :root root
                      :details (or details (make-hash-table :test #'equal))
                      :targets (or targets (make-hash-table :test #'equal)))))
        (puthash root session isled-session--sessions)
        session)))

(defun isled-session-attach ()
  "Attach this view to its canonical ledger's retained resources."
  (when-let ((existing (gethash isled--root isled-session--sessions)))
    (setf (isled-session-views existing)
          (seq-filter #'buffer-live-p (isled-session-views existing)))
    (unless (or (isled-session-views existing) (isled-session-listeners existing))
      (remhash isled--root isled-session--sessions)))
  (unless isled-session
    (setq isled-session
          (isled-session-for-root isled--root isled-data-details isled-data-targets))
    (cl-pushnew (current-buffer) (isled-session-views isled-session)))
  (setq isled-data-details (isled-session-details isled-session)
        isled-data-targets (isled-session-targets isled-session)))

(defun isled-session-detach ()
  "Detach this view and release an unused ledger session."
  (when-let ((session isled-session))
    (setq isled-session nil)
    (setf (isled-session-views session)
          (delq (current-buffer) (isled-session-views session))
          (isled-session-queue session)
          (seq-remove (lambda (job) (eq (car job) (current-buffer)))
                      (isled-session-queue session)))
    (isled-session-release-unused session)))

(defun isled-session-release-unused (session)
  "Release SESSION resources only when neither views nor listeners remain."
  (if (or (isled-session-views session) (isled-session-listeners session))
      (isled-session-schedule session)
    (isled-session-cancel-timer session)
    (remhash (isled-session-root session) isled-session--sessions)
    (when-let ((owner (isled-session-owner session)))
      (when (buffer-live-p owner)
        (with-current-buffer owner (isled--stop-auto-refresh))
        (kill-buffer owner)))
    (setf (isled-session-queue session) nil
          (isled-session-details session) nil
          (isled-session-targets session) nil)))

(defun isled-session-subscribe (root callback)
  "Retain ROOT's shared watch and call CALLBACK in the subscribing buffer."
  (let ((session (isled-session-for-root root)))
    (push (cons (current-buffer) callback) (isled-session-listeners session))
    (let ((isled-session session)) (isled-session-watch))
    session))

(defun isled-session-unsubscribe (session)
  "Remove this buffer's subscription to SESSION and release unused resources."
  (when session
    (setf (isled-session-listeners session)
          (assq-delete-all (current-buffer) (isled-session-listeners session)))
    (isled-session-release-unused session)))

(defun isled-session-nearby ()
  "Return the union of expanded IDs near windows of this ledger's views."
  (if (not isled-session) (isled-windows-nearby)
    (let ((ids (make-hash-table :test #'equal)))
      (dolist (view (isled-session-views isled-session))
        (when (buffer-live-p view)
          (with-current-buffer view
            (dolist (id (isled-windows-nearby)) (puthash id t ids)))))
      (sort (hash-table-keys ids) #'string<))))

(defun isled-session-cancel-timer (session)
  "Cancel SESSION's formatting timer and clear all view references to it."
  (when (timerp (isled-session-timer session))
    (cancel-timer (isled-session-timer session)))
  (setf (isled-session-timer session) nil)
  (dolist (view (isled-session-views session))
    (when (buffer-live-p view)
      (with-current-buffer view (setq isled-loading-timer nil)))))

(defun isled-session-schedule (session)
  "Dispatch SESSION's current data demand; yield between extra formatting."
  (let ((visible (seq-filter
                  (lambda (view) (and (buffer-live-p view)
                                 (with-current-buffer view (isled-windows-visible))))
                  (isled-session-views session))))
    (if (not visible) (isled-session-cancel-timer session)
      (isled-loading--request-needed (car visible))
      (if (not (seq-some (lambda (view)
                          (with-current-buffer view (isled-viewport-work-p))) visible))
          (isled-session-cancel-timer session)
        (let ((timer (or (isled-session-timer session)
                       ;; A positive delay returns to input/redisplay processing
                       ;; instead of draining zero-delay callbacks in one turn.
                       (run-at-time 0.001 nil #'isled-session--prepare-next session))))
        (setf (isled-session-timer session) timer)
        (dolist (view visible)
          (with-current-buffer view (setq isled-loading-timer timer))))))))

(defun isled-session--prepare-next (session)
  "Prepare at most one extra body in SESSION, then yield to the event loop."
  (isled-session-cancel-timer session)
  (when (seq-some (lambda (buffer)
                    (when (buffer-live-p buffer)
                      (with-current-buffer buffer (isled-viewport-prefetch))))
                  (isled-session-views session))
    (isled-session-schedule session)))

(defun isled-session-watch ()
  "Install one notification owner for this ledger and return whether it is new."
  (let* ((session isled-session)
         (owner (isled-session-owner session))
         (enabled isled-auto-revert))
    (unless (buffer-live-p owner)
      (setq owner (generate-new-buffer " *isled ledger*"))
      (setf (isled-session-owner session) owner)
      (with-current-buffer owner
        (setq-local isled-session session)
        (setq-local isled-session-owner-p t)
        (setq-local isled--root (isled-session-root session))
        (setq default-directory (file-name-as-directory isled--root))
        (setq-local isled-auto-revert enabled)
        (setq-local revert-buffer-function
                    (lambda (&rest _) (isled-session-refresh)))
        (setq-local buffer-stale-function #'isled--buffer-stale-p)))
    (with-current-buffer owner (isled--configure-auto-refresh))))

(defun isled-session-refresh ()
  "Notify subscribers and reconcile through a surviving view of this ledger."
  (dolist (listener (isled-session-listeners isled-session))
    (when (buffer-live-p (car listener))
      (with-current-buffer (car listener) (funcall (cdr listener)))))
  (dolist (view (isled-session-views isled-session))
    (when (buffer-live-p view)
      (with-current-buffer view (isled-expansion-clear))))
  (when-let ((view (seq-find #'buffer-live-p
                            (isled-session-views isled-session))))
    (with-current-buffer view (isled-loading-request 'refresh))))

(defun isled-session-submit (directory request callback &optional prepare)
  "Serialize REQUEST for DIRECTORY and call CALLBACK in its originating view.
Optional PREPARE rebuilds the request at dispatch; nil cancels obsolete demand."
  (if (not isled-session)
      (funcall isled-process-function directory request callback)
    (let* ((session isled-session)
           (input (json-parse-string request :object-type 'alist :array-type 'array
                                     :null-object :json-null :false-object :json-false)))
      (when (and (equal (alist-get 'mode input) "refresh")
                 (or (equal (isled-session-running-mode session) "refresh")
                     (seq-some (lambda (job) (equal (alist-get 'mode
                                              (json-parse-string (nth 1 job) :object-type 'alist))
                                             "refresh"))
                               (isled-session-queue session))))
        (setf (alist-get 'mode input) "view")
        (setq request (json-serialize input :null-object :json-null :false-object :json-false)))
      (setf (isled-session-queue session)
            (nconc (isled-session-queue session)
                   (list (list (current-buffer) request callback isled-process-function prepare))))
      (isled-session--start session))))

(defun isled-session--start (session)
  "Start the next useful queued request in SESSION."
  (unless (isled-session-running session)
    (when-let ((job (pop (isled-session-queue session))))
      (pcase-let ((`(,view ,request ,callback ,runner ,prepare) job))
        (if (not (buffer-live-p view)) (isled-session--start session)
          (with-current-buffer view
            (when prepare (setq request (funcall prepare)))
            (if (not request)
                (progn
                  (let ((isled-session-discarded t)) (funcall callback nil))
                  (isled-session--start session))
              (setf (isled-session-running session) t
                    (isled-session-running-mode session)
                    (alist-get 'mode (json-parse-string request :object-type 'alist)))
              (condition-case failure
                  (funcall runner (isled-session-root session) request
                           (lambda (result) (isled-session--finish session view callback result)))
                (error
                 (setf (isled-session-running session) nil
                       (isled-session-running-mode session) nil)
                 (isled-session--start session)
                 (signal (car failure) (cdr failure)))))))))))

(defun isled-session--finish (session view callback result)
  "Deliver RESULT to VIEW's CALLBACK and release SESSION's running slot."
  (unwind-protect
      (if (and (buffer-live-p view) (memq view (isled-session-views session)))
          (with-current-buffer view
            (let ((isled-session-delivered-mode
                   (intern (isled-session-running-mode session))))
              (funcall callback result)))
        (when (equal (isled-session-running-mode session) "refresh")
          (isled-session-refresh-survivors session result)))
    (setf (isled-session-running session) nil
          (isled-session-running-mode session) nil)
    (isled-session--start session)
    (isled-session-schedule session)))

(defun isled-session-refresh-survivors (session result &optional exclude)
  "Propagate a successful refresh RESULT after its origin stopped using it.
Update surviving SESSION views except EXCLUDE, preserving navigation."
  (when session
    (condition-case failure
        (progn
          (unless (eql (isled-command-result-status result) 0)
            (error "%s" (isled-snapshot--failure-message result)))
          (let ((response (isled-frontend-decode (isled-command-result-stdout result))))
            (unless (and (equal (isled-response-root response) (isled-session-root session))
                         (isled-response-view-hash response))
              (error "Invalid shared refresh response"))
            (dolist (view (isled-session-views session))
              (when (and (buffer-live-p view) (not (eq view exclude)))
                (with-current-buffer view
                  (unless isled-loading-pending
                    (isled-loading-request 'view)))))))
      (error
       (dolist (view (isled-session-views session))
         (when (buffer-live-p view)
           (with-current-buffer view (isled-loading--failure failure))))))))

(declare-function isled-warnings-accept "isled-warnings")

(defun isled-session-publish (response mode ids)
  "Share accepted RESPONSE with sibling views after request MODE for IDS."
  (when isled-session
    (dolist (view (isled-session-views isled-session))
      (when (and (buffer-live-p view) (not (eq view (current-buffer))))
        (with-current-buffer view
          (isled-warnings-accept response)
          (when (eq mode 'details) (setq isled-loading-range ids))
          (if (eq mode 'refresh)
              (unless (or (and isled-loading-pending
                               (memq (car isled-loading-pending) '(view refresh)))
                          (seq-some (lambda (job)
                                      (and (eq (car job) view)
                                           (member (alist-get 'mode (json-parse-string (nth 1 job) :object-type 'alist))
                                                   '("view" "refresh"))))
                                    (isled-session-queue isled-session)))
                (isled-loading-request 'view))
            (when (isled-response-changes response)
              (isled-loading-share response))))))))

(provide 'isled-session)
;;; isled-session.el ends here
