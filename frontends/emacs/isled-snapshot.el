;;; isled-snapshot.el --- Snapshot boundary for isled  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT

;; Author: Sacha De Vos
;; Assisted-by: Codex:GPT-6
;; Keywords: tools

;;; Commentary:

;; Decode and validate the versioned JSON snapshot produced by the Rust
;; isled executable.  This library owns process execution and weak
;; wire data; it returns typed structures to the user interface.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)

(require 'isled-cli)

(define-error 'isled-snapshot-error
              "Invalid isled snapshot")

(cl-defstruct (isled-command-result
               (:constructor isled-command-result-create))
  "Result returned by a isled process invocation."
  status
  stdout
  stderr)

(cl-defstruct (isled-issue
               (:constructor isled-issue-create))
  "One validated issue in a isled snapshot."
  id
  status
  ready
  kind
  title
  path
  content
  references
  warnings)

(cl-defstruct (isled-warning
               (:constructor isled-warning-create))
  "One Rust-generated local relation diagnostic."
  code message related-ids source-id target-id needs-reason)

(cl-defstruct (isled-unavailable
               (:constructor isled-unavailable-create))
  "An identified file which could not be parsed as an issue."
  id path error)

(cl-defstruct (isled-inline-reference
               (:constructor isled-inline-reference-create))
  "One Rust-recognized issue target occurrence."
  field
  entry
  authored
  target-id
  resolution
  byte-start
  byte-length
  character-start
  character-length)

(cl-defstruct (isled-snapshot
               (:constructor isled-snapshot-create))
  "One validated isled application snapshot."
  root
  issues
  unavailable
  targets)

(defvar isled-snapshot-runner-function
  #'isled-snapshot--run-process
  "Function used to run isled for a snapshot.

The function receives a directory and returns a
`isled-command-result'.  Tests may bind this variable to a fake
runner.")

(defun isled-snapshot-load (directory)
  "Load and validate the issue snapshot discovered from DIRECTORY."
  (let* ((result (funcall isled-snapshot-runner-function directory))
         (status (isled-command-result-status result)))
    (unless (and (integerp status) (zerop status))
      (signal 'isled-snapshot-error
              (list (isled-snapshot--failure-message result))))
    (isled-snapshot-decode
     (isled-command-result-stdout result))))

(defun isled-snapshot-decode (json)
  "Decode and validate a version 3 snapshot from JSON."
  (condition-case error-data
      (let* ((wire (json-parse-string json
                                      :object-type 'alist
                                      :array-type 'list
                                      :null-object :json-null
                                      :false-object :json-false))
             (version (isled-snapshot--field wire 'schema_version))
             (root (isled-snapshot--file-name
                    (isled-snapshot--bytes
                     (isled-snapshot--field wire 'root) "root")))
             (wire-issues (isled-snapshot--field wire 'issues)))
        (unless (eql version 3)
          (isled-snapshot--invalid
           "unsupported schema version: %S" version))
        (unless (and (stringp root) (file-name-absolute-p root))
          (isled-snapshot--invalid
           "root is not an absolute path"))
        (unless (listp wire-issues)
          (isled-snapshot--invalid "issues is not an array"))
        (let ((issues (mapcar #'isled-snapshot--issue wire-issues))
              (unavailable (isled-snapshot--unavailable-files
                            (alist-get 'unavailable wire) root)))
          (isled-snapshot--validate-order issues)
          (isled-snapshot--validate-distinct-identities issues unavailable)
          (isled-snapshot-create
           :root root :issues issues :unavailable unavailable)))
    (isled-snapshot-error
     (signal (car error-data) (cdr error-data)))
    (error
     (signal 'isled-snapshot-error
             (list (format "cannot decode snapshot: %s"
                           (error-message-string error-data)))))))

(defun isled-snapshot--run-process (directory &optional arguments)
  "Run ARGUMENTS, defaulting to snapshot, from DIRECTORY and capture results."
  (let ((isled-program (isled-cli-resolve))
        (stdout-buffer (generate-new-buffer " *isled-stdout*"))
        (stderr-file (make-temp-file "isled-stderr-"))
        status stdout stderr)
    (unwind-protect
        (let ((default-directory
               (file-name-as-directory (expand-file-name directory))))
          (setq status
                (condition-case error-data
                    (apply #'process-file isled-program nil
                           (list stdout-buffer stderr-file) nil
                           (or arguments '("snapshot")))
                  (file-missing
                   (signal 'isled-snapshot-error
                           (list (format "cannot run %s: %s"
                                         isled-program
                                         (error-message-string error-data)))))))
          (setq stdout (with-current-buffer stdout-buffer (buffer-string))
                stderr (with-temp-buffer
                         (insert-file-contents stderr-file)
                         (buffer-string)))
          (isled-command-result-create
           :status status :stdout stdout :stderr stderr))
      (kill-buffer stdout-buffer)
      (delete-file stderr-file))))

(defun isled-snapshot--failure-message (result)
  "Describe the failed command RESULT for a user-facing error."
  (let ((stderr (string-trim
                 (or (isled-command-result-stderr result) ""))))
    (if (string-empty-p stderr)
        (format "isled snapshot exited with status %S"
                (isled-command-result-status result))
      stderr)))

(defun isled-snapshot--summary (wire)
  "Convert one WIRE summary into a validated issue without body data."
  (unless (listp wire)
    (isled-snapshot--invalid "issue is not an object"))
  (let* ((id (isled-snapshot--field wire 'id))
         (status (isled-snapshot--field wire 'status))
         (kind (isled-snapshot--field wire 'kind))
         (ready (isled-snapshot--boolean
                 (isled-snapshot--field wire 'ready)
                 (format "readiness for issue %s" id)))
         (path (isled-snapshot--file-name
                (isled-snapshot--bytes
                 (isled-snapshot--field wire 'path)
                 (format "path for issue %s" id))))
         (title (isled-snapshot--bytes
                 (isled-snapshot--field wire 'title)
                 (format "title for issue %s" id))))
    (unless (and (stringp id) (string-match-p "\\`[0-9]\\{4\\}\\'" id)
                 (not (string= id "0000")))
      (isled-snapshot--invalid "invalid issue ID: %S" id))
    (unless (member status '("open" "closed"))
      (isled-snapshot--invalid
       "invalid status for issue %s: %S" id status))
    (unless (and (stringp kind)
                 (let ((case-fold-search nil))
                   (string-match-p
                    "\\`[a-z0-9]\\(?:[a-z0-9-]*[a-z0-9]\\)?\\'" kind)))
      (isled-snapshot--invalid
       "invalid kind for issue %s: %S" id kind))
    (when (and ready (not (equal status "open")))
      (isled-snapshot--invalid
       "closed issue %s cannot be ready" id))
    (unless (file-name-absolute-p path)
      (isled-snapshot--invalid
       "path for issue %s is not absolute" id))
    (isled-issue-create
     :id id
     :status status
     :ready ready
     :kind kind
     :title title
     :path path)))

(defun isled-snapshot--issue (wire)
  "Convert one complete WIRE issue into a validated issue."
  (let* ((issue (isled-snapshot--summary wire))
         (id (isled-issue-id issue))
         (content (isled-snapshot--bytes
                   (isled-snapshot--field wire 'content)
                   (format "content for issue %s" id))))
    (setf (isled-issue-content issue) content
          (isled-issue-warnings issue) (isled-snapshot--warnings
                                                 (isled-snapshot--field wire 'warnings))
          (isled-issue-references issue)
          (isled-snapshot--references
           (isled-snapshot--field wire 'references) content id))
    issue))

(defun isled-snapshot--warnings (wire)
  "Decode the generated warning array WIRE."
  (unless (listp wire)
    (isled-snapshot--invalid "warnings is not an array"))
  (mapcar
   (lambda (item)
     (let ((code (isled-snapshot--field item 'code))
           (message (isled-snapshot--field item 'message))
           (ids (isled-snapshot--field item 'related_ids))
           (source (isled-snapshot--field item 'source_id))
           (target (isled-snapshot--field item 'target_id))
           (needs-reason (isled-snapshot--boolean
                          (isled-snapshot--field item 'needs_reason)
                          "warning needs_reason")))
       (unless (and (stringp code) (not (string-empty-p code))
                    (stringp message) (not (string-empty-p message))
                    (listp ids)
                    (cl-every (lambda (id)
                                (and (stringp id)
                                     (string-match-p "\\`[0-9]\\{4\\}\\'" id)
                                     (not (equal id "0000"))))
                              (append ids (list source target))))
         (isled-snapshot--invalid "invalid relation warning"))
       (isled-warning-create
        :code code :message message :related-ids ids
        :source-id source :target-id target :needs-reason needs-reason)))
   wire))

(defun isled-snapshot--unavailable-files (wire root)
  "Validate unavailable WIRE files belong directly to ROOT's ledger."
  (unless (listp wire)
    (isled-snapshot--invalid "unavailable is not an array"))
  (let ((files (mapcar #'isled-snapshot--unavailable wire))
        (directory (file-name-as-directory (expand-file-name ".issues" root)))
        previous)
    (dolist (file files)
      (let ((id (isled-unavailable-id file))
            (path (isled-unavailable-path file)))
        (unless (and (equal (file-name-directory path) directory)
                     (equal path (expand-file-name path))
                     (string-prefix-p (concat id "-") (file-name-nondirectory path))
                     (string-suffix-p ".md" path)
                     (or (null previous) (string< previous id)))
          (isled-snapshot--invalid "unsafe or unordered unavailable file"))
        (setq previous id)))
    files))

(defun isled-snapshot--unavailable (wire)
  "Decode an unavailable file from WIRE without inventing issue metadata."
  (let ((id (isled-snapshot--field wire 'id))
        (path (isled-snapshot--file-name
               (isled-snapshot--bytes
                (isled-snapshot--field wire 'path) "unavailable path")))
        (error (isled-snapshot--field wire 'error)))
    (unless (and (stringp id) (string-match-p "\\`[0-9]\\{4\\}\\'" id)
                 (not (equal id "0000")) (file-name-absolute-p path)
                 (stringp error))
      (isled-snapshot--invalid "invalid unavailable file"))
    (isled-unavailable-create :id id :path path :error error)))

(defun isled-snapshot--boolean (value context)
  "Decode JSON boolean VALUE described by CONTEXT."
  (cond
   ((eq value t) t)
   ((eq value :json-false) nil)
   (t (isled-snapshot--invalid "%s is not a boolean" context))))

(defun isled-snapshot--references (wire content issue-id)
  "Validate WIRE references against CONTENT for ISSUE-ID."
  (unless (listp wire)
    (isled-snapshot--invalid
     "references for issue %s is not an array" issue-id))
  (let ((previous-end 0)
        (content-bytes (and wire (encode-coding-string content 'utf-8 t))))
    (mapcar
     (lambda (item)
       (let ((reference
              (isled-snapshot--reference item content content-bytes issue-id)))
         (when (< (isled-inline-reference-byte-start reference)
                  previous-end)
           (isled-snapshot--invalid
            "references for issue %s are not ordered" issue-id))
         (setq previous-end
               (+ (isled-inline-reference-byte-start reference)
                  (isled-inline-reference-byte-length reference)))
         reference))
     wire)))

(defun isled-snapshot--reference (wire content content-bytes issue-id)
  "Validate WIRE against CONTENT and its UTF-8 CONTENT-BYTES for ISSUE-ID."
  (unless (listp wire)
    (isled-snapshot--invalid
     "reference for issue %s is not an object" issue-id))
  (let* ((field (isled-snapshot--field wire 'field))
         (entry (isled-snapshot--field wire 'entry))
         (authored (isled-snapshot--field wire 'authored))
         (target-id (isled-snapshot--field wire 'target_id))
         (resolution (isled-snapshot--field wire 'resolution))
         (byte-start (isled-snapshot--field wire 'byte_start))
         (byte-length (isled-snapshot--field wire 'byte_length))
         (character-start
          (isled-snapshot--field wire 'character_start))
         (character-length
          (isled-snapshot--field wire 'character_length)))
    (unless (member field
                    '("waiting_on" "blocking"
                      "statement" "evidence" "outcome"))
      (isled-snapshot--invalid
       "invalid reference field for issue %s: %S" issue-id field))
    (unless (and (natnump entry)
                 (stringp authored)
                 (string-match-p "\\`#[0-9]\\{1,4\\}\\'" authored)
                 (not (string-match-p "\\`#0+\\'" authored))
                 (stringp target-id)
                 (string-match-p "\\`[0-9]\\{4\\}\\'" target-id)
                 (not (string= target-id "0000"))
                 (equal target-id
                        (format "%04d" (string-to-number
                                        (substring authored 1))))
                 (member resolution '("resolved" "missing"))
                 (natnump byte-start)
                 (natnump byte-length)
                 (> byte-length 0)
                 (natnump character-start)
                 (natnump character-length)
                 (> character-length 0))
      (isled-snapshot--invalid
       "invalid reference metadata for issue %s" issue-id))
    (let ((authored-bytes (encode-coding-string authored 'utf-8 t)))
      (unless (and (= byte-length (length authored-bytes))
                   (<= (+ byte-start byte-length) (length content-bytes))
                   (equal authored-bytes
                          (substring content-bytes byte-start
                                     (+ byte-start byte-length)))
                   (= character-length (length authored))
                   (<= (+ character-start character-length) (length content))
                   (equal authored
                          (substring content character-start
                                     (+ character-start character-length))))
        (isled-snapshot--invalid
         "reference offsets do not match issue %s content" issue-id)))
    (isled-inline-reference-create
     :field (intern field)
     :entry entry
     :authored authored
     :target-id target-id
     :resolution (intern resolution)
     :byte-start byte-start
     :byte-length byte-length
     :character-start character-start
     :character-length character-length)))

(defun isled-snapshot--file-name (path)
  "Convert decoded native PATH to Emacs file-name spelling without I/O.
On Windows, Rust canonical paths use a verbatim prefix and backslashes;
Emacs uses forward slashes and lowercase drive letters.  Unix bytes remain
unchanged, including literal backslashes."
  (if (not (eq system-type 'windows-nt))
      path
    (let ((name (subst-char-in-string ?\\ ?/ path)))
      (cond
       ((string-prefix-p "//?/UNC/" name)
        (setq name (concat "//" (substring name 8))))
       ((and (string-prefix-p "//?/" name)
             (string-match-p "\\`[a-zA-Z]:/" (substring name 4)))
        (setq name (substring name 4))))
      (if (string-match-p "\\`[A-Z]:/" name)
          (concat (downcase (substring name 0 1)) (substring name 1))
        name))))

(defun isled-snapshot--bytes (wire context)
  "Decode a WIRE byte object described by CONTEXT."
  (unless (listp wire)
    (isled-snapshot--invalid "%s is not an encoded byte object" context))
  (let ((encoding (isled-snapshot--field wire 'encoding))
        (value (isled-snapshot--field wire 'value)))
    (unless (stringp value)
      (isled-snapshot--invalid "%s value is not a string" context))
    (pcase encoding
      ("utf-8" value)
      ("base64"
       (condition-case nil
           (base64-decode-string value)
         (error
          (isled-snapshot--invalid "%s contains invalid base64" context))))
      (_ (isled-snapshot--invalid
          "%s has unsupported encoding: %S" context encoding)))))

(defun isled-snapshot--validate-order (issues)
  "Require ISSUES to have unique, ascending identifiers."
  (let (previous)
    (dolist (issue issues)
      (let ((id (isled-issue-id issue)))
        (when (and previous (not (string< previous id)))
          (isled-snapshot--invalid
           "issue IDs are not unique and ascending: %s then %s"
           previous id))
        (setq previous id)))))

(defun isled-snapshot--validate-distinct-identities (issues unavailable)
  "Require sorted ISSUES and UNAVAILABLE files to have disjoint identities."
  (while (and issues unavailable)
    (let ((issue-id (isled-issue-id (car issues)))
          (file-id (isled-unavailable-id (car unavailable))))
      (cond
       ((equal issue-id file-id)
        (isled-snapshot--invalid "unavailable identity is also an issue"))
       ((string< issue-id file-id) (setq issues (cdr issues)))
       (t (setq unavailable (cdr unavailable)))))))

(defun isled-snapshot--field (object field)
  "Return required FIELD from alist OBJECT."
  (let ((entry (assq field object)))
    (unless entry
      (isled-snapshot--invalid "missing field: %s" field))
    (cdr entry)))

(defun isled-snapshot--invalid (format-string &rest arguments)
  "Signal a snapshot error formatted with FORMAT-STRING and ARGUMENTS."
  (signal 'isled-snapshot-error
          (list (apply #'format format-string arguments))))

(provide 'isled-snapshot)
;;; isled-snapshot.el ends here
