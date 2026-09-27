;;; isled-release.el --- Pinned release metadata -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Assisted-by: Codex:GPT-6
;; Keywords: tools

;;; Commentary:
;; Validate release identity and hashes before any executable can run.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)

(cl-defstruct (isled-release (:constructor isled-release--create))
  "Validated metadata for one pinned platform executable."
  version target archive archive-size archive-hash member size hash)

(defun isled-release-current-target ()
  "Return the supported native target, or explain the source-build alternative."
  (or (cond
       ((and (eq system-type 'gnu/linux) (string-prefix-p "x86_64-" system-configuration))
        "x86_64-unknown-linux-musl")
       ((and (eq system-type 'darwin)
             (string-match-p "\\`\\(?:aarch64\\|arm64\\)-" system-configuration))
        "aarch64-apple-darwin")
       ((and (eq system-type 'windows-nt)
             (string-prefix-p "x86_64-" system-configuration)
             (not (member (getenv "PROCESSOR_ARCHITEW6432") '("ARM64" "arm64")))
             (not (member (getenv "PROCESSOR_ARCHITECTURE") '("ARM64" "arm64"))))
        "x86_64-pc-windows-msvc"))
      (user-error "No Isled binary for %s; build from source: https://github.com/cark/isled#installation"
                  system-configuration)))

(defun isled-release-validate-version (version)
  "Return VERSION if it is an exact release identity, otherwise fail."
  (unless (and (stringp version)
               (string-match-p "\\`[0-9]+\\.[0-9]+\\.[0-9]+\\'" version))
    (error "Invalid Isled CLI pin: %S" version))
  version)

(defun isled-release-executable (target)
  "Return the executable basename for TARGET."
  (if (equal target "x86_64-pc-windows-msvc") "isled.exe" "isled"))

(defun isled-release-checksum (checksums name)
  "Read the unique SHA-256 for NAME from strict CHECKSUMS text."
  (let ((seen (make-hash-table :test #'equal)) (case-fold-search nil))
    (dolist (line (split-string checksums "\n" t))
      (setq line (string-remove-suffix "\r" line))
      (unless (string-match "\\`\\([0-9a-f]\\{64\\}\\)  \\([A-Za-z0-9][A-Za-z0-9._-]*\\)\\'" line)
        (error "Malformed Isled SHA-256 metadata"))
      (let ((file (match-string 2 line)) (hash (match-string 1 line)))
        (when (gethash file seen) (error "Duplicate Isled checksum: %s" file))
        (puthash file hash seen)))
    (or (gethash name seen) (error "Missing Isled checksum: %s" name))))

(defun isled-release-verify (bytes hash &optional size)
  "Verify BYTES against HASH and optional SIZE before further processing."
  (unless (and (stringp hash) (string-match-p "\\`[0-9a-f]\\{64\\}\\'" hash)
               (or (null size) (= (length bytes) size))
               (equal (secure-hash 'sha256 bytes) hash))
    (error "Isled checksum or size mismatch")))

(defun isled-release-read (manifest checksums version target)
  "Validate MANIFEST and CHECKSUMS for VERSION and TARGET, returning metadata."
  (isled-release-validate-version version)
  (isled-release-verify manifest
                        (isled-release-checksum checksums (format "isled-%s-manifest.json" version)))
  (let* ((wire (json-parse-string (decode-coding-string manifest 'utf-8-unix)
                                :object-type 'alist :array-type 'list))
         (binary (alist-get (intern target) (alist-get 'binaries wire)))
         (archive (alist-get 'archive binary))
         (executable (alist-get 'executable binary))
         (prefix (format "isled-%s-%s" version target))
         (name (concat prefix (if (equal target "x86_64-pc-windows-msvc") ".zip" ".tar.gz")))
         (member (concat prefix "/" (isled-release-executable target))))
    (unless (and (eql (alist-get 'schema_version wire) 1)
                 (equal (alist-get 'repository wire) "cark/isled")
                 (equal (alist-get 'version wire) version)
                 (equal (alist-get 'tag wire) (concat "v" version))
                 (equal (alist-get 'name archive) name)
                 (equal (alist-get 'member executable) member)
                 (equal (alist-get 'sha256 archive) (isled-release-checksum checksums name)))
      (error "Isled release metadata does not match %s for %s" version target))
    (dolist (item (list archive executable))
      (unless (and (integerp (alist-get 'size item)) (< 0 (alist-get 'size item) (* 128 1024 1024))
                   (stringp (alist-get 'sha256 item))
                   (string-match-p "\\`[0-9a-f]\\{64\\}\\'" (alist-get 'sha256 item)))
        (error "Invalid Isled release size or hash")))
    (isled-release--create :version version :target target :archive name
                          :archive-size (alist-get 'size archive) :archive-hash (alist-get 'sha256 archive)
                          :member member :size (alist-get 'size executable) :hash (alist-get 'sha256 executable))))

(provide 'isled-release)
;;; isled-release.el ends here
