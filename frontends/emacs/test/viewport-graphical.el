;;; viewport-graphical.el --- Native viewport integration checks -*- lexical-binding: t; -*-

;; Run with the private graphical runner; batch display fixtures stay disabled.
(setq load-prefer-newer t)
(require 'isled-windows-test)
(require 'isled-expansion-test)

(unless (and (getenv "PI_RESULT") (display-graphic-p) (not (daemonp)))
  (error "Use the private graphical runner"))

(defvar isled-viewport-check-results nil)

(defun isled-viewport-check-reset ()
  "Reset body presentation to exercise fresh formatting at the current scale."
  (let ((inhibit-read-only t) (isled-sections--defer-rich t))
    (isled-rows-clear)
    (erase-buffer)
    (isled-sections-insert isled--snapshot 'all isled--expanded-ids))
  (isled-windows-test--point (selected-window) "0001"))

(defun isled-viewport-check-visible ()
  "Return fixture rows actually intersecting a displayed window."
  (seq-filter
   (lambda (row)
     (seq-some
      (lambda (window)
        (and (> (isled-row-end row) (window-start window))
             (pos-visible-in-window-p
              (max (isled-row-start row) (window-start window)) window t)))
      (isled-windows-visible)))
   (append isled-rows nil)))

(defun isled-viewport-check-coverage (name)
  "Check body formatting, loading and gutter coverage for NAME."
  (isled-viewport-update)
  (redisplay t)
  (let ((visible (isled-viewport-check-visible))
        (demand (isled-windows-nearby))
        (gutters (isled-graph-gutter-nearby-rows)))
    (unless visible (error "%s: no visible fixture rows" name))
    (dolist (row visible)
      (unless (isled-row-rich row)
        (error "%s: visible body %s remains unformatted" name (isled-row-value row)))
      (unless (member (isled-row-value row) demand)
        (error "%s: visible issue %s is outside loading demand" name (isled-row-value row)))
      (unless (gethash row gutters)
        (error "%s: visible issue %s is outside gutter coverage" name (isled-row-value row))))
    (when (or (>= (length demand) 100) (>= (hash-table-count gutters) 100))
      (error "%s: preparation reached too far into the 250-issue fixture" name))
    (push (list :case name :visible (length visible) :demand (length demand)
                :gutters (hash-table-count gutters)) isled-viewport-check-results)))

(defun isled-viewport-check-layout ()
  "Exercise scaled bodies, split windows, scrolling and an impending recenter."
  (isled-windows-test--with-view
    (setq isled--expanded-ids
          (mapcar #'isled-issue-id (isled-snapshot-issues isled--snapshot)))
    (dolist (issue (isled-snapshot-issues isled--snapshot))
      (setf (isled-issue-content issue) "**Notes** for the next implementation step.\n"))
    (dolist (scale '(0 -2 2))
      (text-scale-set scale)
      (isled-viewport-check-reset)
      (isled-viewport-check-coverage (format "bodies-scale-%s" scale)))
    (text-scale-set -2)
    (isled-viewport-check-reset)
    (let ((other (split-window-below)))
      (isled-windows-test--point other "0200")
      (isled-viewport-check-coverage "distant-split")
      (delete-window other))
    (isled-viewport-check-reset)
    ;; No intervening redisplay: prepare the destination of a distant jump.
    (isled-sections-goto-id "0200")
    (isled-viewport-check-coverage "impending-recenter")
    (isled-windows-test--point (selected-window) "0100")
    (set-window-vscroll (selected-window) 7 t)
    (isled-viewport-check-coverage "partial-body")))

(defun isled-viewport-check-run ()
  "Run native geometry and expansion checks after private frame startup."
  (condition-case failure
      (progn
        (menu-bar-mode -1) (tool-bar-mode -1) (scroll-bar-mode -1)
        (set-frame-font "DejaVu Sans Mono-13" nil t)
        (set-frame-size nil 1080 680 t)
        (isled-viewport-check-layout)
        (let ((stats (ert-run-tests-batch "^isled-expansion-")))
          (unless (zerop (ert-stats-completed-unexpected stats))
            (error "Graphical expansion regressions failed"))
          (push (list :expansion-tests (ert-stats-total stats)) isled-viewport-check-results))
        (with-temp-file (getenv "PI_RESULT")
          (prin1 (list :passed t :checks (nreverse isled-viewport-check-results)) (current-buffer)))
        (kill-emacs 0))
    (error
     (let ((coding-system-for-write 'binary))
       (write-region (x-export-frames nil 'png) nil
                     (expand-file-name "failure.png" (file-name-directory (getenv "PI_RESULT")))
                     nil 'silent))
     (with-temp-file (getenv "PI_RESULT")
       (prin1 (list :failure failure :checks (nreverse isled-viewport-check-results)) (current-buffer)))
     (kill-emacs 1))))

(run-at-time 0.2 nil #'isled-viewport-check-run)
