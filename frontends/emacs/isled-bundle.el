;;; isled-bundle.el --- Verify complete local release bundles -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Assisted-by: Codex:GPT-6
;; Keywords: tools

;;; Commentary:
;; One manifest binds the executable, license and complete agent skill.

;;; Code:
(require 'isled-release)

(defconst isled-bundle-skill-files
  '("skill/SKILL.md" "skill/references/mutations.md" "skill/references/recovery.md")
  "The complete skill supplied with each release.")

(defvar isled-bundle--verified (make-hash-table :test #'equal)
  "Complete bundles verified against unchanged manifest and file attributes.")

(defun isled-bundle-read-file (file &optional maximum)
  "Read regular local FILE literally, rejecting links and bytes beyond MAXIMUM.
The default maximum is 128 MiB, the largest permitted release payload."
  (setq maximum (or maximum (* 128 1024 1024)))
  (when (or (file-symlink-p file) (not (file-regular-p file)))
    (error "Missing or unsafe Isled bundle file: %s" file))
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file nil 0 (1+ maximum))
    (when (> (buffer-size) maximum) (error "Oversized Isled bundle file: %s" file))
    (buffer-string)))

(defun isled-bundle-read (bytes version target)
  "Validate manifest BYTES for VERSION and TARGET; return its file descriptors."
  (when (> (length bytes) 65536) (error "Oversized Isled bundle manifest"))
  (let* ((wire (json-parse-string (decode-coding-string bytes 'utf-8-unix)
                                  :object-type 'alist :array-type 'list))
         (files (alist-get 'files wire))
         (expected (append (list (isled-release-executable target) "LICENSE")
                           isled-bundle-skill-files)))
    (unless (and (eql (alist-get 'schema_version wire) 1)
                 (equal (alist-get 'version wire) version)
                 (equal (alist-get 'target wire) target)
                 (equal (sort (mapcar (lambda (item) (alist-get 'name item)) files) #'string<)
                        (sort expected #'string<)))
      (error "Incomplete or mismatched Isled bundle"))
    (dolist (item files)
      (unless (and (integerp (alist-get 'size item))
                   (< 0 (alist-get 'size item)
                      (if (equal (alist-get 'name item) (isled-release-executable target))
                          (* 128 1024 1024) (* 1024 1024)))
                   (stringp (alist-get 'sha256 item))
                   (string-match-p "\\`[0-9a-f]\\{64\\}\\'" (alist-get 'sha256 item)))
        (error "Invalid Isled bundle file descriptor")))
    files))

(defun isled-bundle-verify-directory (directory version target)
  "Verify the complete bundle in DIRECTORY for VERSION and TARGET."
  (dolist (name '("" "skill" "skill/references"))
    (let ((path (expand-file-name name directory)))
      (unless (and (file-directory-p path) (not (file-symlink-p (directory-file-name path))))
        (error "Unsafe Isled bundle directory: %s" path))))
  (let* ((names (append (list (isled-release-executable target) "LICENSE" "bundle.json")
                        isled-bundle-skill-files))
         (signature
          (mapcar (lambda (name)
                    (let* ((path (expand-file-name name directory))
                           (attributes (file-attributes path 'integer)))
                      (unless (and attributes (null (file-attribute-type attributes)))
                        (error "Missing or unsafe Isled bundle file: %s" path))
                      (list (file-attribute-size attributes)
                            (file-attribute-modification-time attributes)
                            (file-attribute-status-change-time attributes)))) names))
         (key (list directory version target)))
    (unless (equal (gethash key isled-bundle--verified) signature)
      (dolist (item (isled-bundle-read
                     (isled-bundle-read-file (expand-file-name "bundle.json" directory) 65536) version target))
        (isled-release-verify
         (isled-bundle-read-file (expand-file-name (alist-get 'name item) directory) (alist-get 'size item))
         (alist-get 'sha256 item) (alist-get 'size item)))
      (puthash key signature isled-bundle--verified))))

(provide 'isled-bundle)
;;; isled-bundle.el ends here
