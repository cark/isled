;;; work-preparation-graphical.el --- Preparation menu and labels -*- lexical-binding: t; -*-

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
(defvar isled-preparation-root (make-temp-file "isled-preparation-" t))

(defun isled-preparation-cli (&rest arguments)
  "Run ARGUMENTS in the disposable test ledger."
  (with-temp-buffer
    (unless (zerop (apply #'call-process isled-program nil t nil
                         "--root" isled-preparation-root arguments))
      (error "Preparation CLI failed: %s" (buffer-string)))
    (buffer-string)))

(defun isled-preparation-wait (predicate)
  "Wait briefly for PREDICATE while allowing normal asynchronous work."
  (let ((deadline (+ (float-time) 10)))
    (while (not (funcall predicate))
      (when (> (float-time) deadline) (error "Preparation view timed out"))
      (sit-for 0.05)))
  (sit-for 0.2))

(defun isled-preparation-state-p (state)
  "Return whether the first issue's displayed work state is STATE."
  (when-let ((row (gethash "0001" isled-rows-index)))
    (equal (isled-work-data-state (isled-issue-work (isled-row-issue row))) state)))

(defun isled-preparation-capture (name)
  "Save the displayed frame as NAME in the runner's artifact directory."
  (redisplay t)
  (let ((coding-system-for-write 'binary))
    (write-region (x-export-frames nil 'png) nil
                  (expand-file-name name (file-name-directory (getenv "PI_RESULT")))
                  nil 'silent)))

(defun isled-preparation-run ()
  "Exercise the work menu after graphical startup completes."
  (condition-case failure
    (progn
      (menu-bar-mode -1)
      (tool-bar-mode -1)
      (scroll-bar-mode -1)
      (load-theme 'modus-vivendi-tinted t)
      (set-frame-font "DejaVu Sans Mono-13" nil t)
      (set-frame-size nil 1080 680 t)
      (isled-preparation-cli "init")
      (isled-preparation-cli "add" "Choose the offline conflict rule"
                             "Discuss how deliberate resets interact with newer reading progress."
                             "--kind" "design")
      (isled-preparation-cli "add" "Merge progress after reconnecting"
                             "Use the agreed conflict rule to merge local and remote progress."
                             "--kind" "feature")
      (isled-preparation-cli "wait" "add" "2" "1" "Settle the conflict rule first.")
      (isled-preparation-cli "work" "prepare" "2")
      (isled isled-preparation-root)
      (delete-other-windows)
      (isled-preparation-wait (lambda () (and isled--snapshot
                                              (not isled-loading-running))))
      (goto-char (isled-row-start (gethash "0001" isled-rows-index)))
      (execute-kbd-macro "w")
      (sit-for 0.3)
      (isled-preparation-capture "work-menu.png")
      (execute-kbd-macro "P")
      (isled-preparation-wait (lambda () (isled-preparation-state-p "planning")))
      (execute-kbd-macro (kbd "w m"))
      (isled-preparation-wait (lambda () (isled-preparation-state-p "prepared")))
      (let ((report (json-parse-string (isled-preparation-cli "work" "show" "1" "--json")
                                      :object-type 'alist :array-type 'list
                                      :null-object nil)))
        (unless (and (null (alist-get 'running_since report))
                     (null (alist-get 'spans report)))
          (error "Preparation started a clock")))
      (execute-kbd-macro (kbd "w P"))
      (isled-preparation-wait (lambda () (isled-preparation-state-p "planning")))
      (dolist (label '("Planning" "Prepared"))
        (unless (string-match-p (concat "\\[" label "\\]") (buffer-string))
          (error "Missing heading label: %s" label)))
      (isled-preparation-capture "preparation-headings.png")
      (isled-preparation-cli "check")
      (delete-directory isled-preparation-root t)
      (with-temp-file (getenv "PI_RESULT") (insert "(:passed t)\n"))
      (kill-emacs 0))
  (error
   (with-temp-file (expand-file-name "failure-messages.txt" (file-name-directory (getenv "PI_RESULT")))
     (insert (with-current-buffer "*Messages*" (buffer-string))))
   (isled-preparation-capture "failure.png")
   (with-temp-file (getenv "PI_RESULT") (insert (format "failed: %S\n" failure)))
   (kill-emacs 1))))

(run-at-time 0.2 nil #'isled-preparation-run)
