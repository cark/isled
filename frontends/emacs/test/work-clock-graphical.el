;;; work-clock-graphical.el --- Live heading clock acceptance -*- lexical-binding: t; -*-

;; Run through scripts/private-graphical-emacs.py, never a working daemon.
(setq load-prefer-newer t)
(require 'isled)
(require 'isled-browser)
(require 'isled-work)

(unless (and (getenv "PI_RESULT") (getenv "ISLED_TEST_PROGRAM")
             (display-graphic-p) (not (daemonp)))
  (error "Use the private graphical runner with ISLED_TEST_PROGRAM"))

(setq isled-program (getenv "ISLED_TEST_PROGRAM")
      isled-use-development-cli t
      isled-auto-revert nil)
(defvar isled-clock-root (make-temp-file "isled-clock-" t))
(defvar isled-clock-processes 0)

(defun isled-clock-cli (&rest arguments)
  "Run ARGUMENTS against the disposable ledger."
  (with-temp-buffer
    (unless (zerop (apply #'call-process isled-program nil t nil
                         "--root" isled-clock-root arguments))
      (error "Clock CLI failed: %s" (buffer-string)))
    (buffer-string)))

(defun isled-clock-wait (predicate)
  "Wait for PREDICATE with ordinary redisplay and asynchronous callbacks."
  (let ((deadline (+ (float-time) 10)))
    (while (not (funcall predicate))
      (when (> (float-time) deadline) (error "Clock view timed out"))
      (sit-for 0.05))))

(defun isled-clock-settled ()
  "Return non-nil once current view and body requests have completed."
  (and isled--snapshot (not isled-loading-running) (not isled-loading-pending)
       (not isled-loading-timer)))

(defun isled-clock-label ()
  "Return issue 0001's current display label."
  (when-let ((overlay (and isled-work-display--overlays
                           (gethash (gethash "0001" isled-rows-index)
                                    isled-work-display--overlays))))
    (overlay-get overlay 'display)))

(defun isled-clock-capture (name)
  "Save the visible frame as NAME beside the runner's result."
  (redisplay t)
  (let ((coding-system-for-write 'binary))
    (write-region (x-export-frames nil 'png) nil
                  (expand-file-name name (file-name-directory (getenv "PI_RESULT")))
                  nil 'silent)))

(defun isled-clock-check-ticks (prefix)
  "Verify real ticks preserve layout, and save two frames named with PREFIX."
  (isled-clock-wait #'isled-clock-settled)
  (isled-clock-wait #'isled-clock-label)
  (sit-for 0.3)
  (let ((label (isled-clock-label)) (text (buffer-string))
        (tick (buffer-chars-modified-tick)) (position (point))
        (start (window-start)) (count isled-clock-processes)
        (expanded (isled-sections-expanded-ids)))
    (unless (string-match-p "1h [0-9][0-9]m [0-9][0-9]s" label)
      (error "Missing live hour/minute/second label: %S" label))
    (isled-clock-capture (concat prefix "-before.png"))
    (isled-clock-wait (lambda () (not (equal label (isled-clock-label)))))
    (isled-clock-capture (concat prefix "-after.png"))
    (unless (and (equal text (buffer-string)) (= tick (buffer-chars-modified-tick))
                 (= position (point)) (= start (window-start))
                 (= count isled-clock-processes)
                 (equal expanded (isled-sections-expanded-ids)))
      (error "Clock tick changed text/navigation/layout or requested data"))))

(defun isled-clock-run ()
  "Exercise ticking, hierarchy, navigation, pause and resume after startup."
  (condition-case failure
      (progn
        (menu-bar-mode -1) (tool-bar-mode -1) (scroll-bar-mode -1)
        (load-theme 'modus-vivendi-tinted t)
        (set-frame-font "DejaVu Sans Mono-13" nil t)
        (set-frame-size nil 1080 680 t)
        (isled-clock-cli "init")
        (isled-clock-cli "add" "Keep notes available offline"
                         "Save reading notes locally and preserve them across restarts."
                         "--kind" "feature")
        (isled-clock-cli "add" "Sync notes after reconnecting"
                         "Send the local changes after the connection returns."
                         "--kind" "feature")
        (isled-clock-cli "wait" "add" "2" "1" "Local notes must survive disconnection.")
        (isled-clock-cli "work" "start" "1" "--at"
                         (format-time-string "%Y-%m-%d %H:%M:%S"
                                             (time-subtract (current-time) 3660) t))
        (isled-clock-cli "work" "queue" "2")
        (advice-add 'isled-process-command :before
                    (lambda (&rest _) (cl-incf isled-clock-processes)))
        (isled isled-clock-root)
        (delete-other-windows)
        (isled-clock-wait #'isled-clock-settled)
        (isled-listing-order 'id)
        (isled-clock-wait #'isled-clock-settled)
        (isled-sections-goto-id "0001")
        (isled-clock-check-ticks "flat")
        (isled-listing-order 'hierarchy)
        (isled-clock-wait (lambda () (and isled-graph-direction (isled-clock-settled))))
        (isled-sections-show (gethash "0001" isled-rows-index))
        (isled-clock-check-ticks "hierarchy-expanded")
        (isled-sections-hide (gethash "0001" isled-rows-index))
        (isled-sections-goto-id "0002")
        (set-window-start (selected-window) (isled-row-start (gethash "0001" isled-rows-index)))
        (isled-clock-check-ticks "hierarchy-neighbor")
        ;; Normal window observation removes scheduling while the view is hidden.
        (let ((view (current-buffer)) (timer isled-work-display--timer))
          (switch-to-buffer (get-buffer-create " *clock-hidden*"))
          (isled-clock-wait (lambda () (not (buffer-local-value 'isled-work-display--timer view))))
          (when (memq timer timer-list) (error "Hidden clock still scheduled"))
          (sit-for 1.2)
          (switch-to-buffer view)
          (isled-clock-wait #'isled-clock-label))
        (isled-sections-goto-id "0001")
        (isled-work-pause)
        (isled-clock-wait (lambda () (and (isled-clock-settled) (not (isled-clock-label)))))
        (when isled-work-display--timer (error "Paused clock still scheduled"))
        (isled-work-start)
        (isled-clock-wait #'isled-clock-label)
        (isled-clock-check-ticks "resumed")
        (isled-work-await-review)
        (isled-clock-wait (lambda () (and (isled-clock-settled) (not (isled-clock-label)))))
        (isled-clock-cli "check")
        (kill-buffer (current-buffer))
        (delete-directory isled-clock-root t)
        (with-temp-file (getenv "PI_RESULT") (insert "(:passed t)\n"))
        (kill-emacs 0))
    (error
     (isled-clock-capture "failure.png")
     (with-temp-file (getenv "PI_RESULT") (insert (format "failed: %S\n" failure)))
     (kill-emacs 1))))

(run-at-time 0.2 nil #'isled-clock-run)
