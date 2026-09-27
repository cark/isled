;;; isled-install.el --- Download verified bundles for the shared installer -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Assisted-by: Codex:GPT-6
;; Keywords: tools

;;; Commentary:
;; Emacs owns private download staging.  The verified Rust executable owns
;; versioned storage, complete skill installation and the current directory link.

;;; Code:
(require 'isled-download)
(require 'isled-archive)
(require 'isled-executable)
(require 'isled-installation)

(defun isled-install-directory (root version)
  "Return the versioned directory under ROOT for VERSION."
  (expand-file-name (concat "versions/" version) root))

(defun isled-install--read (file)
  "Read regular local FILE literally, rejecting symbolic links."
  (isled-bundle-read-file file))

(defun isled-install--write (file bytes)
  "Write BYTES into a new local FILE without visiting it."
  (let ((coding-system-for-write 'no-conversion))
    (write-region bytes nil file nil 'silent nil 'excl)))

(defun isled-install-cached (root version target)
  "Return the verified cached executable for ROOT, VERSION and TARGET, or nil."
  (when root
    (let* ((directory (isled-install-directory root version))
           (program (expand-file-name (isled-release-executable target) directory)))
      (when (or (file-exists-p directory) (file-symlink-p directory))
        (condition-case failure
            (isled-bundle-verify-directory directory version target)
          (error (error "Invalid cached Isled (%s); inspect %s before retrying"
                        (error-message-string failure) directory)))
        program))))

(defun isled-install (root version target callback)
  "Download VERSION for TARGET and install its complete bundle under ROOT.
ROOT may be nil to let the CLI choose the platform default.  Deliver the exact
installed executable to CALLBACK.  Return a cancellation function."
  (let ((generation 0) stage cancel finished checksums release)
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
         (launch (operation)
           (let ((token (cl-incf generation)) (stop (funcall operation)))
             (when (= token generation) (setq cancel stop))))
         (fetch (name limit next)
           (launch (lambda ()
                     (isled-download version name limit
                                     (lambda (bytes failure)
                                       (if failure (finish nil failure)
                                         (guard (lambda () (funcall next bytes)))))))))
         (installed (paths failure)
           (if failure (finish nil failure)
             (guard
              (lambda ()
                (let ((directory (alist-get 'root paths)))
                  (unless root (isled-installation-remember directory))
                  (let ((program (isled-install-cached directory version target)))
                    (unless program (error "Shared installer did not install its bundle"))
                    (isled-installation-display paths program)
                    (finish program nil)))))))
         (activate (program failure)
           (if failure (finish nil failure)
             (guard (lambda ()
                      (launch (lambda () (isled-installation-run program root "install" #'installed version)))))))
         (unpack (bytes)
           (let* ((content (isled-archive-read bytes release))
                  (program (expand-file-name (isled-release-executable target) stage)))
             (dolist (entry (isled-archive-files content))
               (let ((file (expand-file-name (car entry) stage)))
                 (make-directory (file-name-directory file) t)
                 (isled-install--write file (cdr entry))))
             (set-file-modes program #o700)
             (message "Verifying Isled %s executable and skill" version)
             (launch (lambda () (isled-executable-verify program version nil #'activate)))))
         (metadata (bytes)
           (setq release (isled-release-read bytes checksums version target))
           (fetch (isled-release-archive release) (isled-release-archive-size release) #'unpack)))
      (guard
       (lambda ()
         (setq stage (make-temp-file "isled-download-" t))
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
