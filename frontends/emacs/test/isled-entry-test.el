;;; isled-entry-test.el --- Location entry contracts -*- lexical-binding: t; -*-

;;; Commentary:
;; Exercise selection and context identity with disposable local directories.

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'isled-entry)
(require 'isled-browser)
(require 'isled-loading-fixture)

(defmacro isled-entry-test--fixtures (&rest body)
  "Run BODY with a private root, views, and typed asynchronous process seam."
  (declare (indent 0) (debug t))
  `(let* ((root (file-truename (make-temp-file "isled-entry-" t)))
          (child (expand-file-name "child" root))
          (other (expand-file-name "other" root))
          (isled-auto-revert nil)
          (isled-process-function #'isled-test-process)
          (isled-snapshot-runner-function
           (lambda (directory)
             (isled-command-result-create
              :status 0 :stderr ""
              :stdout (json-serialize
                       `((schema_version . 3)
                         (root . ((encoding . "utf-8") (value . ,directory)))
                         (issues . [])))))))
     (make-directory child)
     (make-directory other)
     (unwind-protect
         (save-window-excursion ,@body)
       (dolist (buffer (buffer-list))
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (when (and (derived-mode-p 'isled-mode)
                      (string-prefix-p root (or (isled-context-current) "")))
             (kill-buffer buffer)))))
       (delete-directory root t))))

(ert-deftest isled-entry-current-project-and-directory-dispatch ()
  (let ((default-directory "/tmp/") calls)
    (cl-letf (((symbol-function 'isled-entry-project-root) (lambda () "/project/"))
              ((symbol-function 'isled-entry-open)
               (lambda (directory fresh) (push (list directory fresh) calls))))
      (with-temp-buffer
        (isled)
        (isled "/explicit/" t)
        (cl-letf (((symbol-function 'isled-entry-project-root) #'ignore)) (isled))))
    (should (equal (nreverse calls) '(("/project/" nil) ("/explicit/" t) ("/tmp/" nil))))))

(ert-deftest isled-entry-choosers-default-to-selected-context ()
  (with-temp-buffer
    (isled-mode)
    (setq isled-context-location "/selected" isled--root "/parent")
    (let (calls)
      (cl-letf (((symbol-function 'project-known-project-roots) (lambda () '("/another/")))
                ((symbol-function 'completing-read)
                 (lambda (_prompt choices &rest args)
                   (should (member "/selected/" choices))
                   (should (equal (nth 4 args) "/selected/")) "/another/"))
                ((symbol-function 'read-directory-name)
                 (lambda (_prompt default &rest _) (should (equal default "/selected/")) "/dir/"))
                ((symbol-function 'isled-entry-open)
                 (lambda (directory fresh) (push (list directory fresh) calls)))
                ((symbol-function 'project-remember-project) (lambda (&rest _) (ert-fail "Registered project"))))
        (isled-open-project '(4))
        (isled-open-directory))
      (should (equal (nreverse calls) '(("/another/" (4)) ("/dir/" nil)))))))

(ert-deftest isled-entry-cancel-never-creates-or-opens ()
  (isled-entry-test--fixtures
    (let ((before (buffer-list)))
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "Cancel")))
        (should (condition-case nil (progn (isled-entry-open child nil) nil)
                  (quit t))))
      (should (equal before (buffer-list)))
      (should-not (file-exists-p (expand-file-name ".issues" child))))))

(ert-deftest isled-entry-parent-contexts-and-choice-lifetime ()
  (isled-entry-test--fixtures
    (make-directory (expand-file-name ".issues" root))
    (let ((prompts 0) first second duplicate)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt choices &rest args)
                   (cl-incf prompts)
                   (should (equal (car choices) (nth 4 args)))
                   (car choices))))
        (setq first (isled-entry-open child nil)
              second (isled-entry-open other nil))
        (should-not (eq first second))
        (should (eq (buffer-local-value 'isled-session first)
                    (buffer-local-value 'isled-session second)))
        (with-current-buffer first (isled-filter-closed))
        (should (eq (buffer-local-value 'isled--filter second) 'open))
        (should (eq first (isled-entry-open child nil)))
        (setq duplicate (isled-entry-open child t))
        (should-not (eq duplicate first))
        (should (eq (buffer-local-value 'isled--filter duplicate) 'closed))
        (kill-buffer first)
        (should (eq duplicate (isled-entry-open child nil)))
        (should (= prompts 2))
        (kill-buffer duplicate)
        (isled-entry-open child nil)
        (should (= prompts 3))))))

(ert-deftest isled-entry-new-local-ledger-prompts-without-switching-old-view ()
  (isled-entry-test--fixtures
    (make-directory (expand-file-name ".issues" root))
    (let (parent-view local-view)
      (cl-letf (((symbol-function 'completing-read) (lambda (_ choices &rest _) (car choices))))
        (setq parent-view (isled-entry-open child nil)))
      (make-directory (expand-file-name ".issues" child))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_ choices &rest _args) (cadr choices))))
        (setq local-view (isled-entry-open child nil)))
      (should-not (eq parent-view local-view))
      (should (equal (buffer-local-value 'isled--root parent-view) root))
      (should (equal (buffer-local-value 'isled--root local-view) child))
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) (ert-fail "Unneeded prompt"))))
        (should (eq local-view (isled-entry-open child nil)))))))

(ert-deftest isled-entry-project-and-directory-share-exact-location ()
  (isled-entry-test--fixtures
    (make-directory (expand-file-name ".issues" child))
    (let ((default-directory (file-name-as-directory other)) view)
      (cl-letf (((symbol-function 'isled-entry-project-root) (lambda () child)))
        (setq view (isled)))
      (cl-letf (((symbol-function 'read-directory-name) (lambda (&rest _) child)))
        (should (eq view (isled-open-directory))))
      (with-current-buffer view
        (should (eq view (isled)))
        (should-not (eq view (isled nil t)))))))

(ert-deftest isled-entry-path-validation-and-symlink-identity ()
  (isled-entry-test--fixtures
    (make-directory (expand-file-name ".issues" child))
    (let ((alias (expand-file-name "alias" root)))
      (make-symbolic-link child alias)
      (should (eq (isled-entry-open child nil) (isled-entry-open alias nil))))
    (make-symbolic-link (expand-file-name ".issues" child) (expand-file-name ".issues" other))
    (should-error (isled-entry-open other nil) :type 'user-error)
    (should-error (isled-entry-open (expand-file-name "absent" root) nil) :type 'user-error)
    (should-error (isled-context-canonical "/ssh:somewhere:/tmp") :type 'user-error)))

(ert-deftest isled-entry-creation-requires-explicit-choice ()
  (isled-entry-test--fixtures
    (let (initialized opened)
      (cl-letf (((symbol-function 'completing-read) (lambda (_ choices &rest _) (car choices)))
                ((symbol-function 'isled-initialize)
                 (lambda (location callback)
                   (setq initialized location)
                   (make-directory (expand-file-name ".issues" location))
                   (funcall callback)))
                ((symbol-function 'isled-buffers-open)
                 (lambda (&rest arguments) (setq opened arguments))))
        (isled-entry-open child t))
      (should (equal initialized child))
      (should (equal opened (list child child t child))))))

(ert-deftest isled-initialize-failure-and-late-success-do-not-open ()
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *init-origin*")) callback opened
          (isled-initialize--pending (make-hash-table :test #'equal)))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (cl-letf (((symbol-function 'isled-process-command)
                       (lambda (dir args input receive)
                         (should (equal dir "/tmp"))
                         (should (equal args '("--root" "/tmp" "init")))
                         (should-not input)
                         (setq callback receive))))
              (isled-initialize "/tmp" (lambda () (setq opened t)))
              (should-error (isled-initialize "/tmp" #'ignore) :type 'user-error)
              (funcall callback (isled-command-result-create :status 1 :stdout "" :stderr "Denied"))
              (should-not opened)
              (should (= 0 (hash-table-count isled-initialize--pending)))
              (isled-initialize "/tmp" (lambda () (setq opened t)))
              (switch-to-buffer (get-buffer-create "*scratch*"))
              (funcall callback (isled-command-result-create :status 0 :stdout "Done" :stderr ""))
              (should-not opened)
              (should (= 0 (hash-table-count isled-initialize--pending)))))
        (kill-buffer buffer)))))

(ert-deftest isled-entry-new-local-parent-choice-is-remembered ()
  (isled-entry-test--fixtures
    (make-directory (expand-file-name ".issues" root))
    (let ((prompts 0) view)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_ choices &rest _args) (cl-incf prompts) (car choices))))
        (setq view (isled-entry-open child nil))
        (make-directory (expand-file-name ".issues" child))
        (should (eq view (isled-entry-open child nil)))
        (should (eq view (isled-entry-open child nil)))
        (should (= prompts 2))))))

(ert-deftest isled-entry-reuses-loading-context-without-another-request ()
  (isled-entry-test--fixtures
    (make-directory (expand-file-name ".issues" child))
    (let ((calls 0)
          (isled-process-function nil) view)
      (setq isled-process-function (lambda (&rest _) (cl-incf calls)))
      (setq view (isled-entry-open child nil))
      (should (eq view (isled-entry-open child nil)))
      (should (= calls 1)))))

(ert-deftest isled-entry-frontend-pins-explicit-root ()
  (let (arguments)
    (cl-letf (((symbol-function 'isled-process-command)
               (lambda (_dir args _input _callback) (setq arguments args))))
      (isled-process-start "/chosen" "{}" #'ignore))
    (should (equal arguments '("--root" "/chosen" "frontend" "--stdin")))))

(defun isled-entry-test--wait (predicate)
  "Wait briefly for PREDICATE in the isolated integration process."
  (let ((deadline (+ (float-time) 5)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (should (funcall predicate))))

(ert-deftest isled-entry-real-create-load-and-failure ()
  (let* ((isled-program (or (getenv "ISLED_ENTRY_TEST_PROGRAM")
                           (bound-and-true-p isled-test-program)
                           (executable-find "isled")))
         (isled-auto-revert nil)
         (isled-process-function #'isled-process-start)
         (root (file-truename (make-temp-file "isled-entry-real-" t)))
         (location (expand-file-name "new directory" root))
         (bad (expand-file-name "invalid" root)))
    (skip-unless isled-program)
    (make-directory location)
    (make-directory bad)
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer (get-buffer-create "*scratch*"))
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (_ choices &rest _args) (car choices))))
            (isled-entry-open location nil))
          (isled-entry-test--wait
           (lambda ()
             (when-let ((view (isled-context-view location)))
               (buffer-local-value 'isled-data-view view))))
          (let ((view (isled-context-view location)))
            (should (equal location (buffer-local-value 'isled--root view)))
            (should-not (buffer-local-value 'isled--auto-revert-error view))
            (with-temp-buffer
              (insert-file-contents (expand-file-name ".gitignore" location))
              (should (string-match-p "\\.issues" (buffer-string))))
            (kill-buffer view))
          ;; The CLI rejects a malformed existing allocation counter.  An error
          ;; must not create a view or leave a retained initialization request.
          (make-directory (expand-file-name ".issues" bad))
          (with-temp-file (expand-file-name ".issues/.next-id" bad) (insert "invalid"))
          (let (opened)
            (isled-initialize bad (lambda () (setq opened t)))
            (isled-entry-test--wait (lambda () (not (gethash bad isled-initialize--pending))))
            (should-not opened)))
      (dolist (buffer (buffer-list))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (when (and (derived-mode-p 'isled-mode)
                       (string-prefix-p root (or (isled-context-current) "")))
              (kill-buffer buffer)))))
      (delete-directory root t))))

(provide 'isled-entry-test)
;;; isled-entry-test.el ends here
