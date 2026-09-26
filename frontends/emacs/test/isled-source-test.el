;;; isled-source-test.el --- Source file visits -*- lexical-binding: t; -*-

;;; Commentary:
;; Exercise real file buffers and window selection with disposable source files.

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'isled-browser)

(defmacro isled-source-test--with-file (&rest body)
  "Run BODY with a disposable source path and selected issue view."
  (declare (indent 0) (debug t))
  `(let* ((directory (make-temp-file "isled-source-" t))
          (path (expand-file-name "0042-example.md" directory))
          (source-buffer nil))
     (unwind-protect
         (save-window-excursion
           (with-temp-file path (insert "# Example\n\nSource text.\n"))
           (with-temp-buffer
             (isled-mode)
             (switch-to-buffer (current-buffer))
             (setq isled--snapshot
                   (isled-snapshot-create
                    :issues (list (isled-issue-create
                                   :id "0042" :path path :status "closed"))))
             (cl-letf (((symbol-function 'isled-sections-id-at-point)
                        (lambda () "0042")))
               ,@body)))
       (when (setq source-buffer (find-buffer-visiting path))
         (with-current-buffer source-buffer (set-buffer-modified-p nil))
         (kill-buffer source-buffer))
       (delete-directory directory t))))

(ert-deftest isled-source-uses-current-window ()
  (isled-source-test--with-file
    (let ((origin (selected-window))
          (find-file-hook
           (list (lambda ()
                   (should isled-inhibit-file-routing)))))
      ;; Source can become malformed after the view was loaded.
      (with-temp-file path (insert "Malformed but editable Markdown.\n"))
      (call-interactively #'isled-open-source)
      (should (eq origin (selected-window)))
      (should (equal buffer-file-name path))
      (should (= (point) (point-min)))
      (should (string-prefix-p "Malformed" (buffer-string)))
      (should-not isled-inhibit-file-routing))))

(ert-deftest isled-source-preserves-existing-draft-and-point ()
  (isled-source-test--with-file
    (let ((buffer (find-file-noselect path)))
      (with-current-buffer buffer
        (goto-char (point-max))
        (insert "Unsaved draft")
        (goto-char 5)
        (setq buffer-read-only t))
      (isled-open-source)
      (should (eq (current-buffer) buffer))
      (should (= (point) 5))
      (should (buffer-modified-p))
      (should buffer-read-only)
      (should (string-suffix-p "Unsaved draft" (buffer-string))))))

(ert-deftest isled-source-missing-file-does-not-create-buffer ()
  (isled-source-test--with-file
    (delete-file path)
    (let ((origin (selected-window)))
      (should-error (isled-open-source) :type 'user-error)
      (should (eq origin (selected-window)))
      (should-not (find-buffer-visiting path))
      (should-not (file-exists-p path)))))

(ert-deftest isled-source-needs-issue-at-point ()
  (with-temp-buffer
    (isled-mode)
    (should-error (isled-open-source) :type 'user-error)))

(ert-deftest isled-source-key-and-menu ()
  (should (eq (lookup-key isled-mode-map "s")
              #'isled-open-source))
  (save-window-excursion
    (with-temp-buffer
      (isled-mode)
      (switch-to-buffer (current-buffer))
      (unwind-protect
          (progn
            (transient-setup 'isled-help)
            (let* ((this-command 'isled-open-source)
                   (suffix (transient-suffix-object)))
              (should (eq (oref suffix command) 'isled-open-source))
              (should (equal (oref suffix key) "s"))
              (should-not (oref suffix transient))))
        (transient--emergency-exit)))))

(provide 'isled-source-test)
;;; isled-source-test.el ends here
