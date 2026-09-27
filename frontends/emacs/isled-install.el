;;; isled-install.el --- Stage and activate a CLI release -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Assisted-by: Codex:GPT-6
;; Keywords: tools

;;; Commentary:
;; Keep each verified executable in its own directory.  Failed or cancelled setup
;; removes only its private staging directory, never an earlier executable.

;;; Code:
(require 'isled-download)
(require 'isled-archive)
(require 'isled-executable)

(defun isled-install-directory (root version target)
  "Return the versioned directory under ROOT for VERSION and TARGET."
  (expand-file-name (format "%s-%s" version target) root))

(defun isled-install--read (file)
  "Read regular local FILE literally, rejecting symbolic links."
  (when (or (file-symlink-p file) (not (file-regular-p file)))
    (error "Missing or unsafe Isled cache file: %s" file))
  (with-temp-buffer (set-buffer-multibyte nil) (insert-file-contents-literally file) (buffer-string)))

(defun isled-install--write (file bytes)
  "Write BYTES into a new local FILE without visiting it."
  (let ((coding-system-for-write 'no-conversion))
    (write-region bytes nil file nil 'silent nil 'excl)))

(defun isled-install-cached (root version target)
  "Return the verified cached executable for ROOT, VERSION and TARGET, or nil."
  (let* ((directory (isled-install-directory root version target))
         (program (expand-file-name (isled-release-executable target) directory)))
    (when (or (file-exists-p directory) (file-symlink-p directory))
      (condition-case failure
          (progn
            (when (file-symlink-p directory) (error "Unsafe cache directory"))
            (unless (isled-executable-verified-p program version nil)
              (let ((release (isled-release-read
                              (isled-install--read (expand-file-name "manifest.json" directory))
                              (isled-install--read (expand-file-name "SHA256SUMS" directory)) version target)))
                (isled-release-verify (isled-install--read program)
                                      (isled-release-hash release) (isled-release-size release)))))
        (error (error "Invalid cached Isled (%s); remove only %s and retry"
                      (error-message-string failure) directory)))
      program)))

(defun isled-install (root version target callback)
  "Stage VERSION for TARGET under ROOT, then deliver its path to CALLBACK.
CALLBACK receives PROGRAM and nil, or nil and an error message.  Return a
cancellation function.  Existing version directories are never replaced."
  (let ((destination (isled-install-directory root version target))
        stage cancel finished checksums manifest release)
    (cl-labels
        ((finish (program failure)
           (unless finished
             (setq finished t)
             (when stage
               (condition-case problem (delete-directory stage t)
                 (error (setq failure
                              (format "%s; could not remove temporary directory %s: %s"
                                      (or failure "Isled setup cleanup failed") stage
                                      (error-message-string problem))))))
             (funcall callback program failure)))
         (guard (action)
           (unless finished
             (condition-case failure (funcall action)
               ((error quit) (finish nil (error-message-string failure))))))
         (fetch (name limit next)
           (setq cancel
                 (isled-download version name limit
                                 (lambda (bytes failure)
                                   (if failure (finish nil failure)
                                     (guard (lambda () (funcall next bytes))))))))
         (activate (program failure)
           (if failure (finish nil failure)
             (guard
              (lambda ()
                ;; A second Emacs may have completed the same release first.
                (if (file-exists-p destination)
                    (let ((existing (isled-install-cached root version target)))
                      (setq cancel (isled-executable-verify existing version nil #'finish)))
                  (rename-file stage destination nil)
                  (setq stage nil)
                  (finish (expand-file-name (file-name-nondirectory program) destination) nil))))))
         (unpack (bytes)
           (let* ((content (isled-archive-read bytes release))
                  (program (expand-file-name (isled-release-executable target) stage)))
             (isled-install--write program (isled-archive-executable content))
             (isled-install--write (expand-file-name "LICENSE" stage) (isled-archive-license content))
             (set-file-modes program #o700)
             (isled-install--write (expand-file-name "manifest.json" stage) manifest)
             (isled-install--write (expand-file-name "SHA256SUMS" stage) checksums)
             (message "Verifying Isled %s executable" version)
             (setq cancel (isled-executable-verify program version nil #'activate))))
         (metadata (bytes)
           (setq manifest bytes release (isled-release-read manifest checksums version target))
           (fetch (isled-release-archive release) (isled-release-archive-size release) #'unpack)))
      (guard
       (lambda ()
         (setq stage (make-temp-file (expand-file-name ".install-" root) t))
         (fetch (format "isled-%s-SHA256SUMS" version) (* 256 1024)
                (lambda (bytes)
                  (setq checksums bytes)
                  (fetch (format "isled-%s-manifest.json" version) (* 256 1024) #'metadata)))))
      (lambda ()
        (unless finished
          (when cancel (funcall cancel))
          (finish nil "Isled setup cancelled; invoke the command again to retry"))))))

(provide 'isled-install)
;;; isled-install.el ends here
