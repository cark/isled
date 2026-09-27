;;; isled-install-test.el --- Managed CLI lifecycle tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Exercise real archive construction and provisioning with disposable storage.
;; Replace only network delivery and execution of the synthetic fixture bytes.

;;; Code:
(require 'ert)
(require 'isled)
(require 'isled-cli)

(defconst isled-install-test--script
  (expand-file-name "cli-fixtures.py" (file-name-directory (or load-file-name buffer-file-name))))

(defmacro isled-install-test--with-fixture (&rest body)
  "Run BODY with isolated real release fixtures and controlled delivery."
  (declare (indent 0) (debug t))
  `(let* ((fixture (make-temp-file "isled-installer-test-" t))
          (assets (expand-file-name "assets" fixture))
          (isled-cli-directory (expand-file-name "cache" fixture))
          (isled-program nil) (isled-use-development-cli nil)
          (isled-required-cli-version "0.32.0") (isled-cli--pending nil)
          (isled-executable--verified (make-hash-table :test #'equal))
          (offers 0) (executions 0) requests (accept t) offline corrupt hold delivery)
     (unwind-protect
         (progn
           (should (zerop (call-process (or (executable-find "python3") (executable-find "python"))
                                       nil nil nil isled-install-test--script assets)))
           (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) (cl-incf offers) accept))
                     ((symbol-function 'isled-download)
                      (lambda (version asset _limit callback)
                        (push (list version asset) requests)
                        (let ((deliver (lambda ()
                                         (cond
                                          (offline (funcall callback nil "Offline; retry"))
                                          ((and corrupt (or (string-suffix-p ".tar.gz" asset) (string-suffix-p ".zip" asset)))
                                           (funcall callback "damaged archive" nil))
                                          (t (funcall callback (isled-install--read
                                                                (expand-file-name asset (expand-file-name version assets))) nil))))))
                          (if hold (setq delivery deliver) (funcall deliver))
                          (lambda () (funcall callback nil "Cancelled; retry")))))
                     ((symbol-function 'isled-executable-verify)
                      (lambda (program version _development callback)
                        (cl-incf executions)
                        (should (equal (isled-install--read program) (concat "isled " version "\n")))
                        (funcall callback program nil)
                        #'ignore)))
             (let ((noninteractive nil)) ,@body)))
       (isled-cancel-setup)
       (delete-directory fixture t))))

(defun isled-install-test--result ()
  "Resolve one fixture CLI, returning its path and error."
  (let (result)
    (isled-cli-ensure (lambda (program error) (setq result (list program error))))
    result))

(ert-deftest isled-install-first-use-cache-upgrade-and-rollback ()
  (isled-install-test--with-fixture
    (let* ((first (isled-install-test--result)) (old (car first)))
      (should old) (should-not (cadr first)) (should (= offers 1)) (should (= (length requests) 3))
      (should (file-in-directory-p old isled-cli-directory))
      (should (file-regular-p (expand-file-name "LICENSE" (file-name-directory old))))
      (should (equal first (isled-install-test--result)))
      (should (= (length requests) 3))
      (setq isled-required-cli-version "0.32.1")
      (let ((new (car (isled-install-test--result))))
        (should new) (should-not (equal old new)) (should (= offers 1))
        (should (= (length requests) 6)) (should (file-exists-p old))
        (setq isled-required-cli-version "0.32.0" offline t)
        (should (equal old (car (isled-install-test--result))))
        (should (= (length requests) 6))))))

(ert-deftest isled-install-decline-does-not-download-or-write ()
  (isled-install-test--with-fixture
    (setq accept nil)
    (should (string-match-p "declined" (cadr (isled-install-test--result))))
    (should-not requests) (should (= executions 0))
    (should-not (file-exists-p isled-cli-directory))))

(ert-deftest isled-install-cancel-cleans-stage-and-retries-with-consent ()
  (isled-install-test--with-fixture
    (setq hold t)
    (let (result second)
      (isled-cli-ensure (lambda (path error) (setq result (list path error))))
      (isled-cli-ensure (lambda (path error) (setq second (list path error))))
      (should (= (length requests) 1))
      (isled-cancel-setup)
      (should (equal result second)) (should-not (car result))
      (should (string-match-p "[Cc]ancel" (cadr result)))
      (should-not (directory-files isled-cli-directory nil "\\`\\.install-"))
      (funcall delivery) ; A late response cannot install or execute anything.
      (should (= executions 0))
      (setq hold nil)
      (should (car (isled-install-test--result)))
      (should (= offers 1)))))

(ert-deftest isled-install-checksum-failure-never-executes-and-preserves-old ()
  (isled-install-test--with-fixture
    (let ((old (car (isled-install-test--result))))
      (setq isled-required-cli-version "0.32.1" corrupt t executions 0)
      (should (string-match-p "mismatch" (cadr (isled-install-test--result))))
      (should (= executions 0)) (should (file-exists-p old))
      (should-not (directory-files isled-cli-directory nil "\\`\\.install-"))
      (setq corrupt nil)
      (should (car (isled-install-test--result)))
      (should (= offers 1)))))

(ert-deftest isled-install-offline-retry-preserves-consent ()
  (isled-install-test--with-fixture
    (setq offline t)
    (should (equal "Offline; retry" (cadr (isled-install-test--result))))
    (should (= executions 0)) (should-not isled-cli--pending)
    (setq offline nil)
    (should (car (isled-install-test--result))) (should (= offers 1))))

(ert-deftest isled-install-cleanup-failure-still-releases-waiting-commands ()
  (isled-install-test--with-fixture
    (setq hold t)
    (let (result)
      (isled-cli-ensure (lambda (path error) (setq result (list path error))))
      (cl-letf (((symbol-function 'delete-directory)
                 (lambda (&rest _) (error "File is temporarily busy"))))
        (isled-cancel-setup))
      (should-not isled-cli--pending)
      (should (string-match-p "temporary directory" (cadr result)))
      (should (= executions 0))
      (setq hold nil)
      (should (car (isled-install-test--result))))))

(ert-deftest isled-install-corrupted-cache-is-not-executed ()
  (isled-install-test--with-fixture
    (let ((program (car (isled-install-test--result))))
      (with-temp-file program (insert "broken"))
      (setq executions 0)
      (should (cadr (isled-install-test--result)))
      (should (= executions 0)) (should (= (length requests) 3)))))

(ert-deftest isled-install-explicit-override-never-downloads ()
  (isled-install-test--with-fixture
    (setq isled-program (expand-file-name "fixture-program" assets))
    (cl-letf (((symbol-function 'isled-executable-verify)
               (lambda (_program _version _development callback)
                 (funcall callback nil "Version mismatch") #'ignore)))
      (should (equal "Version mismatch" (cadr (isled-install-test--result))))
      (should-not requests) (should (= offers 0))
      (should-not (file-exists-p isled-cli-directory)))))

(ert-deftest isled-install-checksums-and-identity-are-strict ()
  (isled-install-test--with-fixture
    (let* ((directory (expand-file-name "0.32.0" assets))
           (checksums (isled-install--read (expand-file-name "isled-0.32.0-SHA256SUMS" directory)))
           (manifest (isled-install--read (expand-file-name "isled-0.32.0-manifest.json" directory))))
      (should (isled-release-p
               (isled-release-read manifest (replace-regexp-in-string "\n" "\r\n" checksums)
                                   "0.32.0" "x86_64-unknown-linux-musl")))
      (dolist (bad (list "" "nonsense\n" (concat checksums checksums)))
        (should-error (isled-release-read manifest bad "0.32.0" "x86_64-unknown-linux-musl")))
      (should-error (isled-release-read (concat manifest " ") checksums "0.32.0" "x86_64-unknown-linux-musl"))
      (should-error (isled-release-read manifest checksums "0.32.1" "x86_64-unknown-linux-musl"))
      (should-error (isled-release-read manifest checksums "0.32.0" "unsupported")))))

(ert-deftest isled-install-extracts-real-staging-formats-and-rejects-unsafe-members ()
  (isled-install-test--with-fixture
    (let* ((directory (expand-file-name "0.32.0" assets))
           (checksums (isled-install--read (expand-file-name "isled-0.32.0-SHA256SUMS" directory)))
           (manifest (isled-install--read (expand-file-name "isled-0.32.0-manifest.json" directory))))
      (dolist (target '("x86_64-unknown-linux-musl" "aarch64-apple-darwin" "x86_64-pc-windows-msvc"))
        (let* ((release (isled-release-read manifest checksums "0.32.0" target))
               (bytes (isled-install--read (expand-file-name (isled-release-archive release) directory))))
          (should (equal (isled-archive-executable (isled-archive-read bytes release)) "isled 0.32.0\n"))
          (dolist (name (if (equal target "x86_64-pc-windows-msvc") '("symlink.zip")
                         '("traversal.tar.gz" "symlink.tar.gz" "duplicate.tar.gz" "extra.tar.gz")))
            (let ((bad (isled-install--read (expand-file-name name assets))))
              (setf (isled-release-archive-hash release) (secure-hash 'sha256 bad)
                    (isled-release-archive-size release) (length bad))
              (should-error (isled-archive-read bad release)))))))))


(ert-deftest isled-install-platform-selection-is-explicit ()
  (dolist (case '((gnu/linux "x86_64-unknown-linux-gnu" "x86_64-unknown-linux-musl")
                  (darwin "aarch64-apple-darwin24" "aarch64-apple-darwin")
                  (windows-nt "x86_64-w64-mingw32" "x86_64-pc-windows-msvc")
                  (darwin "x86_64-apple-darwin24" nil)
                  (gnu/linux "aarch64-unknown-linux-gnu" nil)
                  (windows-nt "aarch64-w64-mingw32" nil)))
    (let ((system-type (nth 0 case)) (system-configuration (nth 1 case))
          (process-environment (copy-sequence process-environment)))
      (setenv "PROCESSOR_ARCHITEW6432" nil)
      (setenv "PROCESSOR_ARCHITECTURE" nil)
      (if (nth 2 case) (should (equal (isled-release-current-target) (nth 2 case)))
        (should-error (isled-release-current-target) :type 'user-error)))))

(provide 'isled-install-test)
;;; isled-install-test.el ends here
