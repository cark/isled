;;; isled-loading.el --- Bounded request coordination  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Assisted-by: Codex:GPT-6
;; Keywords: tools

;;; Commentary:

;; Serialize asynchronous requests per view.  Refresh/filter replies establish
;; the heading list before nearby expanded details are selected.  Superseded
;; replies never replace a newer view, and scrolling never reconciles the ledger.

;;; Code:

(require 'isled-process)
(require 'isled-data)
(require 'isled-session)
(require 'isled-windows)
(require 'isled-viewport)
(require 'isled-navigation)
(require 'isled-filter-query)
(require 'isled-filter)
(require 'isled-expansion)

(defvar isled--root)
(defvar isled--snapshot)
(defvar isled--filter)
(defvar isled--auto-revert-error)
(defvar isled--rendering)
(declare-function isled--capture-view-state "isled-browser")
(declare-function isled--restore-view-state "isled-browser")
(declare-function isled--view-state-filter "isled-browser" (state))
(declare-function isled--view-state-graph-direction "isled-browser" (state))
(declare-function isled--window-anchors "isled-browser")
(declare-function isled--restore-window-anchors "isled-browser")
(declare-function isled-warnings-accept "isled-warnings")
(declare-function isled--update-header-line "isled-browser")

(defvar-local isled-loading-initializer nil
  "Setup callback retained until the first accepted view, independent of requests.")
(defvar-local isled-loading-active nil
  "Non-nil when this buffer uses the bounded frontend protocol.")
(defvar-local isled-loading-filter nil
  "Filter corresponding to the last accepted summary list.")
(defvar-local isled-loading-graph nil "Graph direction of the accepted view, or nil.")
(defvar-local isled-loading-graph-intent nil "Graph direction of the latest request.")
(defvar-local isled-loading-intent nil
  "Most recently requested status filter, including an in-flight switch.")
(defvar-local isled-loading-generation nil
  "Generation fence for refresh and filter requests.")
(defvar-local isled-loading-running nil
  "Non-nil while one process is in flight for this view.")
(defvar-local isled-loading-pending nil
  "Latest queued request, retaining its filter text and parsed criteria.")
(defvar-local isled-loading-timer nil
  "Shared timer yielding between extra body-formatting passes.")
(defvar-local isled-loading-range nil
  "Expanded IDs in the last successfully requested nearby range.")

(defconst isled-loading--gc-allowance (* 16 1024 1024)
  "Minimum allocation allowance while accepting one frontend reply.
The 5,000-issue switch experiment found repeated collections dominated latency.
This measured 16 MiB allowance batches that work without changing the user's
threshold outside reply processing or reducing a larger configured value.")

(defun isled-loading-request (mode &optional state callback criteria completion)
  "Queue MODE with destination STATE and optional successful CALLBACK.
Refresh and view requests obtain summaries first, then schedule nearby details.
CRITERIA may supply the already parsed destination filter; otherwise parse it.
COMPLETION is (CRITERIA CALLBACK) for independently fenced contextual choices."
  (let* ((filter (if state (isled--view-state-filter state) isled--filter))
         (graph (if state (isled--view-state-graph-direction state) isled-graph-direction))
         (criteria (or criteria (if (eq mode 'choices) '((status . "all"))
                                  (isled-filter-query-criteria filter)))))
    (unless (memq mode '(details choices))
      (isled-expansion-clear))
    (isled-windows-track #'isled-loading--display-changed)
    (setq isled-loading-active t)
    (unless (memq mode '(details choices))
      (setq isled-loading-intent filter)
      (setq isled-loading-graph-intent graph)
      (setq isled-loading-generation (list t))
      (setq isled-loading-range nil))
    ;; Cursor movement updates choice context without discarding a queued view.
    (when (and (eq mode 'choices) isled-loading-pending
               (memq (car isled-loading-pending) '(view refresh)))
      (setf (nth 6 isled-loading-pending) completion)
      (setq mode nil))
    ;; Movement cannot replace a pending reconciliation or filter change.
    (unless (or (null mode)
                (and (eq mode 'details) isled-loading-pending
                     (not (eq (car isled-loading-pending) 'details))))
      (when (eq (car isled-loading-pending) 'refresh)
        (setq mode 'refresh))
      (setq isled-loading-pending
            (list mode state callback
                  (and (or state callback) (isled-navigation-origin))
                  filter criteria completion graph)))
    (isled-loading--start-next)))

(defun isled-loading--start-next ()
  "Start the pending request when this buffer has no running process."
  (when (and isled-loading-pending (not isled-loading-running))
    (pcase-let* ((`(,mode ,state ,callback ,origin ,filter ,criteria ,completion ,graph)
                  isled-loading-pending)
                 (ids (when (eq mode 'details) (isled-session-nearby)))
                 (generation isled-loading-generation)
                 (buffer (current-buffer))
                 (request `((schema_version . 5) (mode . ,(symbol-name mode))
                            (filter . ,criteria)
                            (view_hash . ,(or (and (not (eq mode 'choices))
                                                   (equal filter isled-loading-filter)
                                                   isled-data-hash) :json-null))
                            (details . ,(isled-data-request-details ids)))))
      (when completion (push (cons 'choice_filter (car completion)) request))
      (when (and graph (memq mode '(view refresh)))
        (push `(graph . ((direction . ,(symbol-name graph))
                        (hash . ,(or isled-graph-hash :json-null)))) request))
      (setq isled-loading-pending nil)
      (if (and (eq mode 'details) (null ids))
          (progn
            (setq isled-loading-range nil)
            (when callback (funcall callback)))
        (setq isled-loading-running t)
        (condition-case failure
            (isled-session-submit
             (or isled--root default-directory)
             (json-serialize request :null-object :json-null)
             (lambda (result)
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (unwind-protect
                       (unless isled-session-discarded
                         (isled-loading--deliver
                          result mode filter state ids callback origin generation completion graph))
                     (setq isled-loading-running nil)
                     (isled-loading--start-next)))))
             (when (eq mode 'details)
               (lambda ()
                 (setq ids (isled-session-nearby))
                 (when ids
                   (json-serialize
                    `((schema_version . 5) (mode . "details")
                      (details . ,(isled-data-request-details ids)))
                    :null-object :json-null)))))
          (error
           (setq isled-loading-running nil)
           (when completion (funcall (cadr completion) nil failure))
           (isled-loading--failure failure)))))))

(defun isled-loading--deliver (result mode filter state ids callback origin generation &optional completion graph)
  "Deliver RESULT for MODE/FILTER and IDS if GENERATION and ORIGIN still apply.
Restore STATE and run CALLBACK only for a still-current navigation request.
COMPLETION retains independently fenced choice delivery; GRAPH is the direction."
  (if (and (eq generation isled-loading-generation)
           (isled-navigation-valid-p origin))
      (isled-navigation-at-origin
       origin (lambda () (isled-loading--receive result mode filter state ids callback completion graph)))
    (when (eq generation isled-loading-generation)
      (setq isled-loading-intent isled--filter
            isled-loading-graph-intent isled-graph-direction))
    (when (eq (or isled-session-delivered-mode mode) 'refresh)
      (isled-session-refresh-survivors isled-session result (current-buffer)))))

(defun isled-loading--receive (result mode filter state ids callback &optional completion graph)
  "Apply RESULT for MODE, FILTER, STATE and IDS, then run CALLBACK.
COMPLETION delivers independently fenced choices.
GRAPH is the requested direction."
  (setq mode (or isled-session-delivered-mode mode))
  (condition-case failure
      (progn
        (unless (eql (isled-command-result-status result) 0)
          (error "%s" (isled-snapshot--failure-message result)))
        (let* ((gc-cons-threshold (max gc-cons-threshold isled-loading--gc-allowance))
               (response (isled-frontend-decode
                          (isled-command-result-stdout result)))
               (anchors (unless (eq mode 'choices) (isled--window-anchors)))
               (destination (unless (eq mode 'choices)
                              (or state (isled--capture-view-state)))))
          (isled-loading--validate-response response mode ids)
          (when (memq mode '(view refresh))
            (isled-loading--validate-graph response graph))
          (when completion
            (unless (isled-response-choices-present response)
              (error "Missing requested completion choices"))
            (funcall (cadr completion) (isled-response-choices response)))
          (unless (or completion (eq mode 'details))
            (setq isled-filter-choices (isled-response-choices response)))
          (unless (eq mode 'choices)
            (isled-warnings-accept response)
            (setq isled--root (isled-response-root response))
            (isled-session-attach)
            (when (memq mode '(view refresh))
              (setq isled-loading-graph graph
                    isled-loading-graph-intent graph)
              (when-let ((reply (isled-response-graph response)))
                (setq isled-graph-hash (isled-graph-response-hash reply)
                      isled-graph-layout-direction (isled-graph-response-direction reply))
                (when (isled-graph-response-plan reply)
                  (setq isled-graph-layout (isled-graph-response-plan reply)))))
            (setq isled--snapshot
                  (if (or (isled-response-view response)
                          (isled-response-changes response))
                      (isled-data-accept response)
                    isled--snapshot)
                  isled--root (isled-response-root response)
                  default-directory (file-name-as-directory isled--root)
                  isled--auto-revert-error nil
                  isled-loading-filter filter
                  isled-loading-intent filter)
            (when (eq mode 'details)
              (setq isled-loading-range ids))
            (when (or state (isled-response-view response)
                      (and (isled-response-graph response)
                           (isled-graph-response-plan (isled-response-graph response)))
                      (isled-response-changes response))
              (isled-loading--present destination anchors))
            (isled--update-header-line)
            (isled-loading-schedule)
            (when isled-loading-initializer
              (let ((initialize isled-loading-initializer))
                (setq isled-loading-initializer nil)
                (funcall initialize)))
            (isled-session-publish response mode ids)
            (when callback (funcall callback)))))
    (error
     (when completion (funcall (cadr completion) nil failure))
     (isled-loading--failure failure))))

(defun isled-loading--validate-graph (response direction)
  "Validate RESPONSE's conditional layout against requested DIRECTION and view."
  (let ((reply (isled-response-graph response)))
    (if (not direction)
        (when reply (error "Unrequested graph layout"))
      (unless (and reply (eq direction (isled-graph-response-direction reply)))
        (error "Missing requested graph layout; update the Isled CLI"))
      (let* ((plan (or (isled-graph-response-plan reply)
                       (and (equal (isled-graph-response-hash reply) isled-graph-hash)
                            (eq direction isled-graph-layout-direction)
                            isled-graph-layout)))
             (view (or (isled-response-view response) isled-data-view))
             (issues (and view (isled-snapshot-issues view))))
        (unless (and plan (= (length issues) (length (isled-graph-plan-rows plan)))
                     (seq-every-p (lambda (issue)
                                    (gethash (isled-issue-id issue)
                                             (isled-graph-plan-index plan))) issues))
          (error "Graph membership does not match the requested view"))))))

(defun isled-loading--validate-response (response mode ids)
  "Check RESPONSE belongs to this MODE and requested IDS before any mutation."
  (when (and isled--root
             (not (equal isled--root (isled-response-root response))))
    (error "Ledger root changed while refreshing"))
  (if (memq mode '(details choices))
      (when (or (isled-response-view response)
                (isled-response-view-hash response))
        (error "Unexpected view in detail response"))
    (unless (and (isled-response-view-hash response)
                 (or (isled-response-view response)
                     (and isled-data-view
                          (equal isled-data-hash
                                 (isled-response-view-hash response)))))
      (error "Missing requested view")))
  (let ((changed (make-hash-table :test #'equal)))
    (dolist (detail (isled-response-changes response))
      (unless (member (isled-detail-id detail) ids)
        (error "Unrequested detail in response"))
      (puthash (isled-detail-id detail) t changed))
    (dolist (id ids)
      (unless (or (gethash id changed)
                  (and isled-data-details
                       (gethash id isled-data-details)))
        (error "Missing uncached detail %s" id)))))

(defun isled-loading--failure (failure)
  "Keep the last good view and expose FAILURE in its header."
  (setq isled--auto-revert-error (error-message-string failure)
        isled-loading-intent isled--filter
        isled-loading-graph-intent isled-graph-direction)
  (isled--update-header-line))

(defvar-local isled-loading-presented nil
  "Non-nil after this view has been presented in a live window.")

(defvar-local isled-loading-dirty nil
  "Non-nil when a hidden view needs its retained projection rendered.")

(defun isled-loading--present (destination anchors)
  "Render DESTINATION with ANCHORS, or defer a hidden view update."
  (isled-expansion-prune)
  (if (and (or isled-loading-presented isled-loading-initializer
               isled-loading-dirty)
           (not (isled-windows-visible)))
      (setq isled-loading-dirty destination)
    (when (isled-windows-visible) (setq isled-loading-presented t))
    (setq isled-loading-dirty nil)
    (let ((isled-sections--defer-rich t))
      (isled--restore-view-state destination)
      (isled--restore-window-anchors anchors))
    (isled-viewport-update)
    (isled-expansion-complete)))

(defun isled-loading-share (response)
  "Apply shared detail RESPONSE to this view without issuing a process."
  (when isled-data-view
    (let ((state (or isled-loading-dirty (isled--capture-view-state)))
          (anchors (isled--window-anchors)))
      (setq isled--snapshot
            (isled-data-accept
             (isled-response-create
              :root isled--root :changes (isled-response-changes response))))
      (isled-loading--present state anchors))))

(defun isled-loading--display-changed ()
  "Present cached visible text before redisplay; schedule asynchronous data demand."
  (when (isled-windows-visible) (setq isled-loading-presented t))
  (when (and isled-loading-dirty (isled-windows-visible))
    (isled-loading--present isled-loading-dirty (isled--window-anchors)))
  (isled-viewport-update)
  (isled-loading-schedule))

(defun isled-loading-schedule ()
  "Dispatch needed data now and schedule incremental extra presentation."
  (when (and isled-loading-active isled-data-view
             (not isled--rendering))
    (isled-windows-track #'isled-loading--display-changed)
    (if isled-session
        (isled-session-schedule isled-session)
      (isled-loading--request-needed (current-buffer)))
    (unless (isled-windows-visible) (setq isled-loading-range nil))))

(defun isled-loading--request-needed (buffer)
  "Request current demand in live BUFFER as soon as its transport is free."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (unless (or isled--auto-revert-error isled-loading-running
                  isled-loading-pending
                  (and isled-session (isled-session-running isled-session)))
        (let ((ids (isled-session-nearby)))
          (unless (equal ids isled-loading-range)
            (if ids (isled-loading-request 'details)
              (setq isled-loading-range nil))))))))

(defun isled-loading-stop ()
  "Invalidate replies and timers on buffer death or a major-mode change."
  (isled-windows-stop)
  (isled-expansion-clear)
  (when isled-session
    (setq isled-loading-timer nil)
    (isled-session-detach))
  (setq isled-loading-generation (list t))
  (when (timerp isled-loading-timer)
    (cancel-timer isled-loading-timer))
  (setq isled-loading-timer nil isled-loading-pending nil
        isled-loading-active nil isled-loading-initializer nil))

(provide 'isled-loading)
;;; isled-loading.el ends here
