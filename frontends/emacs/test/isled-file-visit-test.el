;;; isled-file-visit-test.el --- Rust-backed file navigation -*- lexical-binding: t; -*-

;;; Commentary:
;; Exercise actual record validation, view reuse and history on disposable ledgers.

;;; Code:
(require 'ert)
(require 'isled-file-routing-test)
(defvar isled-test-program)

(defun isled-file-visit-test--await (predicate)
  "Wait up to five seconds for PREDICATE over the selected window."
  (let ((deadline (+ (float-time) 5)))
    (while (and (not (with-current-buffer (window-buffer) (funcall predicate)))
                (< (float-time) deadline))
      (accept-process-output nil 0.01))
    (set-buffer (window-buffer))
    (should (funcall predicate))))

(defun isled-file-visit-test--ready (id)
  "Return whether ID has been revealed in the selected view."
  (and (derived-mode-p 'isled-mode)
       (not isled-loading-running)
       (equal (isled-sections-id-at-point) id)
       (member id (isled-sections-expanded-ids))))

(defmacro isled-file-visit-test--with-ledger (&rest body)
  "Run BODY with a disposable real ledger and normal asynchronous transport."
  (declare (indent 0) (debug t))
  `(progn
     (skip-unless isled-test-program)
     (isled-file-routing-test--with-file
       (let ((isled-program isled-test-program)
             (isled-process-function #'isled-process-start)
             (default-directory (file-name-as-directory root)))
         (delete-file file)
         (delete-directory (expand-file-name ".issues" root))
         (dolist (arguments '(("init") ("add" "One" "--kind" "feature" "Body one.")
                              ("add" "Two" "--kind" "feature" "Body two.")
                              ("add" "Three" "--kind" "feature" "Body three.")
                              ("evidence" "add" "0003" "Disposable routing fixture.")
                              ("close" "0003" "--outcome" "Fixture complete.")))
           (should (zerop (apply #'call-process isled-program nil nil nil
                                 "--root" root arguments))))
         ,@body))))

(ert-deftest isled-file-visit-real-routing-history-and-reuse ()
  (isled-file-visit-test--with-ledger
    ;; Relative paths must be resolved before find-file changes default-directory.
    (find-file ".issues/0001-one.md")
    (isled-file-visit-test--await (lambda () (isled-file-visit-test--ready "0001")))
    (should-not (find-buffer-visiting (expand-file-name ".issues/0001-one.md" root)))
    (let ((view (current-buffer)) (origin-window (selected-window)))
      (isled-open-source)
      (should (equal buffer-file-name (expand-file-name ".issues/0001-one.md" root)))
      (should-not isled-file-visit--pending)
      (find-file (expand-file-name ".issues/0002-two.md" root))
      (isled-file-visit-test--await (lambda () (isled-file-visit-test--ready "0002")))
      (should (eq (current-buffer) view))
      (should-not (find-buffer-visiting (expand-file-name ".issues/0002-two.md" root)))
      (should (eq (selected-window) origin-window))
      (should (member "0001" (isled-sections-expanded-ids)))
      (isled-history-back)
      (should (equal (isled-sections-id-at-point) "0001"))
      (isled-navigation-with-window
        (isled--restore-view-state (isled--state-for-filter "s:open One")))
      (isled-file-visit-test--await
       (lambda () (and (not isled-loading-running) (equal isled--filter "s:open One"))))
      (find-file (expand-file-name ".issues/0003-three.md" root))
      (isled-file-visit-test--await (lambda () (isled-file-visit-test--ready "0003")))
      (should (eq (current-buffer) view))
      (should (eq isled--filter 'closed))
      (isled-history-back)
      (isled-file-visit-test--await
       (lambda () (and (not isled-loading-running) (equal isled--filter "s:open One"))))
      (should (equal (isled-sections-id-at-point) "0001"))
      (should (member "0001" (isled-sections-expanded-ids))))))

(ert-deftest isled-file-visit-real-malformed-fallback ()
  (isled-file-visit-test--with-ledger
    (let ((bad (expand-file-name ".issues/0004-bad.md" root)) notice)
      (with-temp-file bad (insert "Malformed Markdown\n"))
      (cl-letf (((symbol-function 'message)
                 (lambda (format &rest arguments) (setq notice (apply #'format format arguments)))))
        (find-file bad)
        (isled-file-visit-test--await (lambda () (not isled-file-visit--pending))))
      (should (equal buffer-file-name bad))
      (should (string-match-p "opening Markdown" notice))
      (should-not (isled--buffer-for-root root)))))

(ert-deftest isled-file-visit-real-independent-views ()
  (isled-file-visit-test--with-ledger
    (find-file (expand-file-name ".issues/0001-one.md" root))
    (isled-file-visit-test--await (lambda () (isled-file-visit-test--ready "0001")))
    (let* ((first (current-buffer))
           (first-folds (isled-sections-expanded-ids))
           (first-point (point))
           (second (isled-duplicate-view)))
      (find-file (expand-file-name ".issues/0003-three.md" root))
      (isled-file-visit-test--await (lambda () (isled-file-visit-test--ready "0003")))
      (should (eq (current-buffer) second))
      (with-current-buffer first
        (should (eq isled--filter 'open))
        (should (equal first-folds (isled-sections-expanded-ids)))
        (should (= first-point (point)))))))

(ert-deftest isled-file-visit-real-cross-ledger ()
  (isled-file-visit-test--with-ledger
    (find-file (expand-file-name ".issues/0001-one.md" root))
    (isled-file-visit-test--await (lambda () (isled-file-visit-test--ready "0001")))
    (let ((first (current-buffer)) (first-root root))
      (isled-file-visit-test--with-ledger
        (find-file (expand-file-name ".issues/0003-three.md" root))
        (isled-file-visit-test--await (lambda () (isled-file-visit-test--ready "0003")))
        (should (equal isled--root root))
        (should-not (eq (current-buffer) first))
        (with-current-buffer first
          (should (equal isled--root first-root))
          (should (eq isled--filter 'open)))))))

(provide 'isled-file-visit-test)
;;; isled-file-visit-test.el ends here
