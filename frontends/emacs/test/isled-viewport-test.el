;;; isled-viewport-test.el --- Bounded presentation checks -*- lexical-binding: t; -*-

;;; Commentary:

;; Physical screen ranges bound new formatting without evicting stable text.

;;; Code:

(require 'isled-windows-test)

(ert-deftest isled-viewport-formats-window-union-and-retains-properties ()
  (save-window-excursion
    (delete-other-windows)
    (isled-loading-test--with-displayed-buffer
     (isled-mode)
     (setq isled--snapshot
           (apply #'isled-view-test--open-snapshot
                  (mapcar (lambda (n) (format "%04d" n)) (number-sequence 1 100)))
           isled--expanded-ids
           (mapcar #'isled-issue-id
                   (isled-snapshot-issues isled--snapshot)))
     (dolist (issue (isled-snapshot-issues isled--snapshot))
       (setf (isled-issue-content issue)
             (concat "# Heading\n\n" (apply #'concat (make-list 30 "Some **bold** text.\n")))))
     (let ((isled-sections--defer-rich t)) (isled--render))
     (let* ((first (selected-window)) (other (split-window-below))
            (row (aref isled-rows 0))
            (marker (copy-marker (+ 20 (isled-row-content row))))
            (tick (buffer-chars-modified-tick)))
       (unwind-protect
           (progn
             (isled-windows-test--point first "0001")
             (isled-windows-test--point other "0100")
             (isled-viewport-update)
             (should (isled-row-rich row))
             (should (isled-row-rich (aref isled-rows 99)))
             (should-not (isled-row-rich (aref isled-rows 49)))
             (should (< (cl-count-if #'isled-row-rich isled-rows) 10))
             (should (= marker (+ 20 (isled-row-content row))))
             (should (= tick (buffer-chars-modified-tick)))
             (should-not (buffer-modified-p))
             (let ((properties (text-properties-at marker)))
               (isled-windows-track #'isled-loading--display-changed)
               (isled-windows-test--point first "0050")
               ;; The normal observer presents cached text without waiting for
               ;; an idle timer or initiating a data request.
               (cl-letf (((symbol-function 'isled-loading-request)
                          (lambda (&rest _) (ert-fail "Redisplay requested data"))))
                 (funcall pre-redisplay-function t))
               (should (isled-row-rich (aref isled-rows 49)))
               (should (equal properties (text-properties-at marker)))
               (isled-windows-test--point first "0001")
               (cl-letf (((symbol-function 'isled-sections--present-issue)
                          (lambda (&rest _) (ert-fail "Reformatted retained body"))))
                 (isled-viewport-update))))
         (set-marker marker nil))))))

(ert-deftest isled-viewport-preview-formats-cached-text-without-loading ()
  (with-temp-buffer
    (isled-mode)
    (let ((inhibit-read-only t) (isled-sections--defer-rich t))
      (isled-sections-insert (isled-view-test--snapshot) 'all '("0001")))
    (let ((row (aref isled-rows 0)))
      (isled-sections-hide row)
      (should-not (isled-row-rich row))
      (cl-letf (((symbol-function 'isled-loading-schedule)
                 (lambda () (ert-fail "Preview scheduled loading"))))
        (isled-fold-preview (isled-row-fold row) nil)
        (should (isled-row-rich row))
        (should (isled-row-hidden row))
        (isled-fold-preview (isled-row-fold row) t)
        (should (invisible-p (1+ (isled-row-content row))))))))

(ert-deftest isled-viewport-prepares-point-outside-old-window-start ()
  (save-window-excursion
    (delete-other-windows)
    (isled-loading-test--with-displayed-buffer
     (isled-mode)
     (let ((inhibit-read-only t) (isled-sections--defer-rich t))
       (isled-sections-insert
        (apply #'isled-view-test--open-snapshot
               (mapcar (lambda (n) (format "%04d" n)) (number-sequence 1 100)))
        'all '("0098" "0099" "0100")))
     (set-window-start (selected-window) (point-min))
     (isled-sections-goto-id "0099")
     (isled-viewport-update)
     (should (isled-row-rich (gethash "0099" isled-rows-index)))
     (should (isled-row-rich (gethash "0100" isled-rows-index))))))

(ert-deftest isled-viewport-prefetch-formats-one-body-per-pass ()
  (isled-windows-test--with-view
   (let ((isled-sections--defer-rich t)) (isled--render))
   (isled-viewport-update)
   (let ((before (cl-count-if #'isled-row-rich isled-rows)))
     (isled-viewport-prefetch)
     (should (<= (- (cl-count-if #'isled-row-rich isled-rows) before) 1))
     (let ((rich (seq-filter #'isled-row-rich isled-rows)))
       (isled-windows-test--point (selected-window) "0200")
       (isled-viewport-update)
       (dolist (row rich) (should (isled-row-rich row)))))))

(ert-deftest isled-viewport-prefetch-prioritizes-direction ()
  (isled-windows-test--with-view
   (isled-windows-test--point (selected-window) "0050")
   (isled-viewport-update)
   (isled-windows-test--point (selected-window) "0060")
   (isled-viewport-update)
   (should (< (isled-viewport--priority (aref isled-rows 64))
              (isled-viewport--priority (aref isled-rows 54))))
   (isled-windows-test--point (selected-window) "0050")
   (isled-viewport-update)
   (should (< (isled-viewport--priority (aref isled-rows 44))
              (isled-viewport--priority (aref isled-rows 54))))))

(ert-deftest isled-viewport-collapsed-scrolling-does-no-layout-work ()
  (isled-windows-test--with-view
   (isled-collapse-all)
   (cl-letf (((symbol-function 'vertical-motion)
              (lambda (&rest _) (ert-fail "Collapsed scrolling traversed layout"))))
     (should-not (isled-windows-nearby))
     (isled-viewport-update)
     (should-not (isled-viewport-prefetch))
     (should-not (isled-viewport-work-p)))))

(ert-deftest isled-viewport-distant-expansions-do-no-layout-work ()
  (isled-windows-test--with-view
   (isled-collapse-all)
   (isled-sections-show (aref isled-rows 0))
   (isled-sections-show (aref isled-rows 249))
   (isled-windows-test--point (selected-window) "0125")
   (cl-letf (((symbol-function 'vertical-motion)
              (lambda (&rest _) (ert-fail "Distant bodies traversed layout"))))
     (should-not (isled-windows-nearby))
     (isled-viewport-update)
     (should-not (isled-viewport-prefetch)))))

(ert-deftest isled-viewport-rich-bodies-need-no-background-timer ()
  (isled-windows-test--with-view
   (setq isled-data-view isled--snapshot)
   (isled-session-attach)
   (cl-letf (((symbol-function 'isled-loading--request-needed) #'ignore))
     (isled-session-schedule isled-session)
     (should-not isled-loading-timer))
   (should (= (hash-table-count isled-rows-expanded) 8))
   (isled-collapse-all)
   (should (= (hash-table-count isled-rows-expanded) 0))))

(ert-deftest isled-viewport-expansion-is-indexed-before-dispatch ()
  (isled-windows-test--with-view
   (isled-collapse-all)
   (let ((row (aref isled-rows 10)) called)
     (cl-letf (((symbol-function 'isled-loading-schedule)
                (lambda ()
                  (setq called t)
                  (should (gethash row isled-rows-expanded)))))
       (isled-sections-show row))
     (should called))))

(provide 'isled-viewport-test)
;;; isled-viewport-test.el ends here
