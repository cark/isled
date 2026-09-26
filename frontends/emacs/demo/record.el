;;; record.el --- Record the README tour in private Emacs -*- lexical-binding: t; -*-

;; Run only through scripts/private-graphical-emacs.py.  The runner owns the
;; display, HOME, temporary ledger and process cleanup; no user init is loaded.

(unless (and (getenv "PI_RESULT") (getenv "ISLED_DEMO_PROGRAM")
             (display-graphic-p) (not (daemonp)))
  (error "Use the private graphical runner with ISLED_DEMO_PROGRAM"))

(setq load-prefer-newer t
      inhibit-startup-screen t
      ring-bell-function #'ignore
      isled-auto-revert nil
      isled-filter-inline-auto nil
      isled-program (getenv "ISLED_DEMO_PROGRAM"))
(require 'isled)
(require 'isled-browser)
(require 'isled-entry)

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
      (error "Demo CLI failed: %s" (buffer-string)))))

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
      (cancel-timer isled-demo-timer)
      (with-temp-file (getenv "PI_RESULT")
        (prin1 '(:passed t :clips (hierarchy filtering) :fictional-issues 10)
               (current-buffer)))
      (kill-emacs 0))
  (error
   (when (timerp isled-demo-timer) (cancel-timer isled-demo-timer))
   (with-temp-file (getenv "PI_RESULT") (prin1 failure (current-buffer)))
   (kill-emacs 1)))
