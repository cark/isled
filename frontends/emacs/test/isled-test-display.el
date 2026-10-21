;;; isled-test-display.el --- Display fixture for batch tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Batch Emacs has windows but no redisplay.  Model uniform text lines only for
;; orchestration tests; graphical checks exercise the unmodified native APIs.

;;; Code:
(require 'cl-lib)

(defun isled-test-display--end (&optional window _update)
  "Return WINDOW's end in the batch fixture's uniform-line display."
  (let ((window (or window (selected-window))))
    (with-current-buffer (window-buffer window)
      (save-excursion
        (goto-char (window-start window))
        (vertical-motion (window-body-height window) window)
        (point)))))

(defun isled-test-display--visible (&optional position window partially)
  "Check POSITION in WINDOW's batch fixture, accepting PARTIALLY."
  (let* ((window (or window (selected-window)))
         (end (isled-test-display--end window))
         (position (if (eq position t) (max (window-start window) (1- end))
                     (or position (window-point window)))))
    (when (and (>= position (window-start window))
               (or (< position end)
                   (and (= position end)
                        (= end (with-current-buffer (window-buffer window) (point-max))))))
      (if partially '(0 0) t))))

(defun isled-test-display-call (function)
  "Call FUNCTION with a uniform display fixture in batch Emacs only."
  (if noninteractive
      (cl-letf (((symbol-function 'window-end) #'isled-test-display--end)
                ((symbol-function 'pos-visible-in-window-p) #'isled-test-display--visible))
        (funcall function))
    (funcall function)))

(provide 'isled-test-display)
;;; isled-test-display.el ends here
