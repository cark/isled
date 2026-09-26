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
       '(("Ship the offline reading beta" "release" "beta"
          "Let the first group of readers try Trail Notes on a weekend trip. Saved guides, reading progress and keyboard navigation should work together before we send invitations.")
         ("Keep saved guides available offline" "feature" "offline"
          "Readers should be able to open a saved guide on a train or trail without a connection. Keep downloaded text and maps available after restarting the app.")
         ("Sync reading progress across devices" "feature" "sync"
          "Resume a guide on the same paragraph when moving from a phone to a tablet. Keep local progress while offline and reconcile it after reconnecting.")
         ("Make the library keyboard-friendly" "feature" "accessibility"
          "Let readers reach every saved guide and download action using a keyboard. Keep focus visible and return it to the card after closing its details.")
         ("Resume interrupted downloads" "bug" "offline"
          "A dropped connection currently restarts the whole download. Resume from the last complete chunk and keep the previous saved guide usable until its replacement is ready.")
         ("Store guides and progress locally" "feature" "offline"
          "Keep downloaded guides and reading positions on the device. Store them together so a guide is never marked available before its content is complete.")
         ("Merge progress after reconnecting" "bug" "sync"
          "Reconnecting a tablet must not replace newer phone progress with an older position. Preserve deliberate resets and explain conflicts only when a reader needs to choose.")
         ("Keep focus visible in library cards" "bug" "accessibility"
          "The download button loses its focus outline in the compact layout. Make keyboard focus clear in both light and dark themes.")
         ("Handle edits made on two devices" "feature" "sync"
          "Retain the order of reading-position changes made on separate devices. Use the recorded edit time and preserve an explicit return to the beginning.")
         ("Explain storage use before downloading" "docs" "offline"
          "Show the expected download size before saving a guide. Explain how to remove downloads without losing bookmarks or reading progress.")
         ("Fix long titles on narrow screens" "bug" "mobile"
          "Long guide titles overlap the saved indicator on small phones. Let titles wrap while keeping the download action reachable.")
         ("Polish the empty-library message" "docs" "onboarding"
          "Tell new readers how to save their first guide and where it will appear. Keep the message short and useful before the first download.")))
    (isled-demo-cli "add" (nth 0 issue) (nth 3 issue)
                    "--kind" (nth 1 issue) "--tag" (nth 2 issue)))
  (isled-demo-cli "tag" "add" "6" "sync")
  (dolist (relation
           '(("1" "2" "Beta readers need guides available without a connection.")
             ("1" "3" "Reading position must follow readers between devices.")
             ("1" "4" "Include keyboard users in the first beta.")
             ("2" "5" "Downloads must survive a dropped connection.")
             ("2" "6" "Save the guide locally before making it available offline.")
             ("3" "6" "Keep a local reading position while disconnected.")
             ("3" "7" "Reconnecting must keep the newer reading position.")
             ("4" "8" "Clear focus is needed to navigate the library cards.")
             ("7" "9" "Define conflict order before implementing the merge.")
             ("10" "2" "Document the download behavior readers will actually get.")))
    (isled-demo-cli "wait" "add" (car relation) (cadr relation)
                    (nth 2 relation)))
  (isled-demo-cli "evidence" "add" "12" "Reviewed the empty library on phone and tablet layouts.")
  (isled-demo-cli "close" "12" "--outcome" "New readers can find and save their first guide."))

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
      (isled-demo-hold 2.5 "Dependencies keep the next useful step in view")
      (isled-demo-select "0005")
      (isled-demo-hold 0.7 "RET  ·  Read the issue")
      (isled-activate)
      (isled-demo-wait)
      (isled-demo-hold 3 "RET  ·  Read the issue")
      (search-forward "#0002")
      (backward-char)
      (isled-jump-to-reference)
      (isled-demo-wait)
      (isled-demo-hold 2 "M-.  ·  Follow an issue reference")
      (isled-history-back)
      (isled-demo-wait)
      (isled-demo-hold 1.5 "M-,  ·  Return to your place")
      (isled-demo-select "0005")
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
      (isled-demo-filter-input "s:open t:sync reconnecting")
      (isled-demo-wait)
      (isled-demo-hold 2.5 "Combine tags with words anywhere in the issue")
      (setq isled-demo-clip nil)
      (cancel-timer isled-demo-timer)
      (with-temp-file (getenv "PI_RESULT")
        (prin1 '(:passed t :clips (hierarchy filtering) :fictional-issues 12)
               (current-buffer)))
      (kill-emacs 0))
  (error
   (when (timerp isled-demo-timer) (cancel-timer isled-demo-timer))
   (with-temp-file (getenv "PI_RESULT") (prin1 failure (current-buffer)))
   (kill-emacs 1)))
