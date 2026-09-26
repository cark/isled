;;; isled-browser.el --- Browse project issue ledgers  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT

;; Author: Sacha De Vos
;; Keywords: tools

;;; Commentary:

;; A local, read-only expandable frontend for the Rust isled
;; command.  Invoke `isled' from a directory inside an initialized
;; project.  Each canonical ledger can own multiple independent view buffers.

;;; Code:

(require 'isled)

(require 'cl-lib)
(require 'isled-sections)
(require 'isled-snapshot)
(require 'isled-view)
(require 'seq)
(require 'transient)
(require 'isled-header)
(require 'isled-warnings)
(require 'isled-jump)
(require 'isled-auto-refresh)
(require 'isled-loading)
(require 'isled-buffers)
(require 'isled-navigation)
(require 'isled-expansion)
(require 'isled-source)
(require 'isled-filter)
(require 'isled-graph)

(declare-function isled-sections-point-state
                  "isled-sections")
(declare-function isled-sections-restore-point-state
                  "isled-sections")

(defface isled-help-key-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face used for activation keys in the persistent help line."
  :group 'isled)

(defface isled-help-delimiter-face
  '((t :inherit font-lock-comment-delimiter-face))
  "Face used for brackets and separators in the persistent help line."
  :group 'isled)

(defface isled-help-text-face
  '((t :inherit font-lock-doc-face))
  "Face used for descriptions in the persistent help line."
  :group 'isled)

(defvar-local isled--root nil
  "Canonical ledger root displayed by the current buffer.")

(defvar-local isled--snapshot nil
  "Latest validated snapshot displayed by the current buffer.")

(defvar-local isled--header-count 0
  "Visible issue count, updated when the view is rendered.")

(defvar-local isled--filter 'open
  "Status filter active in the current buffer.")

(defvar-local isled--selected-id nil
  "Selected issue identifier in the current buffer.")

(defvar-local isled--expanded-ids nil
  "Issue identifiers whose sections are expanded in the current buffer.")

(defvar-local isled--last-collapse-by-filter nil
  "Last collapsed issue-relative position for each filter in this buffer.
This is filter memory, not jump history: restoring a jump must not resurrect
a position discarded by a later collapse-all.")

(cl-defstruct (isled--view-state
               (:constructor isled--view-state-create))
  "Opaque restorable state for one issue filter."
  filter
  selected-id
  expanded-ids
  point-state
  preferred-state
  ledger-point
  (graph-direction 'prerequisites))

(defvar-local isled--saved-view-states nil
  "Association list of filters and their last captured view states.")

(defvar-local isled--back-history nil
  "Opaque view states preceding the current semantic location.")

(defvar-local isled--forward-history nil
  "Opaque view states following the current semantic location.")

(defvar-local isled--rendering nil
  "Non-nil while the current buffer is being rendered.")

(defvar-local isled--auto-revert-error nil
  "Most recent automatic refresh error, or nil after a successful refresh.")

(defconst isled--layout-version 18
  "Current buffer layout version for upgrading source-loaded views.")

(defvar-local isled--buffer-layout-version 0
  "Layout version initialized in the current ledger buffer.")

(defun isled--migrate-mode-map ()
  "Retire obsolete package defaults once, without reinstalling current keys."
  (when (< isled--mode-map-version 1)
    (dolist (binding '(("o" . isled-filter-open)
                       ("c" . isled-filter-closed)
                       ("a" . isled-filter-all)
                       ("s" . isled-search)))
      (when (eq (keymap-lookup isled-mode-map (car binding))
                (cdr binding))
        (keymap-unset isled-mode-map (car binding))))
    (setq isled--mode-map-version 1))
  (when (< isled--mode-map-version 2)
    ;; One-time migration of the former issue action; preserve owner overrides.
    (when (memq (keymap-lookup isled-mode-map "c") '(isled-create-issue isled-add-issue))
      (keymap-set isled-mode-map "c" #'isled-close-issue))
    (unless (keymap-lookup isled-mode-map "a")
      (keymap-set isled-mode-map "a" #'isled-add-issue))
    (setq isled--mode-map-version 2))
  (when (< isled--mode-map-version 3)
    (unless (keymap-lookup isled-mode-map "!")
      (keymap-set isled-mode-map "!" #'isled-jump-to-warning))
    (setq isled--mode-map-version 3))
  (when (< isled--mode-map-version 4)
    (unless (keymap-lookup isled-mode-map "j")
      (keymap-set isled-mode-map "j" #'isled-jump-to-issue))
    (setq isled--mode-map-version 4))
  (when (< isled--mode-map-version 5)
    (dolist (binding '(("v" . isled-graph-toggle) ("d" . isled-graph-reverse)
                       ("O" . isled-filter-open) ("C" . isled-filter-closed)
                       ("A" . isled-filter-all) ("M-n" . isled-graph-next-match)
                       ("M-p" . isled-graph-previous-match)))
      (unless (keymap-lookup isled-mode-map (car binding))
        (keymap-set isled-mode-map (car binding) (cdr binding))))
    (setq isled--mode-map-version 5))
  (when (< isled--mode-map-version 6)
    (dolist (binding '(("v" . isled-graph-toggle)
                      ("M-n" . isled-graph-next-match)
                      ("M-p" . isled-graph-previous-match)))
      (when (eq (keymap-lookup isled-mode-map (car binding)) (cdr binding))
        (keymap-unset isled-mode-map (car binding))))
    (setq isled--mode-map-version 6))
  (when (< isled--mode-map-version 7)
    (unless (keymap-lookup isled-mode-map "v")
      (keymap-set isled-mode-map "v" #'isled-graph-toggle))
    (setq isled--mode-map-version 7)))

(isled--migrate-mode-map)

(define-derived-mode isled-mode special-mode "Project-Issues"
  "Major mode for a read-only project issue ledger.

Each buffer represents one view of a canonical ledger.  Issues are expandable
sections whose complete canonical content is displayed inline."
  ;; Generated replacements must not retain old rows through undo history.
  (buffer-disable-undo)
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  (font-lock-mode -1)
  (setq-local revert-buffer-function #'isled--revert-buffer)
  (setq-local buffer-stale-function #'isled--buffer-stale-p)
  ;; The generic non-file handler drops child-content change events.  This mode
  ;; therefore owns its directory watch and uses Auto Revert only as fallback.
  (setq-local buffer-auto-revert-by-notification nil)
  (isled--update-header-line)
  (setq-local isled--buffer-layout-version
              isled--layout-version)
  (when (bound-and-true-p hl-line-mode)
    (hl-line-mode -1))
  (add-hook 'change-major-mode-hook
            #'isled--stop-auto-refresh nil t)
  (add-hook 'kill-buffer-hook #'isled--stop-auto-refresh nil t)
  (add-hook 'change-major-mode-hook #'isled-loading-stop nil t)
  (add-hook 'kill-buffer-hook #'isled-loading-stop nil t)
  (add-hook 'post-command-hook #'isled-loading-schedule t t)
  (add-hook 'post-command-hook #'isled--track-point nil t)
  (add-hook 'post-command-hook #'isled--mark-unmodified t t))

(defun isled-refresh ()
  "Refresh the current ledger while retaining filter and selection."
  (interactive nil isled-mode)
  (isled--refresh nil))

(defun isled--refresh (_automatic)
  "Refresh asynchronously, preserving the last good view on failure."
  (isled-expansion-clear)
  (if isled-session-owner-p
      (isled-session-refresh)
    (isled-loading-request 'refresh)))

(defun isled--revert-buffer (&optional _ignore-auto _noconfirm)
  "Regenerate the current non-file view for `revert-buffer'."
  (isled--refresh t))

(defun isled--update-header-line ()
  "Arrange per-window identity and refresh diagnostics at redisplay time."
  (when (and isled-session-owner-p isled-session)
    (let ((warning isled--auto-refresh-warning))
      (dolist (view (isled-session-views isled-session))
        (when (buffer-live-p view)
          (with-current-buffer view (setq isled--auto-refresh-warning warning))))))
  (setq-local header-line-format
              '(:eval (isled-header-mode-line (isled--header-line))))
  (force-mode-line-update t))

(defun isled--header-line ()
  "Return the identity header for the window being redisplayed."
  (let* ((root (or (isled-context-current) default-directory))
         (roots (delq nil (mapcar
                           (lambda (buffer)
                             (with-current-buffer buffer (isled-context-current)))
                           (buffer-list))))
         (label (propertize (isled-header-directory root roots)
                            'help-echo (abbreviate-file-name root)))
         (diagnostic
          (cond
           (isled--auto-revert-error
            (propertize (concat "Auto-refresh failed: "
                                isled--auto-revert-error)
                        'face 'isled-error-face))
           (isled--auto-refresh-warning
            (propertize (concat "Auto-refresh using polling: "
                                isled--auto-refresh-warning)
                        'face 'isled-warning-face)))))
    (isled-header-format
     label (isled-graph-header-filter isled--filter) isled--header-count
     (window-body-width) (concat (isled-warnings-indicator) (isled--fontified-help))
     (if isled-filter-active
         (propertize (or isled-filter-feedback diagnostic isled-filter-help)
                     'face (cond (isled-filter-feedback
                                  'isled-warning-face)
                                 (diagnostic 'isled-error-face)
                                 (t 'isled-help-text-face)))
       diagnostic)
     (and isled--root (not (equal root isled--root)) isled--root))))

(defun isled--fontified-help ()
  "Return a help hint reflecting the current mode-map binding."
  (let* ((binding (where-is-internal #'isled-help
                                     isled-mode-map t))
         (key (if binding (key-description binding)
                "M-x isled-help"))
         (help (propertize (format "[%s] Help" key)
                           'face 'isled-help-text-face)))
    (put-text-property 0 1 'face 'isled-help-delimiter-face help)
    (put-text-property 1 (1+ (length key))
                       'face 'isled-help-key-face help)
    (put-text-property (1+ (length key)) (+ 2 (length key))
                       'face 'isled-help-delimiter-face help)
    help))

(defun isled-filter-all ()
  "Show issues of every status, retaining the current issue."
  (interactive nil isled-mode)
  (isled--set-filter 'all))

(defun isled-filter-open ()
  "Display open issues in the current ledger."
  (interactive nil isled-mode)
  (isled--set-filter 'open))

(defun isled-filter-closed ()
  "Display closed issues in the current ledger."
  (interactive nil isled-mode)
  (isled--set-filter 'closed))

(defun isled-next ()
  "Move to the next issue heading or actionable expanded-body target."
  (interactive nil isled-mode)
  (isled--move-selection 1))

(defun isled-previous ()
  "Move to the previous issue heading or actionable expanded-body target."
  (interactive nil isled-mode)
  (isled--move-selection -1))

(defun isled-open ()
  "Open the selected issue's canonical file read-only."
  (interactive nil isled-mode)
  (let* ((id (or (isled-sections-id-at-point)
                 isled--selected-id))
         (issue (and id
                     (isled-view-find-issue
                      (isled-snapshot-issues isled--snapshot)
                      id))))
    (unless issue
      (user-error "No issue is selected"))
    (let ((isled-inhibit-file-routing t))
      (find-file-read-only (isled-issue-path issue)))))

(defun isled-next-issue ()
  "Move to the next issue heading, skipping links."
  (interactive nil isled-mode)
  (isled--move-selection 1 t))

(defun isled-previous-issue ()
  "Move to the previous issue heading, skipping links."
  (interactive nil isled-mode)
  (isled--move-selection -1 t))

(defun isled-activate ()
  "Activate the link at point, or toggle the containing issue."
  (interactive nil isled-mode)
  (pcase (get-text-property (point) 'isled-target)
    ('warning-action (isled--warning-action))
    ('issue-reference (isled-jump-to-reference))
    ('markdown-link (isled--activate-markdown-link))
    (_
     (if (get-text-property (point) 'isled-reference)
         (user-error "The referenced issue does not exist")
       (if (isled-sections-id-at-point)
           (isled--toggle-issue)
         (user-error "No issue is selected"))))))

(defun isled--warning-action ()
  "Execute the explicit diagnostic action at point, then refresh this view."
  (let* ((payload (get-text-property (point) 'isled-warning-action))
         (action (nth 0 payload)) (source (nth 1 payload))
         (target (nth 2 payload)) (needs-reason (nth 3 payload)))
    (pcase action
      ('open-file (let ((isled-inhibit-file-routing t)) (find-file source)))
      ('trash-file
       (unless (and (file-regular-p source) (not (file-symlink-p source)))
         (user-error "Not a regular issue file; refresh and inspect %s" source))
       (when (yes-or-no-p (format "Move %s to trash? " source))
         (move-file-to-trash source)
         (isled--refresh-after-warning)))
      ((or 'complete 'remove)
       (let* ((args (list "wait" "repair" (symbol-name action) source target))
              (args (if (and (eq action 'complete) needs-reason)
                        (append args (list "--reason" (read-string "Dependency reason: ")))
                      args))
              (result (isled-snapshot--run-process isled--root args)))
         (unless (equal (isled-command-result-status result) 0)
           (user-error "%s" (isled-command-result-stderr result)))
         (isled--refresh-after-warning)
         (unless (string-empty-p (isled-command-result-stderr result))
           (message "%s" (string-trim (isled-command-result-stderr result)))))))))

(defun isled--window-anchors (&optional preferred-id)
  "Capture viewport anchors, preferring PREFERRED-ID in this window."
  (mapcar
   (lambda (window)
     (save-excursion
       (goto-char (window-start window))
       (let* ((id (or (and (eq window (selected-window)) preferred-id)
                      (isled-sections-id-at-point)))
              (state (save-excursion
                       (goto-char (window-point window))
                       (isled-sections-point-state)))
              (lines (when (and id (isled-sections-goto-id id))
                       (let ((start (window-start window)) (heading (point)))
                         (* (if (< start heading) -1 1)
                            (count-screen-lines (min start heading) (max start heading)
                                                nil window))))))
         (list window id lines state))))
   (get-buffer-window-list (current-buffer) nil t)))

(defun isled--restore-window-anchors (anchors)
  "Restore ANCHORS where possible, allowing Emacs to keep point visible."
  (dolist (anchor anchors)
    (when anchor
      (pcase-let ((`(,window ,id ,lines ,state) anchor))
        (when (and (window-live-p window)
                   (eq (window-buffer window) (current-buffer)))
          (set-window-point
           window
           (if (eq window (selected-window)) (point)
             (save-excursion
               (isled-sections-restore-point-state state)
               (point))))
          (save-excursion
            (when (and lines (isled-sections-goto-id id))
              (vertical-motion lines window)
              (set-window-start window (point) t))))))))

(defun isled--refresh-after-warning ()
  "Refresh an action's issue, landing on a remaining warning or its heading."
  (let* ((id (isled-sections-id-at-point))
         (index (or (get-text-property (point) 'isled-warning-index) 0))
         (anchors (isled--window-anchors id)))
    (isled-loading-request
     'refresh nil
     (lambda ()
       (isled-loading-request
        'details nil
        (lambda () (isled--restore-warning-position id index anchors)))))))

(defun isled--restore-warning-position (id index anchors)
  "Restore the surviving warning INDEX for ID and its window ANCHORS."
  (if (and id (isled-sections-goto-id id))
      (let* ((section (isled-row-at))
             (end (isled-row-end section))
             (position (point)) targets)
        (while (< position end)
          (let ((next (next-single-property-change
                       position 'isled-warning-index nil end)))
            (when-let ((ordinal (get-text-property position 'isled-warning-index)))
              (push (cons ordinal
                          (or (text-property-any position next 'isled-target
                                                 'warning-action)
                              position)) targets))
            (setq position next)))
        (setq targets (nreverse targets))
        (when targets
          (goto-char (cdr (nth (min index (1- (length targets))) targets)))))
    ;; A ledger-level action has no issue anchor: prefer its next control.
    (unless id
      (goto-char (point-min))
      (when-let ((position (text-property-any
                            (point-min) (point-max) 'isled-target 'warning-action)))
        (goto-char position))))
  (isled--track-point)
  (isled--restore-window-anchors anchors))

(defun isled--toggle-issue ()
  "Toggle the issue at point, remembering one collapse position per filter."
  (isled-navigation-with-window
    (let* ((section (isled-row-at))
           (saved (alist-get isled--filter
                             isled--last-collapse-by-filter nil nil #'equal)))
      (if (isled-row-hidden section)
          (progn
            (isled-sections-show section)
            (when (equal (car-safe saved) (isled-row-value section))
              (isled-sections-restore-point-state saved))
            (isled-expansion-request))
        (setf (alist-get isled--filter
                         isled--last-collapse-by-filter nil nil #'equal)
              (isled-sections-point-state))
        (isled-expansion-collapse
         section
         (lambda ()
           (isled-sections-hide section)
           (goto-char (isled-row-start section))))))))

(defun isled-collapse-all ()
  "Collapse every issue in the current view."
  (interactive nil isled-mode)
  (isled-navigation-with-window
    (isled-expansion-clear)
    (setf (alist-get isled--filter isled--last-collapse-by-filter nil nil #'equal)
          nil)
    (when isled-rows-index
      (dolist (section (append isled-rows nil))
        (isled-sections-hide section))
      (setq isled--expanded-ids nil))))

(defun isled-activate-mouse (event)
  "Activate the target clicked by mouse EVENT."
  (interactive "e")
  (mouse-set-point event)
  (isled-activate))

(defun isled-jump-to-reference ()
  "Jump to the issue referenced at point and record semantic history."
  (interactive nil isled-mode)
  (isled-navigation-with-window
    (cond
     ((eq (get-text-property (point) 'isled-target)
          'issue-reference)
      (let ((origin (isled--capture-view-state)))
        (isled--visit-reference
         (lambda ()
           (isled-navigation-record origin)))))
     ((get-text-property (point) 'isled-reference)
      (user-error "The referenced issue does not exist"))
     (t
      (user-error "No issue reference at point")))))

(defun isled-history-back ()
  "Restore the previous semantic issue location."
  (interactive nil isled-mode)
  (isled-navigation-with-window
    (unless isled--back-history
      (user-error "No earlier issue location"))
    (let ((destination (car isled--back-history))
          (origin (isled--save-current-view-state)))
      (isled--restore-view-state
       destination
       (lambda ()
         (setq isled--back-history (cdr isled--back-history))
         (isled-navigation-record origin 'back))))))

(defun isled-history-forward ()
  "Restore the next semantic issue location."
  (interactive nil isled-mode)
  (isled-navigation-with-window
    (unless isled--forward-history
      (user-error "No later issue location"))
    (let ((destination (car isled--forward-history))
          (origin (isled--save-current-view-state)))
      (isled--restore-view-state
       destination
       (lambda ()
         (setq isled--forward-history (cdr isled--forward-history))
         (isled-navigation-record origin 'forward))))))

(defun isled--visit-reference (&optional callback)
  "Visit the issue reference at point, then run successful CALLBACK."
  (let* ((reference (get-text-property (point) 'isled-reference))
         (target-id (or (get-text-property (point) 'isled-target-id)
                        (isled-inline-reference-target-id reference)))
         (target (isled-view-find-target isled--snapshot target-id)))
    (isled--visit-issue target callback)))

(defun isled--visit-issue (target &optional callback)
  "Reveal typed TARGET through normal navigation, then run successful CALLBACK."
  (let* ((target-id (isled-issue-id target))
         (target-filter
          (if (equal (isled-issue-status target) "closed")
              'closed
            'open)))
    (if (and isled--snapshot
             (or (stringp isled--filter)
                 (eq isled--filter 'all)
                 (eq isled--filter target-filter))
             (or (not isled-loading-active)
                 (equal isled-loading-intent isled--filter))
             (isled-view-find-issue (isled--visible-issues) target-id))
        (progn
          (setq isled--selected-id target-id)
          (isled-sections-goto-id target-id)
          (isled-sections-show (isled-row-at))
          (isled-expansion-request)
          (when callback (funcall callback)))
      (isled--save-current-view-state)
      (when (eq isled--filter 'all) (setq target-filter 'all))
      (let ((state (copy-isled--view-state
                    (or (alist-get target-filter isled--saved-view-states)
                        (isled--initial-view-state target-filter)))))
        (setf (isled--view-state-filter state) target-filter
              (isled--view-state-graph-direction state) isled-graph-direction
              (isled--view-state-selected-id state) target-id
              (isled--view-state-point-state state) (cons target-id 0))
        (cl-pushnew target-id (isled--view-state-expanded-ids state) :test #'equal)
        (if isled-loading-active
            (isled-loading-request
             'view state (lambda () (isled-expansion-request)
                           (when callback (funcall callback))))
          (isled--restore-view-state
           state (lambda () (isled-expansion-request)
                   (when callback (funcall callback)))))))))

(defun isled--activate-markdown-link ()
  "Follow the Markdown link at point relative to its issue record."
  (let* ((id (isled-sections-id-at-point))
         (issue (isled-view-find-issue
                 (isled-snapshot-issues isled--snapshot)
                 id))
         (buffer-file-name (isled-issue-path issue))
         (default-directory (file-name-directory buffer-file-name)))
    (markdown-follow-thing-at-point nil)))

(defun isled--help-display (buffer _alist)
  "Display BUFFER by splitting only the selected issue window."
  (let ((window (condition-case nil
                    (split-window (selected-window) nil 'below)
                  (error (user-error "Not enough room below this issue view for help")))))
    (set-window-buffer window buffer)
    (set-window-dedicated-p window t)
    window))

(defun isled--help-motion ()
  "Keep ordinary movement active; dismiss help for other outside commands."
  (if (memq this-command
            '(forward-char backward-char right-char left-char
                           next-line previous-line forward-word backward-word
                           move-beginning-of-line move-end-of-line beginning-of-buffer
                           end-of-buffer scroll-up-command scroll-down-command
                           mwheel-scroll mouse-set-point))
      transient--stay
    transient--exit))

(defun isled--help-activate ()
  "Keep help for issue actions, but dismiss before following a Markdown link."
  (if (eq (get-text-property (point) 'isled-target) 'markdown-link)
      transient--exit
    transient--stay))

(transient-define-prefix isled-help ()
  "Show actions for the current project issue view."
  :transient-suffix t
  :transient-non-suffix #'isled--help-motion
  :display-action '(isled--help-display)
  [["Navigate"
    ("TAB" "Next item" isled-next)
    ("<backtab>" "Previous item" isled-previous)
    ("C-<tab>" "Next issue" isled-next-issue)
    ("C-S-<tab>" "Previous issue" isled-previous-issue)
    ("j" "Jump to issue" isled-jump-to-issue)
    ("M-." "Follow reference" isled-jump-to-reference)
    ("!" "Known warning" isled-jump-to-warning)
    ""
    "History"
    ("M-," "Back" isled-history-back)
    ("C-M-," "Forward" isled-history-forward)]
   ["Filter"
    ("O" "Open" isled-filter-open)
    ("C" "Closed" isled-filter-closed)
    ("A" "All" isled-filter-all)
    ("f" "Filter issues" isled-filter)
    ""
    "Display"
    ("v" "Hierarchical / flat" isled-graph-toggle)
    ("d" "Reverse graph direction" isled-graph-reverse :if-non-nil isled-graph-direction)
    ("g" "Refresh" isled-refresh)]
   ["Read"
    ("RET" "Toggle / follow" isled-activate
     :transient isled--help-activate)
    ("C-<return>" "Collapse all" isled-collapse-all)
    ("s" "Markdown source" isled-open-source :transient nil)
    ""
    "Change"
    ("a" "Add issue" isled-add-issue :transient nil)
    ("e" "Edit issue" isled-edit-issue :transient nil)
    ("c" "Close issue" isled-close-issue :transient nil)
    ""
    "Exit"
    ("q" "Dismiss menu" transient-quit-one)
    ("Q" "Quit view" quit-window :transient nil)]]
  ;; Explicit bindings survive Transient's map rebuild after a suffix.
  ;; Keep these out of the legend: they are ordinary buffer navigation.
  [:hide (lambda () t)
         ("<tab>" "Next issue / link" isled-next)
         ("C-<backtab>" "Previous issue" isled-previous-issue)
         ("C-S-<iso-lefttab>" "Previous issue" isled-previous-issue)
         ("<up>" "Previous line" previous-line)
         ("<down>" "Next line" next-line)
         ("<left>" "Backward character" left-char)
         ("<right>" "Forward character" right-char)
         ("C-n" "Next line" next-line)
         ("C-p" "Previous line" previous-line)
         ("C-v" "Page down" scroll-up-command)
         ("M-v" "Page up" scroll-down-command)
         ("<next>" "Page down" scroll-up-command)
         ("<prior>" "Page up" scroll-down-command)]
  (interactive nil isled-mode)
  (transient-setup 'isled-help))

(defun isled--buffer-for-root (root &optional except)
  "Return the ledger buffer for ROOT, excluding EXCEPT when supplied."
  (seq-find (lambda (buffer)
              (and (not (eq buffer except))
                   (with-current-buffer buffer
                     (and (derived-mode-p 'isled-mode)
                          (and isled--root
                               (equal (directory-file-name isled--root)
                                      (directory-file-name root)))))))
            (buffer-list)))

(defun isled--buffer-name (root)
  "Return a descriptive buffer name for canonical ROOT."
  (format "*isled: %s*"
          (abbreviate-file-name (directory-file-name root))))

(defun isled--visible-issues ()
  "Return issues matching the current buffer's filter."
  (isled-view-visible-issues
   isled--snapshot isled--filter (and isled-graph-direction isled-graph-layout)))

(defun isled--set-filter (filter)
  "Switch to FILTER, retaining visible point or restoring its saved view."
  (when (stringp isled--filter)
    (setq filter (isled-filter-query-status isled--filter filter)))
  (isled-navigation-with-window
    (unless (equal (or (and isled-loading-active isled-loading-intent)
                    isled--filter) filter)
      (isled-expansion-clear)
      (let* ((origin (isled--save-current-view-state))
             (destination (copy-isled--view-state
                           (or (alist-get filter isled--saved-view-states nil nil #'equal)
                               origin))))
        (setf (isled--view-state-filter destination) filter
              (isled--view-state-graph-direction destination) isled-graph-direction
              (isled--view-state-preferred-state destination) origin)
        (isled--restore-view-state destination)))))

(defun isled--move-selection (offset &optional issues-only)
  "Move through stops by OFFSET without wrapping, skipping links if ISSUES-ONLY."
  (if-let ((id (isled-sections-move offset issues-only)))
      (setq isled--selected-id id)
    (unless (isled--visible-issues)
      (user-error "No %s issues" isled--filter))))

(defun isled--render (&optional point-state)
  "Render current state, restoring POINT-STATE or the selected issue."
  (isled-graph-gutter-overflow)
  (let ((inhibit-read-only t)
        (isled--rendering t))
    (isled-sections-render
     isled--snapshot
     isled--filter
     isled--expanded-ids)
    (setq isled--header-count
          (length (isled--visible-issues)))
    (goto-char (point-min))
    (unless (isled-sections-restore-point-state point-state)
      (when isled--selected-id
        (isled-sections-goto-id isled--selected-id)))
    (set-buffer-modified-p nil)))

(defun isled--remember-expanded-ids ()
  "Remember the current sections' visibility before rebuilding the view."
  (when isled-rows-index
    (setq isled--expanded-ids
          (isled-sections-expanded-ids))))

(defun isled--capture-view-state ()
  "Capture the current view as an opaque restorable value."
  (isled--remember-expanded-ids)
  (isled--view-state-create
   :filter isled--filter
   :graph-direction isled-graph-direction
   :selected-id isled--selected-id
   :expanded-ids (copy-sequence isled--expanded-ids)
   :point-state (isled-sections-point-state)
   :ledger-point (isled-sections-ledger-point-state)))

(defun isled--state-for-filter (query)
  "Capture this view's position with QUERY as its destination filter."
  (let ((state (isled--capture-view-state)))
    (setf (isled--view-state-filter state) query)
    state))

(defun isled--save-current-view-state ()
  "Save and return the current filter's view state."
  (let ((state (isled--capture-view-state)))
    (when (or (memq isled--filter '(open closed)) (stringp isled--filter))
      (setf (alist-get isled--filter isled--saved-view-states
                       nil nil #'equal)
            state))
    state))

(defun isled--initial-view-state (filter)
  "Return the collapsed initial view state for FILTER."
  (isled--view-state-create :filter filter))

(defun isled--restore-filter-view (filter)
  "Restore the saved view for FILTER, or its initial view."
  (isled--restore-view-state
   (or (alist-get filter isled--saved-view-states nil nil #'equal)
       (isled--initial-view-state filter))))

(defun isled--restore-view-state (state &optional callback)
  "Restore STATE and run CALLBACK after its filtered summaries are available."
  (if (and isled-loading-active
           (or (not (eq (isled--view-state-graph-direction state) isled-loading-graph))
               (not (eq (isled--view-state-graph-direction state) isled-loading-graph-intent))
               (not (equal (isled--view-state-filter state)
                        isled-loading-filter))
               (not (equal (isled--view-state-filter state)
                        isled-loading-intent))))
      (isled-loading-request 'view state callback)
    (let ((anchors (isled--window-anchors)))
      (isled--restore-loaded-view-state state)
      (isled--restore-window-anchors anchors))
    (when callback (funcall callback))))

(defun isled--restore-loaded-view-state (state)
  "Restore opaque view STATE against the already loaded filtered list."
  (let* ((filter (isled--view-state-filter state))
         (graph (isled--view-state-graph-direction state))
         (issues (isled-view-visible-issues
                  isled--snapshot filter (and graph isled-graph-layout)))
         (issue-index (isled-view-index-issues issues))
         (state (isled--prefer-visible-state state issue-index))
         (point-state (isled--view-state-point-state state))
         (point-id (car-safe point-state))
         (point-visible (and point-id
                             (gethash point-id issue-index)))
         (replacement-id
          (and point-id
               (not point-visible)
               (isled-view-replacement-id issues point-id)))
         (selected-id
          (cond
           (point-visible point-id)
           (replacement-id replacement-id)
           (t (isled-view-select-id
               issues (isled--view-state-selected-id state)))))
         (restored-point
          (cond
           (point-visible point-state)
           (replacement-id (cons replacement-id 0)))))
    (setq isled--filter filter
          isled-graph-direction graph
          isled--selected-id selected-id
          isled--expanded-ids
          (seq-filter
           (lambda (id) (gethash id issue-index))
           (isled--view-state-expanded-ids state)))
    (isled--render restored-point)
    (isled-sections-restore-ledger-point (isled--view-state-ledger-point state))))

(defun isled--prefer-visible-state (state issue-index)
  "Resolve STATE's preferred cursor against the newly loaded ISSUE-INDEX."
  (let* ((preferred (isled--view-state-preferred-state state))
         (id (and preferred
                  (or (car (isled--view-state-point-state preferred))
                      (isled--view-state-selected-id preferred)))))
    (if (not (and id (gethash id issue-index))) state
      (let ((resolved (copy-isled--view-state state)))
        (setf (isled--view-state-selected-id resolved) id
              (isled--view-state-point-state resolved)
              (isled--view-state-point-state preferred)
              (isled--view-state-expanded-ids resolved)
              (append (isled--view-state-expanded-ids state)
                      (isled--view-state-expanded-ids preferred)))
        resolved))))

(defun isled--track-point ()
  "Update selection when point lands on a different issue row."
  (isled-navigation-with-window
    (unless isled--rendering
      (when-let ((id (isled-sections-id-at-point)))
        (unless (equal id isled--selected-id)
          (setq isled--selected-id id))))))

(defun isled--mark-unmodified ()
  "Keep the generated ledger buffer from acquiring modified state."
  (when (buffer-modified-p)
    (set-buffer-modified-p nil)))

(provide 'isled-browser)
;;; isled-browser.el ends here
