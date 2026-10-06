;;; record.el --- Record the README tour in private Emacs -*- lexical-binding: t; -*-

;; Run only through scripts/private-graphical-emacs.py.  The runner owns the
;; display, HOME, temporary ledger and process cleanup; no user init is loaded.

(unless (and (getenv "PI_RESULT") (getenv "ISLED_DEMO_PROGRAM")
             (display-graphic-p) (not (daemonp)))
  (error "Use the private graphical runner with ISLED_DEMO_PROGRAM"))

(setq isled-use-development-cli t
      load-prefer-newer t
      inhibit-startup-screen t
      ring-bell-function #'ignore
      isled-auto-revert nil
      isled-filter-inline-auto nil
      isled-program (getenv "ISLED_DEMO_PROGRAM"))
(require 'isled)
(require 'isled-browser)
(require 'isled-entry)
(require 'isled-editor)

(defvar isled-demo-root (expand-file-name "trail-notes" "~"))
(defvar isled-demo-output
  (expand-file-name "frames" (file-name-directory (getenv "PI_RESULT"))))
(defvar isled-demo-clip nil)
(defvar isled-demo-frame 0)
(defvar isled-demo-timer nil)

(defun isled-demo-cli (&rest arguments)
  "Run ARGUMENTS against the disposable demonstration ledger."
  (with-temp-buffer
    (unless (zerop (apply #'call-process isled-program nil t nil
                         "--root" isled-demo-root arguments))
      (error "Demo CLI failed: %s" (buffer-string)))
    (buffer-string)))

(defun isled-demo-fixture ()
  "Create a fictional reading app backlog through the CLI."
  (make-directory isled-demo-root)
  (isled-demo-cli "init")
  (dolist
      (issue
       '(("Ship the offline reading beta" "milestone" "beta"
          "Invite the first readers to try Trail Notes on a weekend trip. Release the beta once downloading and reading a saved guide have passed a complete offline trial.")
         ("Verify offline reading on a weekend trip" "validation" "offline"
          "Save a guide, interrupt the download, then finish it and switch to airplane mode. Check that every page remains available after restarting the app before inviting beta readers.")
         ("Resume interrupted guide downloads" "feature" "offline"
          "A dropped connection currently restarts the whole download. Resume from the last complete chunk and keep the previous saved guide usable until its replacement is ready.")
         ("Store saved guides on the device" "feature" "offline"
          "Keep downloaded text and maps available after restarting the app. Save each guide together with its download state so incomplete content is never shown as ready to read.")
         ("Sync reading progress across devices" "feature" "sync"
          "Resume a guide on the same paragraph when moving from a phone to a tablet. Connect the progress merge to sign-in and check the complete journey on both devices.")
         ("Merge progress after reconnecting" "feature" "sync"
          "Reconnecting a tablet must not replace newer phone progress with an older position. Preserve deliberate resets and explain conflicts only when a reader needs to choose.")
         ("Keep a local history of reading progress" "feature" "sync"
          "Record reading-position changes while the device is offline. Keep their order and distinguish an explicit return to the beginning from a reader who has not started yet.")
         ("Choose a rule for conflicting progress" "design" "sync"
          "Decide which position to keep when two devices change the same guide while offline. Write down examples for ordinary reading, deliberate resets and changes made at the same time.")
         ("Fix long guide titles on small phones" "bug" "mobile"
          "Long guide titles overlap the saved indicator on small phones. Let titles wrap while keeping the download action reachable.")
         ("Polish the empty-library message" "docs" "onboarding"
          "Tell new readers how to save their first guide and where it will appear. Keep the message short and useful before the first download.")))
    (isled-demo-cli "add" (nth 0 issue) (nth 3 issue)
                    "--kind" (nth 1 issue) "--tag" (nth 2 issue)))
  (dolist (relation
           '(("1" "2" "Complete the offline trial before inviting beta readers.")
             ("2" "3" "The trial must include recovery from an interrupted download.")
             ("3" "4" "Resuming a download needs durable local content and download state.")
             ("5" "6" "The cross-device journey needs a working progress merge.")
             ("6" "7" "The merge needs the ordered changes retained while offline.")
             ("6" "8" "Settle conflict behavior before implementing the merge.")))
    (isled-demo-cli "wait" "add" (car relation) (cadr relation)
                    (nth 2 relation)))
  (isled-demo-cli "evidence" "add" "10" "Reviewed the empty library on phone and tablet layouts.")
  (isled-demo-cli "close" "10" "--outcome" "New readers can find and save their first guide."))

(defun isled-demo-capture ()
  "Export the real displayed frame, preserving the package's rendering."
  (when isled-demo-clip
    (when (> isled-demo-frame 200) (error "Demo capture exceeded its frame limit"))
    (let* ((directory (expand-file-name isled-demo-clip isled-demo-output))
           (path (expand-file-name (format "%03d.png" isled-demo-frame) directory))
           (coding-system-for-write 'binary))
      (make-directory directory t)
      (redisplay t)
      (write-region (x-export-frames nil 'png) nil path nil 'silent)
      (setq isled-demo-frame (1+ isled-demo-frame)))))

(defun isled-demo-wait ()
  "Wait for normal asynchronous loading, bounded by a deadline."
  (let ((deadline (+ (float-time) 8)))
    (while (or isled-loading-running isled-loading-pending
               (not isled--snapshot))
      (when (> (float-time) deadline) (error "Demo view did not become ready"))
      (sit-for 0.05)))
  (sit-for 0.2))

(defun isled-demo-select (id)
  "Move to the real heading for ID."
  (let ((row (gethash id isled-rows-index)))
    (unless row (error "Demo issue not visible: %s" id))
    (goto-char (isled-row-start row))))

(defun isled-demo-hold (seconds caption)
  "Keep the displayed state for SECONDS with CAPTION in the echo area."
  (message "%s" caption)
  (sit-for seconds))

(defun isled-demo-filter-input (text)
  "Enter TEXT in the actual filter prompt, leaving time for live previews."
  (minibuffer-with-setup-hook
      (lambda ()
        (delete-minibuffer-contents)
        (run-at-time
         0.5 nil
         (lambda ()
           (condition-case failure
               (progn
                 (dolist (character (string-to-list text))
                   (execute-kbd-macro (char-to-string character))
                   (sit-for 0.14))
                 (sit-for 1.6)
                 (execute-kbd-macro (kbd "RET")))
             (error (message "Demo input failed: %S" failure)
                    (abort-recursive-edit))))))
    (call-interactively #'isled-filter)))

(defun isled-demo-type (text)
  "Type TEXT through the normal command loop at a readable pace."
  (dolist (character (string-to-list text))
    (execute-kbd-macro (if (= character ?\n) (kbd "RET")
                         (char-to-string character)))
    (sit-for 0.035)))

(defun isled-demo-editor-wait ()
  "Wait for the current draft's asynchronous operation."
  (let ((draft (current-buffer)) (deadline (+ (float-time) 8)))
    (while (and (buffer-live-p draft)
                (buffer-local-value 'isled-editor-busy draft))
      (when (> (float-time) deadline) (error "Demo editor did not become ready"))
      (sit-for 0.05)))
  (sit-for 0.2))

(defun isled-demo-editing ()
  "Record real issue creation, a follow-up edit and the saved result."
  (isled-demo-filter-input "s:open")
  (isled-demo-wait)
  (goto-char (point-min))
  (set-window-start nil (point-min))
  (setq isled-demo-frame 0 isled-demo-clip "editing")
  (isled-demo-hold 1.5 "a  ·  Turn a concern into an issue")
  (execute-kbd-macro "a")
  (execute-kbd-macro (kbd "C-x 1"))
  (setq mode-line-format nil)
  (isled-demo-hold 1 "Write a title, choose a kind, add a tag")
  (isled-demo-type "Show download size before saving")
  (execute-kbd-macro (kbd "C-<tab>"))
  (execute-kbd-macro (kbd "C-k"))
  (isled-demo-type "feature")
  (execute-kbd-macro (kbd "C-<tab>"))
  (isled-demo-type "offline")
  (execute-kbd-macro (kbd "C-<tab>"))
  (isled-demo-type "Show the guide size before a download starts.\nLet readers decide what fits on their phone.")
  (isled-demo-hold 2 "C-c C-c  ·  Save and return to the ledger")
  (execute-kbd-macro (kbd "C-c C-c"))
  (isled-demo-editor-wait)
  (unless (derived-mode-p 'isled-mode) (error "Demo creation did not return to the ledger"))
  (isled-demo-wait)
  (isled-demo-select "0011")
  (isled-demo-hold 2 "Saved as 0011  ·  e edits it again")
  (execute-kbd-macro "e")
  (isled-demo-editor-wait)
  (execute-kbd-macro (kbd "C-x 1"))
  (setq mode-line-format nil)
  (goto-char (widget-field-end (cdr (assoc "statement" isled-editor-fields))))
  (isled-demo-hold 1 "e  ·  Add a useful detail")
  (isled-demo-type "\n\nInclude maps in the total.")
  (isled-demo-hold 2 "C-c C-c  ·  Save the edit")
  (execute-kbd-macro (kbd "C-c C-c"))
  (isled-demo-editor-wait)
  (unless (derived-mode-p 'isled-mode) (error "Demo edit did not return to the ledger"))
  (isled-demo-wait)
  (isled-demo-select "0011")
  (when (isled-row-hidden (gethash "0011" isled-rows-index))
    (execute-kbd-macro (kbd "RET")))
  (isled-demo-wait)
  (recenter 3)
  (isled-demo-hold 3 "The saved issue is ready to pick up later")
  (let ((saved (isled-demo-cli "show" "11")))
    (unless (and (string-match-p "Show download size before saving" saved)
                 (string-match-p "\\*\\*Kind:\\*\\* feature" saved)
                 (string-match-p "Include maps in the total\\." saved))
      (error "Demo creation/edit did not persist")))
  (isled-demo-cli "check")
  (setq isled-demo-clip nil))

(defun isled-demo-work-action (key state running)
  "Use Work menu KEY and wait for STATE and RUNNING clock status."
  (execute-kbd-macro "w")
  (isled-demo-hold 0.9 "w  ·  Queue, timer and owner actions")
  (execute-kbd-macro key)
  (let ((deadline (+ (float-time) 8)))
    (while (let* ((row (gethash "0004" isled-rows-index))
                  (work (and row (isled-issue-work (isled-row-issue row)))))
             (not (and work (equal state (isled-work-data-state work))
                       (eq running (and (isled-work-data-running-since work) t)))))
      (when (> (float-time) deadline) (error "Work action did not reach %s" state))
      (sit-for 0.05)))
  (isled-demo-wait))

(defun isled-demo-work-tracking ()
  "Record work transitions and history through the real frontend."
  ;; Fictional earlier work makes completed time legible without a long capture.
  (let ((now (current-time)))
    (isled-demo-cli "work" "start" "4" "--activity" "Implementation"
                    "--at" (format-time-string "%Y-%m-%d %H:%M:%S"
                                                (time-subtract now 1440) t))
    (isled-demo-cli "work" "pause" "4" "--at"
                    (format-time-string "%Y-%m-%d %H:%M:%S"
                                        (time-subtract now 360) t))
    (isled-demo-cli "work" "unqueue" "4"))
  (isled-demo-filter-input "s:open t:offline")
  (isled-refresh)
  (isled-demo-wait)
  (isled-demo-select "0004")
  (recenter 2)
  (setq isled-demo-frame 0 isled-demo-clip "work-tracking")
  (isled-demo-hold 2 "Pick up where the previous session stopped")
  (isled-demo-work-action "q" "queued" nil)
  (isled-demo-hold 2 "Queued  ·  Ready for the next work session")
  (isled-demo-work-action "s" "in-progress" t)
  (isled-demo-hold 3 "Start / resume  ·  The timer is running")
  (isled-demo-work-action "p" "in-progress" nil)
  (isled-demo-hold 2 "Pause clock  ·  Breaks stay out of the total")
  (isled-demo-work-action "s" "in-progress" t)
  (isled-demo-hold 2 "Resume  ·  Another session, another span")
  (isled-demo-work-action "r" "awaiting-owner" nil)
  (isled-demo-hold 2 "Ready for review  ·  Timing stops while you wait")
  (let ((view (current-buffer)) (deadline (+ (float-time) 8)) history)
    (execute-kbd-macro "w")
    (isled-demo-hold 0.9 "h  ·  See the sessions and their total")
    (execute-kbd-macro "h")
    (while (not (setq history
                      (get-buffer (format "*Isled work #0004: %s*" isled-demo-root))))
      (when (> (float-time) deadline) (error "Work history did not open"))
      (sit-for 0.05))
    (select-window (get-buffer-window history))
    (delete-other-windows)
    (setq mode-line-format nil)
    (isled-demo-hold 4 "One row per session  ·  The total includes all recorded work")
    (switch-to-buffer view)
    (isled-demo-select "0004")
    (isled-activate)
    (isled-demo-wait)
    (recenter 2)
    (isled-demo-hold 3 "The same work log stays in the Markdown issue"))
  (let ((report (json-parse-string (isled-demo-cli "work" "show" "4" "--json")
                                  :object-type 'alist :array-type 'list
                                  :null-object nil)))
    (unless (and (equal (alist-get 'state report) "awaiting-owner")
                 (equal (alist-get 'reason report) "review")
                 (= (length (alist-get 'spans report)) 3)
                 (>= (alist-get 'total_seconds report) 1080)
                 (null (alist-get 'running_since report)))
      (error "Demo work transitions/history did not persist")))
  (isled-demo-cli "check")
  (setq isled-demo-clip nil))

(condition-case failure
    (progn
      (menu-bar-mode -1)
      (tool-bar-mode -1)
      (scroll-bar-mode -1)
      (blink-cursor-mode -1)
      (load-theme 'modus-vivendi-tinted t)
      (set-frame-font "DejaVu Sans Mono-13" nil t)
      (set-frame-parameter nil 'internal-border-width 16)
      (set-frame-size nil 1080 680 t)
      (isled-demo-fixture)
      (isled isled-demo-root)
      (delete-other-windows)
      (isled-demo-wait)
      (setq mode-line-format nil)
      (setq isled-demo-timer (run-at-time 0 0.25 #'isled-demo-capture)
            isled-demo-clip "hierarchy")
      (isled-demo-hold 2.5 "Ready work first, followed by the steps it unblocks")
      (isled-demo-select "0004")
      (isled-demo-hold 0.7 "RET  ·  Read the issue")
      (isled-activate)
      (isled-demo-wait)
      (isled-demo-hold 3 "RET  ·  Read the issue")
      (search-forward "#0003")
      (backward-char)
      (isled-jump-to-reference)
      (isled-demo-wait)
      (isled-demo-hold 2 "M-.  ·  Follow an issue reference")
      (isled-history-back)
      (isled-demo-wait)
      (isled-demo-hold 1.5 "M-,  ·  Return to your place")
      (isled-demo-select "0004")
      (isled-activate)
      (goto-char (point-min))
      (set-window-start nil (point-min))
      (isled-demo-hold 1.5 "RET  ·  Fold it back into the plan")
      (isled-graph-reverse)
      (isled-demo-wait)
      (goto-char (point-min))
      (set-window-start nil (point-min))
      (isled-demo-hold 2.5 "d  ·  Follow dependencies in the other direction")
      (isled-graph-reverse)
      (isled-demo-wait)
      (goto-char (point-min))
      (set-window-start nil (point-min))
      (isled-demo-hold 1.5 "Ready issues keep their color in either direction")
      (setq isled-demo-clip nil)
      (goto-char (point-min))
      (set-window-start nil (point-min))
      (setq isled-demo-frame 0 isled-demo-clip "filtering")
      (isled-demo-hold 2 "f  ·  Find issues by tag, kind or text")
      (isled-demo-filter-input "s:open t:sync")
      (isled-demo-wait)
      (isled-demo-hold 2.5 "Only open sync work, with its visible dependencies")
      (isled-demo-filter-input "s:open t:sync tablet")
      (isled-demo-wait)
      (isled-demo-hold 2.5 "Combine tags with words anywhere in the issue")
      (setq isled-demo-clip nil)
      (isled-demo-editing)
      (isled-demo-work-tracking)
      (cancel-timer isled-demo-timer)
      (with-temp-file (getenv "PI_RESULT")
        (prin1 '(:passed t :clips (hierarchy filtering editing work-tracking)
                         :fictional-issues 11)
               (current-buffer)))
      (kill-emacs 0))
  (error
   (when (timerp isled-demo-timer) (cancel-timer isled-demo-timer))
   (with-temp-file (getenv "PI_RESULT") (prin1 failure (current-buffer)))
   (kill-emacs 1)))
