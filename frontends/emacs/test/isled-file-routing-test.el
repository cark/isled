;;; isled-file-routing-test.el --- File-open boundaries -*- lexical-binding: t; -*-

;;; Commentary:
;; Exercise displayed file buffers and delayed validation without a live ledger.

;;; Code:
(require 'ert)
(require 'org)
(require 'isled-file-visit)

(defmacro isled-file-routing-test--with-file (&rest body)
  "Run BODY with a disposable candidate FILE under ROOT."
  (declare (indent 0) (debug t))
  `(let* ((root (file-truename (make-temp-file "isled-route-" t)))
          (file (expand-file-name ".issues/0042-example.md" root))
          (isled-file-routing t)
          (isled-auto-revert nil)
          (isled-file-routing--serial 0)
          (isled-file-visit--pending nil)
          (org-link-frame-setup (quote ((file . find-file-other-window))))
          calls
          (isled-process-function
           (lambda (_directory _request callback) (push callback calls))))
     (unwind-protect
         (save-window-excursion
           (make-directory (file-name-directory file))
           (with-temp-file file (insert "# Example\n\nText\n"))
           (with-temp-buffer
             (insert "Origin buffer\n")
             (goto-char (point-min))
             (set-buffer-modified-p nil)
             (switch-to-buffer (current-buffer))
             ,@body))
       (remove-hook 'post-command-hook #'isled-file-visit--observe)
       (dolist (buffer (buffer-list))
         (when (and (buffer-live-p buffer) (with-current-buffer buffer
                 (or (and buffer-file-name (string-prefix-p root buffer-file-name))
                     (and (derived-mode-p 'isled-mode) (equal isled--root root)))))
           (with-current-buffer buffer (set-buffer-modified-p nil))
           (kill-buffer buffer)))
       (delete-directory root t))))

(ert-deftest isled-file-routing-candidates ()
  (isled-file-routing-test--with-file
    (should (equal (isled-file-routing--candidate file) (list root "0042" file)))
    (should-not (isled-file-routing--candidate (expand-file-name "0042-example.md" root)))
    (let ((link (expand-file-name ".issues/0043-link.md" root))
          (alias (concat root "-alias")))
      (unwind-protect
          (progn
            (make-symbolic-link file link)
            (make-symbolic-link root alias)
            (should-not (isled-file-routing--candidate link))
            (should-not (isled-file-routing--candidate
                         (expand-file-name ".issues/0042-example.md" alias))))
        (delete-file alias)))
    (cl-letf (((symbol-function 'file-regular-p) (lambda (_) (ert-fail "Remote I/O"))))
      (should-not (isled-file-routing--candidate "/ssh:host:/p/.issues/0042-example.md")))))

(ert-deftest isled-file-routing-background-and-bypass ()
  (isled-file-routing-test--with-file
    (let ((buffer (find-file-noselect file)))
      (should (buffer-live-p buffer))
      (should-not calls)
      (let ((isled-inhibit-file-routing t)) (find-file file))
      (should-not calls)
      (let ((isled-file-routing nil)) (find-file file))
      (should-not calls)
      (insert "draft")
      (find-file file)
      (should-not calls))))

(ert-deftest isled-file-routing-location-adapters ()
  (isled-file-routing-test--with-file
    (dolist (path (list (concat file "#statement") (concat file ":25")))
      (isled-file-routing--markdown (lambda (&rest _) (find-file file)) path)
      (should-not calls))
    (dolist (location '((25 nil) (nil "Statement")))
      (isled-file-routing--org
       (lambda (&rest _) (find-file file)) file t (car location) (cadr location))
      (should-not calls))
    (dolist (location '((:line-start 2) (:line-end 3) (:column 1)))
      (apply #'isled-file-routing--agent-shell
             (lambda (&rest _) (find-file file) (selected-window))
             :file file location)
      (should-not calls))
    (let (opened)
      (isled-file-routing--agent-shell
       (lambda (&rest _) (setq opened t)) :file file)
      (should-not opened)
      (should (= (length calls) 1)))))

(ert-deftest isled-file-routing-delayed-origin-fences ()
  (dolist (change '(point buffer edit disk newer disable))
    (isled-file-routing-test--with-file
      (find-file file)
      (should (= (length calls) 1))
      (let ((callback (car calls)) decoded)
        (pcase change
          ('point (forward-char))
          ('buffer (switch-to-buffer (get-buffer-create " *route-away*")))
          ('edit (insert "draft"))
          ('disk (with-temp-file file (insert "changed on disk")))
          ('newer (find-file file))
          ('disable (setq isled-file-routing nil)))
        (cl-letf (((symbol-function 'isled-file-visit--decode)
                   (lambda (&rest _) (setq decoded t))))
          (funcall callback nil))
        (should-not decoded)))))

(ert-deftest isled-file-routing-fallback-keeps-source ()
  (isled-file-routing-test--with-file
    (find-file file)
    (let (notice)
      (cl-letf (((symbol-function 'message) (lambda (format &rest args)
                                            (setq notice (apply #'format format args)))))
        (funcall (car calls) (isled-command-result-create :status 1 :stderr "validation failed")))
      ;; Async delivery restores its Lisp caller's buffer, not the displayed one.
      (set-buffer (window-buffer))
      (should (equal buffer-file-name file))
      (should (string-match-p "opening Markdown" notice)))
    (let ((isled-process-function (lambda (&rest _) (error "Executable unavailable"))))
      (find-file file)
      (should (equal buffer-file-name file)))))

(ert-deftest isled-file-routing-decoder-rejects-wrong-identity ()
  (isled-file-routing-test--with-file
    (let* ((request (isled-file-visit--request-create :root root :id "0042" :file file))
           (issue (isled-issue-create :id "0042" :path file))
           (response (isled-response-create
                      :root root :changes (list (isled-detail-create :issue issue))))
           (result (isled-command-result-create :status 0 :stdout "")))
      (cl-letf (((symbol-function 'isled-frontend-decode) (lambda (_) response)))
        (should (eq (isled-file-visit--decode request result) issue))
        (setf (isled-issue-id issue) "0043")
        (should-error (isled-file-visit--decode request result))
        (setf (isled-issue-id issue) "0042" (isled-issue-path issue) "/other.md")
        (should-error (isled-file-visit--decode request result))
        (setf (isled-issue-path issue) file (isled-response-root response) "/other")
        (should-error (isled-file-visit--decode request result))))))

(ert-deftest isled-file-routing-moved-away-and-back ()
  (isled-file-routing-test--with-file
    (find-file file)
    (let ((callback (car calls)) decoded)
      (forward-char)
      (isled-file-visit--observe)
      (backward-char)
      (cl-letf (((symbol-function 'isled-file-visit--decode)
                 (lambda (&rest _) (setq decoded t))))
        (funcall callback nil))
      (should-not decoded))))

(ert-deftest isled-file-routing-changed-view ()
  (isled-file-routing-test--with-file
    (let ((view (generate-new-buffer " *routing-view*")))
      (unwind-protect
          (progn
            (with-current-buffer view
              (isled-mode)
              (setq isled--root root))
            (find-file file)
            (let ((callback (car calls)) decoded)
              (with-current-buffer view (setq isled-loading-generation (list t)))
              (cl-letf (((symbol-function 'isled-file-visit--decode)
                         (lambda (&rest _) (setq decoded t))))
                (funcall callback nil))
              (should-not decoded)))
        (when (buffer-live-p view) (kill-buffer view))))))

(ert-deftest isled-file-routing-waits-without-opening-source ()
  (isled-file-routing-test--with-file
    (let ((origin (current-buffer)) hook-called)
      (let ((find-file-hook (list (lambda () (setq hook-called t)))))
        (find-file file))
      (should (= (length calls) 1))
      (should (eq origin (current-buffer)))
      (should-not hook-called)
      (should-not (find-buffer-visiting file)))))

(ert-deftest isled-file-routing-background-read-during-validation ()
  (isled-file-routing-test--with-file
    (find-file file)
    (let ((source (find-file-noselect file)))
      (should (equal (buffer-local-value 'buffer-file-name source) file))
      (should (= (length calls) 1)))))

(ert-deftest isled-file-routing-org-keeps-external-handler ()
  (isled-file-routing-test--with-file
    (let* (handled
           (org-file-apps (list (cons "md" (lambda (&rest _) (setq handled t))))))
      (org-open-file file)
      (should handled)
      (should-not calls)
      (should-not (find-buffer-visiting file)))))

(ert-deftest isled-file-routing-no-display-keeps-origin ()
  (isled-file-routing-test--with-file
    (let ((origin (current-buffer)))
      (should-not (isled-buffers-display-root root (lambda (_) nil)))
      (should (eq origin (current-buffer)))
      (should-not (isled--buffer-for-root root))
      (should-not (find-buffer-visiting file))
      (should-not calls))))

(provide 'isled-file-routing-test)
;;; isled-file-routing-test.el ends here
