;;; work-clock-geometry-graphical.el --- Scaled clock viewport checks -*- lexical-binding: t; -*-

;; Real font geometry requires the private graphical runner, not batch Emacs.
(setq load-prefer-newer t)
(require 'isled-work-display-test)

(unless (and (getenv "PI_RESULT") (display-graphic-p) (not (daemonp)))
  (error "Use the private graphical runner"))

(defvar isled-clock-geometry-results nil)

(defun isled-clock-geometry-capture (name)
  "Save the current frame as NAME beside the runner's result."
  (let ((coding-system-for-write 'binary))
    (write-region (x-export-frames nil 'png) nil
                  (expand-file-name name (file-name-directory (getenv "PI_RESULT")))
                  nil 'silent)))

(defun isled-clock-geometry-check (name)
  "Check clock coverage against actual displayed headings; record NAME."
  (redisplay t)
  ;; The test oracle may scan the fixture; the production path must stay bounded.
  (let* ((windows (isled-windows-visible))
         (actual (seq-filter
                  (lambda (row)
                    (seq-some
                     (lambda (window)
                       (and (> (isled-row-heading-end row) (window-start window))
                            (pos-visible-in-window-p
                             (max (window-start window) (isled-row-start row)) window t)))
                     windows))
                  (append isled-rows nil)))
         (computed (isled-work-display--visible)))
    (unless (and (= (length actual) (hash-table-count computed))
                 (seq-every-p (lambda (row) (gethash row computed)) actual))
      (error "%s: %d displayed headings, %d clocks, missing %S, extra %S"
             name (length actual) (hash-table-count computed)
             (mapcar #'isled-row-value (seq-remove (lambda (row) (gethash row computed)) actual))
             (mapcar #'isled-row-value (seq-remove (lambda (row) (memq row actual))
                                                  (hash-table-keys computed)))))
    (isled-work-display-update)
    (unless (= (length actual) (hash-table-count isled-work-display--overlays))
      (error "%s: visible headings did not receive clock overlays" name))
    (push (list :case name :headings (length actual)) isled-clock-geometry-results)
    (redisplay t)
    (isled-clock-geometry-capture (concat name ".png"))
    (length actual)))

(defun isled-clock-geometry-scales ()
  "Check small and large fonts, split windows and partial screen lines."
  (isled-work-display-test--with-view
    (let (counts)
      (dolist (scale '(0 -2 2))
        (text-scale-set scale)
        (goto-char (point-min))
        (set-window-start (selected-window) (point-min))
        ;; Exercise fresh layout before redisplay, too.
        (isled-work-display-update)
        (push (isled-clock-geometry-check (format "scale-%s" scale)) counts))
      (unless (and (< (car counts) (nth 2 counts)) (> (nth 1 counts) (nth 2 counts)))
        (error "Font scaling did not change the visible heading count: %S" counts)))
    (text-scale-set -2)
    (let ((other (split-window-below)))
      (isled-windows-test--point other "0200")
      (isled-work-display-update)
      (isled-clock-geometry-check "split-small")
      (delete-window other))
    (set-window-vscroll (selected-window) 7 t)
    (isled-clock-geometry-check "partial-lines")))

(defun isled-clock-geometry-wakeup ()
  "Verify scaling alone starts and stops a previously idle clock."
  (isled-work-display-test--with-view
    (let ((target (gethash "0030" isled-rows-index)))
      (cl-loop for row across isled-rows
               unless (eq row target) do (setf (isled-issue-work (isled-row-issue row)) nil)))
    (isled--render)
    (text-scale-set 2)
    (goto-char (point-min))
    (set-window-start (selected-window) (point-min))
    (isled-windows-track #'isled-loading--display-changed)
    (redisplay t)
    (when isled-work-display--timer (error "Offscreen clock was scheduled"))
    (let ((position (point)) (start (window-start)) (tick (buffer-chars-modified-tick)))
      (text-scale-set -2)
      (redisplay t)
      (unless (and isled-work-display--timer (isled-work-display-test--label "0030"))
        (error "Scaling did not wake the newly visible clock"))
      (let ((label (isled-work-display-test--label "0030"))
            (deadline (+ (float-time) 3)))
        (while (and (equal label (isled-work-display-test--label "0030"))
                    (< (float-time) deadline))
          (sit-for 0.1))
        (when (equal label (isled-work-display-test--label "0030"))
          (error "Newly visible clock did not tick")))
      (text-scale-set 2)
      (redisplay t)
      (when (or isled-work-display--timer isled-work-display--overlays)
        (error "Scaling did not stop the now-hidden clock"))
      (unless (and (= position (point)) (= start (window-start))
                   (= tick (buffer-chars-modified-tick)))
        (error "Scaling check changed text or navigation")))
    (push '(:case "scale-wakeup-and-stop" :passed t) isled-clock-geometry-results)))

(defun isled-clock-geometry-run ()
  "Run the geometry regression checks after private frame startup."
  (condition-case failure
      (progn
        (menu-bar-mode -1) (tool-bar-mode -1) (scroll-bar-mode -1)
        (set-frame-font "DejaVu Sans Mono-13" nil t)
        (set-frame-size nil 1080 680 t)
        (isled-clock-geometry-scales)
        (isled-clock-geometry-wakeup)
        (with-temp-file (getenv "PI_RESULT")
          (prin1 (list :passed t :checks (nreverse isled-clock-geometry-results)) (current-buffer)))
        (kill-emacs 0))
    (error
     (isled-clock-geometry-capture "failure.png")
     (with-temp-file (getenv "PI_RESULT") (prin1 failure (current-buffer)))
     (kill-emacs 1))))

(run-at-time 0.2 nil #'isled-clock-geometry-run)
