;;; isled-navigation-test.el --- Window navigation checks -*- lexical-binding: t; -*-

;;; Commentary:
;; Navigation belongs to the originating window even when replies arrive later.
;;; Code:
(require 'ert)
(require 'isled-browser)
(require 'isled-loading-test)

(ert-deftest isled-navigation-history-coalesces-locations-across-jump-callers ()
  (let* ((a (isled--view-state-create :filter 'open :point-state '("0001" . 4)))
         (b (isled--view-state-create :filter 'open :point-state '("0002" . 8)))
         (same-a (copy-isled--view-state a))
         (isled--back-history nil)
         (isled--forward-history (list b))
         (current a))
    (setf (isled--view-state-expanded-ids same-a) '("0001" "0003"))
    (cl-letf (((symbol-function 'isled--capture-view-state) (lambda () current)))
      (isled-navigation-record same-a)
      (should-not isled--back-history)
      (should (equal isled--forward-history (list b)))
      (setq current b)
      (isled-navigation-record a)
      (isled-navigation-record same-a)
      (should (equal isled--back-history (list a)))
      (should-not isled--forward-history)
      (setq current a)
      (isled-navigation-record b 'back)
      (isled-navigation-record b 'back)
      (should (equal isled--forward-history (list b)))
      (setq current b)
      (isled-navigation-record a 'forward)
      (should (equal isled--back-history (list a)))
      (isled-navigation-record nil)
      (should (equal isled--back-history (list a)))
      (should-not isled--forward-history))))

(ert-deftest isled-navigation-memories-survive-switches-independently ()
  (isled-loading-test--with-displayed-buffer
    (isled-mode)
    (let* ((buffer (current-buffer)) (first (selected-window))
           (second (split-window-right)))
      (set-window-buffer second buffer)
      (isled-navigation-with-window
        (setq isled--back-history '(first)))
      (with-selected-window second
        (isled-navigation-with-window
          (should-not isled--back-history)
          (setq isled--back-history '(second))))
      (set-window-buffer first (get-buffer-create "*scratch*"))
      (set-window-buffer first buffer)
      (isled-navigation-with-window
        (should (equal isled--back-history '(first))))
      (delete-window second)
      (isled-navigation-prune)
      (should (= (hash-table-count isled-navigation--states) 1)))))

(ert-deftest isled-navigation-late-filter-restores-origin-without-focus-theft ()
  (isled-loading-test--with-displayed-buffer
    (isled-mode)
    (let* (calls
          (origin (selected-window))
          (isled-process-function
           (lambda (_root request callback) (push (list request callback) calls))))
      (isled-loading-request 'refresh)
      (isled-loading-test--reply (pop calls) 'refresh)
      (isled-filter-closed)
      (let ((other (split-window-right)))
        (set-window-buffer other (get-buffer-create "*scratch*"))
        (select-window other)
        (isled-loading-test--reply (pop calls) 'view)
        (should (eq other (selected-window)))
        (with-current-buffer (window-buffer origin)
          (should (eq isled--filter 'closed))
          (should-not isled--auto-revert-error))))))

(ert-deftest isled-navigation-movement-cancels-late-destination ()
  (isled-loading-test--with-displayed-buffer
    (isled-mode)
    (let* (calls
          (isled-process-function
           (lambda (_root request callback) (push (list request callback) calls))))
      (isled-loading-request 'refresh)
      (isled-loading-test--reply (pop calls) 'refresh)
      (isled-sections-goto-id "0001")
      (isled-filter-closed)
      (forward-char 1)
      (isled-loading-test--reply (pop calls) 'view)
      (should (eq isled--filter 'open))
      (should (equal (isled-sections-point-state) '("0001" . 1)))
      (should-not isled-loading-running))))

(provide 'isled-navigation-test)
;;; isled-navigation-test.el ends here
