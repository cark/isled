;;; isled-bookmark-test.el --- Persistent bookmark integration tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Use disposable real ledgers, including saved records read by a fresh Emacs.
;;; Code:
(require 'ert)
(require 'isled-browser)
(require 'isled-bookmark)
(require 'isled-auto-refresh-integration-test)

(defmacro isled-bookmark-test--with-ledger (&rest body)
  "Run BODY with a disposable ROOT, bookmark file and real CLI."
  (declare (indent 0) (debug t))
  `(let* ((root (file-truename (make-temp-file "isled-bookmark-" t)))
          (isled-program isled-test-program)
          (isled-use-development-cli t)
          (isled-process-function #'isled-process-start)
          (isled-auto-revert nil)
          (isled-graph-direction nil)
          (bookmark-default-file (expand-file-name "bookmarks" root))
          (bookmark-alist nil) (bookmark-alist-modification-count 0)
          (bookmark-save-flag nil))
     (unwind-protect
         (save-window-excursion
           (dolist (args '(("init") ("add" "First" "A first body." "--kind" "task")
                          ("add" "Second" "A second body." "--kind" "task")))
             (should (zerop (isled-command-result-status
                            (isled-snapshot--run-process root args)))))
           ,@body)
       (dolist (buffer (buffer-list))
         (when (equal root (buffer-local-value 'isled--root buffer))
           (kill-buffer buffer)))
       (delete-directory root t))))

(defun isled-bookmark-test--wait (buffer)
  "Wait for BUFFER to finish loading."
  (isled-native-refresh--wait
   "bookmark restoration" (lambda () (isled-native-refresh--settled-p buffer))))

(defun isled-bookmark-test--save (root name id)
  "Open ROOT and save NAME at expanded issue ID, returning the view."
  (let ((buffer (isled-buffers-open root root t root)))
    (set-buffer buffer)
    (isled-bookmark-test--wait buffer)
    (isled-collapse-all)
    (isled-sections-goto-id id)
    (isled--toggle-issue)
    (isled-bookmark-test--wait buffer)
    (isled-sections-goto-id id)
    (forward-char 2)
    (bookmark-set name)
    buffer))

(ert-deftest isled-bookmark-roundtrip-restores-independent-views ()
  (isled-bookmark-test--with-ledger
    (let* ((first (isled-bookmark-test--save root "First view" "0001"))
           (second (isled-bookmark-test--save root "Second view" "0002")))
      (bookmark-save)
      (kill-buffer first)
      (kill-buffer second)
      (setq bookmark-alist nil)
      (bookmark-load bookmark-default-file t t)
      (bookmark-jump "First view")
      (setq first (current-buffer))
      (isled-bookmark-test--wait first)
      (should (equal (isled-sections-point-state) '("0001" . 2)))
      (should (equal (isled-sections-expanded-ids) '("0001")))
      (bookmark-jump "Second view")
      (setq second (current-buffer))
      (isled-bookmark-test--wait second)
      (should-not (eq first second))
      (should (equal (isled-sections-point-state) '("0002" . 2)))
      (should (equal (isled-sections-expanded-ids) '("0002")))
      (bookmark-jump "First view")
      (should (eq (current-buffer) first))
      (isled-bookmark-test--wait first)
      (should (equal (isled-sections-point-state) '("0001" . 2))))))

(ert-deftest isled-bookmark-missing-issue-restores-silently ()
  (isled-bookmark-test--with-ledger
    (kill-buffer (isled-bookmark-test--save root "Removed" "0002"))
    (delete-file (expand-file-name ".issues/0002-second.md" root))
    (let ((debug-on-error t) messages
          (original-message (symbol-function 'message)))
      (cl-letf (((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (push (apply #'format-message format-string args) messages)
                   (apply original-message format-string args))))
        (bookmark-jump "Removed")
        (isled-bookmark-test--wait (current-buffer)))
      (should (equal (isled-sections-id-at-point) "0001"))
      (should-not (isled-sections-expanded-ids))
      (should-not (seq-some (lambda (text) (string-match-p "Isled bookmark:" text)) messages)))))

(ert-deftest isled-bookmark-invalid-or-unavailable-preserves-origin ()
  (isled-bookmark-test--with-ledger
    (kill-buffer (isled-bookmark-test--save root "Saved" "0001"))
    (let ((origin (current-buffer)) (window-buffer (window-buffer))
          (debug-on-error t))
      (bookmark-prop-set "Saved" 'isled-version 99)
      (bookmark-jump "Saved")
      (should (eq origin (current-buffer)))
      (should (eq window-buffer (window-buffer)))
      (bookmark-prop-set "Saved" 'isled-version 1)
      (rename-file (expand-file-name ".issues" root) (expand-file-name "hidden" root))
      (bookmark-jump "Saved")
      (should (eq origin (current-buffer)))
      (should (eq window-buffer (window-buffer))))))

(ert-deftest isled-bookmark-fresh-emacs-restores-saved-record ()
  (isled-bookmark-test--with-ledger
    (kill-buffer (isled-bookmark-test--save root "Restart" "0002"))
    (bookmark-save)
    (with-temp-buffer
      (let ((status
             (call-process
              (expand-file-name invocation-name invocation-directory) nil t nil
              "-Q" "--batch" "--eval"
              (prin1-to-string
               `(progn
                  (setq load-path ',load-path load-prefer-newer t
                        isled-test-program ,isled-program
                        isled-program ,isled-program isled-use-development-cli t
                        bookmark-default-file ,bookmark-default-file)
                  (require 'isled)
                  (require 'bookmark)
                  (progn
                    (setq isled-auto-revert nil)
                    (bookmark-load bookmark-default-file t t)
                    (bookmark-jump "Restart")
                    (require 'isled-bookmark-test)
                    (isled-bookmark-test--wait (current-buffer))
                    (cl-assert (equal (isled-sections-point-state) '("0002" . 2)))
                    (cl-assert (equal (isled-sections-expanded-ids) '("0002")))))))))
        (ert-info ((buffer-string)) (should (zerop status)))))))

(ert-deftest isled-bookmark-background-restoration-preserves-focus ()
  (isled-bookmark-test--with-ledger
    (kill-buffer (isled-bookmark-test--save root "Background" "0002"))
    (let (delivery view)
      (let ((isled-process-function
             (lambda (directory request callback)
               (isled-process-start directory request
                                    (lambda (result) (setq delivery (lambda () (funcall callback result))))))))
        (bookmark-jump "Background")
        (setq view (current-buffer))
        (isled-native-refresh--wait "held reply" (lambda () delivery)))
      (let ((other (split-window-right)))
        (select-window other)
        (switch-to-buffer (get-buffer-create " *bookmark-other*"))
        (unwind-protect
            (progn
              (funcall delivery)
              (isled-bookmark-test--wait view)
              (should (eq (selected-window) other))
              (should (equal (buffer-name) " *bookmark-other*"))
              (with-selected-window (get-buffer-window view)
                (should (equal (isled-sections-point-state) '("0002" . 2)))))
          (kill-buffer " *bookmark-other*"))))))

(ert-deftest isled-bookmark-restores-position-inside-an-expanded-body ()
  ;; Body demand follows actual redisplay geometry, absent in batch Emacs.
  (skip-unless (display-graphic-p))
  (isled-bookmark-test--with-ledger
    (let ((view (isled-bookmark-test--save root "Body" "0002")) expected)
      (isled-native-refresh--wait
       "body text" (lambda () (save-excursion (goto-char (point-min)) (search-forward "A second body." nil t))))
      (goto-char (point-min))
      (search-forward "A second body.")
      (setq expected (isled-sections-point-state))
      (bookmark-set "Body")
      (kill-buffer view)
      ;; Activities may assemble buffers before displaying their final layout.
      (isled-bookmark-jump (bookmark-get-bookmark "Body"))
      (isled-bookmark-test--wait (current-buffer))
      (should isled-loading-dirty)
      (switch-to-buffer (current-buffer))
      (isled-native-refresh--wait
       "saved body position" (lambda () (not isled-bookmark--pending-point)))
      (should (equal (isled-sections-point-state) expected)))))

(ert-deftest isled-bookmark-new-navigation-supersedes-pending-restore ()
  (isled-bookmark-test--with-ledger
    (kill-buffer (isled-bookmark-test--save root "Superseded" "0002"))
    (let (delivery view)
      (let ((isled-process-function
             (lambda (directory request callback)
               (isled-process-start directory request
                                    (lambda (result) (setq delivery (lambda () (funcall callback result))))))))
        (bookmark-jump "Superseded")
        (setq view (current-buffer))
        (isled-native-refresh--wait "held reply" (lambda () delivery))
        (isled-filter-closed))
      (funcall delivery)
      (isled-bookmark-test--wait view)
      (should (eq isled--filter 'closed))
      (should-not (isled-view-visible-issues isled--snapshot isled--filter)))))

(ert-deftest isled-bookmark-asynchronous-failure-keeps-view-usable ()
  (isled-bookmark-test--with-ledger
    (let ((view (isled-bookmark-test--save root "Failure" "0001"))
          (debug-on-error t) delivery)
      (let ((isled-process-function
             (lambda (_directory _request callback)
               (setq delivery (lambda ()
                                (funcall callback
                                         (isled-command-result-create
                                          :status 1 :stdout "" :stderr "Ledger unavailable")))))))
        (bookmark-jump "Failure"))
      (funcall delivery)
      (should (eq (current-buffer) view))
      (should (string-match-p "Ledger unavailable" isled--auto-revert-error))
      (should (isled-sections-goto-id "0001")))))

(provide 'isled-bookmark-test)
;;; isled-bookmark-test.el ends here
