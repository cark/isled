;;; isled-executable-test.el --- Real executable identity checks -*- lexical-binding: t; -*-

;;; Commentary:
;; Use the explicitly supplied native CLI; never inspect the installed user CLI.

;;; Code:
(require 'ert)
(require 'isled-executable)
(require 'isled-download-test)

(defvar isled-test-program)
(defvar isled-required-cli-version)

(ert-deftest isled-executable-checks-native-version-and-invalidates-evidence ()
  (skip-unless (and (boundp 'isled-test-program) (file-executable-p isled-test-program)))
  (let ((isled-executable--verified (make-hash-table :test #'equal)) result)
    (isled-executable-verify isled-test-program isled-required-cli-version t
                             (lambda (path error) (setq result (list path error))))
    (isled-download-test--wait (lambda () result))
    (should (car result)) (should-not (cadr result))
    (cl-letf (((symbol-function 'make-process) (lambda (&rest _) (error "Unchanged CLI ran again"))))
      (isled-executable-verify isled-test-program isled-required-cli-version t
                               (lambda (path error) (should path) (should-not error))))
    (setq result nil)
    (isled-executable-verify isled-test-program "999.0.0" nil
                             (lambda (path error) (setq result (list path error))))
    (isled-download-test--wait (lambda () result))
    (should-not (car result)) (should (string-match-p "Expected Isled" (cadr result)))))

(ert-deftest isled-executable-rejects-unreportable-programs ()
  (let ((file (make-temp-file "isled-not-executable-")))
    (unwind-protect
        (let (result)
          (set-file-modes file #o600)
          (condition-case failure
              (isled-executable-verify file "0.32.0" nil
                                       (lambda (path error) (setq result (list path error))))
            (error (setq result (list nil (error-message-string failure)))))
          (isled-download-test--wait (lambda () result))
          (should-not (car result)) (should (cadr result)))
      (delete-file file))))


(ert-deftest isled-executable-development-opt-in-is-narrow ()
  (let ((program (expand-file-name invocation-name invocation-directory))
        (launcher (symbol-function 'make-process)))
    (dolist (case '(("isled 0.32.0-dev" nil nil) ("isled 0.32.0-dev" t t)
                    ("isled 0.32.1-dev" t nil) ("not isled 0.32.0" nil nil)
                    ("isled 0.32.0" nil nil "unexpected stderr")
                    ("" nil t "isled 0.32.0")))
      (let ((isled-executable--verified (make-hash-table :test #'equal)) result)
        (cl-letf (((symbol-function 'make-process)
                   (lambda (&rest arguments)
                     (apply launcher
                            (plist-put arguments :command
                                       (list program "-Q" "--batch" "--eval"
                                             (prin1-to-string
                                              `(progn (princ ,(car case))
                                                      (princ ,(or (nth 3 case) "")
                                                             'external-debugging-output)))))))))
          (isled-executable-verify program "0.32.0" (nth 1 case)
                                   (lambda (path error) (setq result (list path error)))))
        (isled-download-test--wait (lambda () result))
        (if (nth 2 case) (should (car result))
          (should-not (car result)) (should (cadr result)))))))

(provide 'isled-executable-test)
;;; isled-executable-test.el ends here
