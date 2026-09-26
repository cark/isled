;;; isled-expansion-test.el --- Expansion viewport checks -*- lexical-binding: t; -*-

;;; Commentary:
;; Exercise real windows, display geometry, command entry and delayed delivery.
;;; Code:
(require 'ert)
(require 'isled-loading-test)
(require 'isled-view-test)


(defun isled-expansion-test--visible-p (position &optional window)
  "Check POSITION against WINDOW's text-screen bounds in headless tests."
  (let ((window (or window (selected-window))))
    (if (display-graphic-p)
        (progn (redisplay t) (pos-visible-in-window-p position window))
      (with-current-buffer (window-buffer window)
      (save-excursion
        (goto-char (window-start window))
        (vertical-motion (window-body-height window) window)
        (and (>= position (window-start window)) (< position (point))))))))

(defmacro isled-expansion-test--with-row (body-text &rest body)
  "Run BODY with one collapsed row containing BODY-TEXT near the window bottom."
  (declare (indent 1) (debug t))
  `(isled-loading-test--with-displayed-buffer
     (delete-other-windows)
     (isled-mode)
     (let* ((buffer (current-buffer))
            (snapshot (isled-view-test--open-snapshot "0001"))
            (issue (car (isled-snapshot-issues snapshot)))
            (window (selected-window)))
       (setf (isled-issue-content issue) ,body-text)
       (let ((inhibit-read-only t))
         (insert (make-string (- (window-body-height) 4) ?\n))
         (isled-sections-insert snapshot 'all nil))
       (let ((row (aref isled-rows 0)))
         (goto-char (isled-row-start row))
         (set-window-start window (point-min) t)
         (cl-letf (((symbol-function 'isled-loading-schedule) #'ignore))
           ,@body)))))

(ert-deftest isled-expansion-fitting-row-scrolls-only-as-needed ()
  (isled-expansion-test--with-row "First\nSecond\nThird\nFourth\n"
    (let ((point-before (point)) (start-before (window-start)))
      (isled--toggle-issue)
      (should (= (point) point-before))
      (should (> (window-start) start-before))
      (should (isled-expansion-test--visible-p (isled-row-start row)))
      (should (isled-expansion-test--visible-p (1- (isled-row-end row)))))
    (let ((start (window-start)))
      (isled-expansion-request)
      (should (= start (window-start))))))

(ert-deftest isled-expansion-fold-restores-original-viewport ()
  (isled-expansion-test--with-row "First\nSecond\nThird\nFourth\n"
    (let ((start-before (window-start)))
      (isled--toggle-issue)
      (should (> (window-start) start-before))
      (should isled-expansion--pending)
      (isled--toggle-issue)
      (should (= (window-start) start-before))
      (should-not isled-expansion--pending))))

(ert-deftest isled-expansion-guards-the-settled-viewport ()
  (isled-expansion-test--with-row "First\nSecond\nThird\nFourth\n"
    (let ((start-before (window-start)) redisplayed)
      (cl-letf (((symbol-function 'redisplay)
                 (lambda (&optional _force)
                   (setq redisplayed t)
                   ;; Model display-time normalization from `scroll-margin'.
                   (set-window-start window (1- (window-start window)) t)
                   (isled-expansion-prune))))
        (isled--toggle-issue))
      (let ((origin (alist-get window isled-expansion--pending)))
        (should redisplayed)
        (should origin)
        (should (= (window-start window)
                   (isled-expansion--origin-start origin))))
      (isled--toggle-issue)
      (should (= (window-start window) start-before)))))

(ert-deftest isled-expansion-does-not-retain-unchanged-viewport ()
  (isled-expansion-test--with-row "Short body\n"
    (set-window-start window (isled-row-start row) t)
    (isled--toggle-issue)
    (should-not isled-expansion--pending)))

(ert-deftest isled-expansion-oversized-keeps-point-visible ()
  (isled-expansion-test--with-row (make-string 100 ?\n)
    (let ((point-before (point)))
      (isled--toggle-issue)
      (should (= point-before (point)))
      (should (= (window-start) (isled-row-start row)))
      (should (isled-expansion-test--visible-p (point)))
      (should-not (isled-expansion-test--visible-p (1- (isled-row-end row)))))
    ;; Reopening retains the existing saved body cursor contract.
    (goto-char (+ (isled-row-content row) 40))
    (let ((saved (point)))
      (isled--toggle-issue)
      (isled--toggle-issue)
      (should (= saved (point)))
      (should (isled-expansion-test--visible-p (point))))))

(ert-deftest isled-expansion-wraps-and-preserves-other-window ()
  (isled-expansion-test--with-row (make-string 210 ?x)
    (let* ((other (split-window-right))
           (other-point (window-point other)) (other-start (window-start other))
           (point-before (point)))
      (isled--toggle-issue)
      (should (= point-before (point)))
      (should (isled-expansion-test--visible-p (1- (isled-row-end row)) window))
      (should (= other-point (window-point other)))
      (should (= other-start (window-start other))))))

(ert-deftest isled-expansion-delayed-body-fits-without-focus-theft ()
  (isled-expansion-test--with-row nil
    (let ((other (split-window-right)))
      (isled--toggle-issue)
      (should isled-expansion--pending)
      (let ((point-before (point)))
        (set-window-buffer other (get-buffer-create "*scratch*"))
        (select-window other)
        (with-current-buffer (window-buffer window)
          (isled-expansion-prune)
          (setf (isled-issue-content issue) "One\nTwo\nThree\nFour\nFive\n")
          (let ((inhibit-read-only t))
            (isled-sections-render snapshot 'all '("0001")))
          (isled-expansion-complete)
          ;; The fit is complete, but its restoration state remains until folding.
          (should isled-expansion--pending)
          (should (= point-before (window-point window)))
          (should (isled-expansion-test--visible-p
                   (1- (isled-row-end row)) window)))
        (should (eq other (selected-window)))))))

(ert-deftest isled-expansion-delayed-refits-retain-first-viewport ()
  (isled-expansion-test--with-row nil
    (let ((start-before (window-start)))
      (isled--toggle-issue)
      (should isled-expansion--pending)
      (setf (isled-issue-content issue) "One\nTwo\nThree\nFour\n")
      (let ((inhibit-read-only t))
        (isled-sections-render snapshot 'all '("0001")))
      (isled-expansion-complete)
      (let ((first-fit (window-start)))
        (should (> first-fit start-before))
        (setf (isled-issue-content issue) (make-string 100 ?\n))
        (let ((inhibit-read-only t))
          (isled-sections-render snapshot 'all '("0001")))
        (isled-expansion-complete)
        (should (>= (window-start) first-fit)))
      (isled--toggle-issue)
      (should (= (window-start) start-before))
      (should-not isled-expansion--pending))))

(ert-deftest isled-expansion-delayed-intent-cancels-after-movement ()
  (dolist (action '(point scroll collapse switch delete))
    (ert-info ((format "Action: %s" action))
    (isled-expansion-test--with-row nil
      (isled--toggle-issue)
      (let* ((origin (cdar isled-expansion--pending))
             (point-marker (isled-expansion--origin-point origin)))
        (pcase action
          ('point (forward-char 1))
          ('scroll (set-window-start window (1+ (window-start window)) t))
          ('collapse (isled-sections-hide row))
          ('switch (set-window-buffer window (get-buffer-create "*scratch*")))
          ('delete (split-window-right) (delete-window window)))
        (set-buffer buffer)
        (isled-expansion-prune)
        (should-not isled-expansion--pending)
        (should-not (marker-buffer point-marker)))))))

(ert-deftest isled-expansion-restoration-cancels-after-away-and-back ()
  (dolist (action '(point scroll))
    (ert-info ((format "Action: %s" action))
      (isled-expansion-test--with-row "First\nSecond\nThird\nFourth\n"
        (isled--toggle-issue)
        (let ((fitted-start (window-start))
              (fitted-point (window-point window)))
          (pcase action
            ('point (forward-char 1))
            ('scroll (set-window-start window (1- fitted-start) t)))
          (isled-expansion-prune)
          (pcase action
            ('point (goto-char fitted-point))
            ('scroll (set-window-start window fitted-start t)))
          (isled-expansion-prune)
          (should-not isled-expansion--pending)
          (isled--toggle-issue)
          (should-not isled-expansion--pending))))))

(ert-deftest isled-expansion-restoration-cancels-on-layout-or-view-change ()
  (dolist (action '(resize refresh filter))
    (ert-info ((format "Action: %s" action))
      (isled-expansion-test--with-row "First\nSecond\nThird\nFourth\n"
        (isled--toggle-issue)
        (should isled-expansion--pending)
        (pcase action
          ('resize
           (split-window-below)
           (isled-expansion-prune))
          ('refresh
           (let ((isled-process-function (lambda (&rest _))))
             (isled-loading-request 'refresh)))
          ('filter
           (let ((isled-process-function (lambda (&rest _))))
             (isled-loading-request 'view))))
        (should-not isled-expansion--pending)))))

(ert-deftest isled-expansion-restoration-is-window-local ()
  (isled-expansion-test--with-row "First\nSecond\nThird\nFourth\n"
    (let* ((other (split-window-right))
           (start-before (window-start window))
           (other-start (window-start other))
           (other-point (window-point other)))
      (isled--toggle-issue)
      (should (> (window-start window) start-before))
      (isled--toggle-issue)
      (should (= (window-start window) start-before))
      (should (= (window-start other) other-start))
      (should (= (window-point other) other-point)))))

(ert-deftest isled-expansion-cleans-markers-on-view-death ()
  (let (marker original)
    (isled-expansion-test--with-row nil
      (isled--toggle-issue)
      (let ((origin (cdar isled-expansion--pending)))
        (setq marker (isled-expansion--origin-start origin)
              original (isled-expansion--origin-original-start origin))))
    (should-not (marker-buffer marker))
    (should-not (marker-buffer original))))

(ert-deftest isled-expansion-real-delivery-respects-scroll-guard ()
  (dolist (move '(nil t))
    (isled-loading-test--with-displayed-buffer
      (isled-mode)
      (let* (calls fitted
             (fit (symbol-function 'isled-expansion--fit))
             (isled-process-function
              (lambda (_root request callback) (push (list request callback) calls))))
        (isled-loading-request 'refresh)
        (isled-loading-test--reply (pop calls) 'refresh)
        (isled-sections-goto-id "0001")
        (isled--toggle-issue)
        (should isled-expansion--pending)
        (isled-loading-test--idle (current-buffer))
        (when move (set-window-start (selected-window) (1+ (window-start)) t))
        (cl-letf (((symbol-function 'isled-expansion--fit)
                   (lambda (row window)
                     (setq fitted t)
                     (funcall fit row window))))
          (isled-loading-test--reply (pop calls) 'details '("0001")))
        (should-not isled--auto-revert-error)
        (should (isled-issue-content
                 (isled-row-issue (gethash "0001" isled-rows-index))))
        (should (eq fitted (not move)))
        (should-not isled-expansion--pending)))))

(ert-deftest isled-expansion-at-buffer-start-keeps-fitting-row ()
  (isled-expansion-test--with-row "Short body\n"
    (let ((inhibit-read-only t))
      (erase-buffer)
      (isled-sections-insert snapshot 'all nil))
    (goto-char (point-min))
    (set-window-start window (point-min) t)
    (isled--toggle-issue)
    (should (= (point-min) (point) (window-start window)))
    (should (isled-expansion-test--visible-p (1- (point-max)) window))))

(ert-deftest isled-expansion-navigation-observer-cancels-intent ()
  (isled-expansion-test--with-row nil
    (isled--toggle-issue)
    (isled-windows-track #'ignore)
    (set-window-buffer window (get-buffer-create "*scratch*"))
    (isled-windows--changed)
    (should-not isled-expansion--pending)))

(provide 'isled-expansion-test)
;;; isled-expansion-test.el ends here
