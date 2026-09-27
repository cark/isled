;;; isled-installation.el --- Shared installer process and installation paths -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Assisted-by: Codex:GPT-6
;; Keywords: tools

;;; Commentary:
;; Rust owns directory selection and activation.  Remember its chosen default
;; root so later sessions can find their exact cached CLI without a download.

;;; Code:
(require 'isled-bundle)

(defun isled-installation--locator ()
  "Return the editor's local installation locator filename."
  (locate-user-emacs-file "isled/installation.json"))

(defun isled-installation-known-root (configured)
  "Return CONFIGURED storage, or the default previously resolved by the CLI."
  (if configured (expand-file-name configured)
    (let ((file (isled-installation--locator)))
      (when (file-exists-p file)
        (let* ((wire (json-parse-string
                      (decode-coding-string (isled-bundle-read-file file 65536) 'utf-8-unix)
                      :object-type 'alist))
               (root (alist-get 'root wire)))
          (unless (and (stringp root) (file-name-absolute-p root) (not (file-remote-p root)))
            (error "Invalid Isled installation locator: %s" file))
          root)))))

(defun isled-installation-remember (root)
  "Remember ROOT as the default selected by the verified CLI."
  (let* ((file (isled-installation--locator))
         (directory (file-name-directory file)) temporary)
    (make-directory directory t)
    (when (file-symlink-p file) (error "Unsafe Isled installation locator: %s" file))
    (unwind-protect
        (progn
          (setq temporary (make-temp-file (expand-file-name ".locator-" directory)))
          (let ((coding-system-for-write 'utf-8-unix))
            (with-temp-file temporary (insert (json-serialize `((root . ,root))) "\n")))
          (rename-file temporary file t)
          (setq temporary nil))
      (when temporary (delete-file temporary)))))

(defun isled-installation--decode (text version)
  "Read installation schema 1 TEXT, requiring VERSION when supplied."
  (let* ((wire (isled-installation--normalize-paths
                (json-parse-string text :object-type 'alist :null-object nil)))
         (root (alist-get 'root wire))
         (current (and (stringp root) (expand-file-name "current" root))))
    (unless (and (eql (alist-get 'schema_version wire) 1)
                 current (file-name-absolute-p root) (not (file-remote-p root))
                 (or (null version) (equal (alist-get 'version wire) version)))
      (error "Invalid Isled installation response"))
    (dolist (pair `((executable . ,(if (eq system-type 'windows-nt) "isled.exe" "isled"))
                    (skill . "skill") (skill_file . "skill/SKILL.md") (path_directory . "")))
      (unless (equal (directory-file-name (or (alist-get (car pair) wire) ""))
                     (directory-file-name (expand-file-name (cdr pair) current)))
        (error "Isled installer did not report stable current paths")))
    (when version
      (unless (equal (alist-get 'program wire)
                     (expand-file-name
                      (if (eq system-type 'windows-nt) "isled.exe" "isled")
                      (expand-file-name (concat "versions/" version) root)))
        (error "Isled installer did not report the exact pinned executable")))
    wire))

(defun isled-installation--normalize-paths (wire)
  "Normalize platform separators in WIRE paths without resolving current links."
  (dolist (key '(root program executable skill skill_file path_directory))
    (let ((value (alist-get key wire)))
      (unless (or (and (eq key 'program) (null value))
                  (and (stringp value) (file-name-absolute-p value) (not (file-remote-p value))))
        (error "Invalid Isled installation path: %s" key))
      (when value (setcdr (assq key wire) (directory-file-name (expand-file-name value))))))
  wire)

(defun isled-installation-run (program root command callback &optional version)
  "Run verified PROGRAM's COMMAND under ROOT and deliver its paths to CALLBACK.
ROOT may be nil for the platform default.  Require VERSION when supplied.
Return a cancellation function.  Use no shell or external installer tools."
  (let ((output (generate-new-buffer " *isled-installer*")) process timer finished)
    (cl-labels
        ((finish (result failure)
           (unless finished
             (setq finished t)
             (when timer (cancel-timer timer))
             (when process
               (set-process-sentinel process #'ignore)
               (when (process-live-p process) (delete-process process)))
             (kill-buffer output)
             (funcall callback result failure))))
      (condition-case failure
          (progn
            (setq process
                  (make-process
                   :name "isled-installer" :buffer output
                   :command (append (list program command "--json")
                                    (when root (list "--directory" root)))
                   :connection-type 'pipe :coding 'utf-8-unix :noquery t
                   :sentinel
                   (lambda (child _event)
                     (when (and (not finished) (memq (process-status child) '(exit signal)))
                       (condition-case problem
                           (let ((text (with-current-buffer output (string-trim (buffer-string)))))
                             (unless (zerop (process-exit-status child))
                               (error "Isled %s failed: %s" command text))
                             (finish (isled-installation--decode text version) nil))
                         (error (finish nil (error-message-string problem))))))))
            (setq timer (run-at-time 60 nil (lambda () (finish nil "Isled installation timed out; retry setup")))))
        ((error quit) (finish nil (error-message-string failure))))
      (lambda () (finish nil "Isled setup cancelled; retry setup to inspect and recover installation")))))

(defun isled-installation-display (paths &optional program)
  "Display copyable stable PATHS and optional exact Emacs PROGRAM."
  (let ((buffer (get-buffer-create "*Isled installation*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Isled %s\n\n" (or (alist-get 'version paths) "installation")))
        (dolist (entry '(("Executable" . executable) ("Skill directory" . skill)
                         ("Skill instructions" . skill_file) ("Add to PATH" . path_directory)))
          (insert (format "%s:\n%s\n\n" (car entry) (alist-get (cdr entry) paths))))
        (insert "Use these current paths in your shell and agent setup.\n"
                "They follow the selected release when you upgrade or roll back.\n"
                "An existing agent conversation may need to reload the skill.\n\n")
        (when program (insert (format "Emacs uses this compatible executable:\n%s\n\n" program)))
        (insert "Show this information again with M-x isled-show-installation.\n")
        (goto-char (point-min))
        (special-mode)))
    (display-buffer buffer)))

(provide 'isled-installation)
;;; isled-installation.el ends here
