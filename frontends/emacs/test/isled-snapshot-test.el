;;; isled-snapshot-test.el --- Snapshot tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused ERT coverage for the process-independent snapshot boundary.

;;; Code:

(require 'ert)

(add-to-list 'load-path
             (file-name-directory
              (directory-file-name
               (file-name-directory (or load-file-name buffer-file-name)))))

(require 'isled-snapshot)

(defconst isled-test--directory
  (file-name-directory (or load-file-name buffer-file-name)))

(defvar isled-test-program nil
  "Rust executable used by opt-in integration tests.")

(defun isled-test--fixture (name)
  "Read fixture NAME as text."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name (concat "fixtures/" name)
                       isled-test--directory))
    (buffer-string)))

(ert-deftest isled-snapshot-validates-generated-warnings ()
  (let ((warning (car (isled-snapshot--warnings
                       '(((code . "RELATION_RECIPROCAL")
                          (message . "Missing reciprocal relation.")
                          (source_id . "0001") (target_id . "0002")
                          (needs_reason . :json-false)
                          (related_ids . ("0002"))))))))
    (should (equal (isled-warning-code warning) "RELATION_RECIPROCAL"))
    (should (equal (isled-warning-related-ids warning) '("0002"))))
  (should-error (isled-snapshot--warnings :json-null)
                :type 'isled-snapshot-error)
  (should-error (isled-snapshot--warnings
                 '(((code . "RELATION_TITLE") (message . "Wrong title")
                    (related_ids . ("0000")))) )
                :type 'isled-snapshot-error))

(ert-deftest isled-snapshot-decodes-current-version ()
  (let* ((snapshot
          (isled-snapshot-decode
           (isled-test--fixture "snapshot-v3.json")))
         (issues (isled-snapshot-issues snapshot)))
    (should (equal (isled-snapshot-root snapshot) "/tmp/example"))
    (should (equal (mapcar #'isled-issue-id issues)
                   '("0001" "0002")))
    (should (equal (isled-issue-title (car issues)) "First issue"))
    (should (equal (isled-issue-kind (car issues)) "feature"))
    (should (isled-issue-ready (car issues)))
    (should-not (isled-issue-ready (cadr issues)))
    (let* ((references (isled-issue-references (car issues)))
           (relation (car references))
           (reference (cadr references)))
      (should (eq (isled-inline-reference-field relation)
                  'waiting_on))
      (should (equal (isled-inline-reference-authored relation)
                     "#0002"))
      (should (equal (isled-inline-reference-target-id relation)
                     "0002"))
      (should (= (isled-inline-reference-byte-start relation) 124))
      (should (= (isled-inline-reference-character-start relation)
                 122))
      (should (eq (isled-inline-reference-field reference)
                  'statement))
      (should (= (isled-inline-reference-entry reference) 0))
      (should (equal (isled-inline-reference-authored reference)
                     "#2"))
      (should (equal (isled-inline-reference-target-id reference)
                     "0002"))
      (should (eq (isled-inline-reference-resolution reference)
                  'resolved))
      (should (= (isled-inline-reference-byte-start reference) 206))
      (should (= (isled-inline-reference-character-start reference)
                 202)))))

(ert-deftest isled-snapshot-validates-kind ()
  (let* ((json (isled-test--fixture "snapshot-v3.json"))
         (wire (json-parse-string json :object-type 'alist :array-type 'list
                                  :false-object :json-false))
         (issue (car (alist-get 'issues wire))))
    (dolist (kind '("bug" "custom-kind-2" "x" "a--b"))
      (setf (alist-get 'kind issue) kind)
      (should (equal (isled-issue-kind
                      (isled-snapshot--issue issue)) kind)))
    (dolist (kind '(nil :json-null 3 "" "Bug" "-bug" "bug-"
                       "bug_fix" "bug\nfix" "bug]"))
      (setf (alist-get 'kind issue) kind)
      (should-error (isled-snapshot--issue issue)
                    :type 'isled-snapshot-error))
    (should-error (isled-snapshot--issue (assq-delete-all 'kind issue))
                  :type 'isled-snapshot-error)))

(ert-deftest isled-snapshot-validates-unavailable-recovery-paths ()
  (let ((wire '(((id . "0001")
                 (path . ((encoding . "utf-8")
                          (value . "/tmp/example/.issues/0001-broken.md")))
                 (error . "Permission denied")))))
    (should (equal (isled-unavailable-error
                    (car (isled-snapshot--unavailable-files wire "/tmp/example")))
                   "Permission denied"))
    (should-error (isled-snapshot--unavailable-files wire "/tmp/other")
                  :type 'isled-snapshot-error)
    (should-error (isled-snapshot--unavailable-files (append wire wire) "/tmp/example")
                  :type 'isled-snapshot-error)))

(ert-deftest isled-snapshot-decodes-base64-bytes ()
  (let* ((json
          "{\"schema_version\":3,\"root\":{\"encoding\":\"base64\",\"value\":\"L3RtcC//\"},\"issues\":[]}")
         (snapshot (isled-snapshot-decode json)))
    (should (equal (string-to-list (isled-snapshot-root snapshot))
                   '(47 116 109 112 47 255)))))

(ert-deftest isled-snapshot-rejects-unsupported-version ()
  (should-error
   (isled-snapshot-decode
    "{\"schema_version\":1,\"root\":{\"encoding\":\"utf-8\",\"value\":\"/tmp\"},\"issues\":[]}")
   :type 'isled-snapshot-error))

(ert-deftest isled-snapshot-rejects-unsorted-identifiers ()
  (let ((json (isled-test--fixture "snapshot-v3.json")))
    (setq json (replace-regexp-in-string
                "\"0001\"" "\"0003\"" json t t))
    (should-error (isled-snapshot-decode json)
                  :type 'isled-snapshot-error)))

(ert-deftest isled-snapshot-rejects-null-issues ()
  (should-error
   (isled-snapshot-decode
    "{\"schema_version\":3,\"root\":{\"encoding\":\"utf-8\",\"value\":\"/tmp\"},\"issues\":null}")
   :type 'isled-snapshot-error))

(ert-deftest isled-snapshot-rejects-incoherent-reference-offsets ()
  (let ((json (isled-test--fixture "snapshot-v3.json")))
    (setq json (replace-regexp-in-string
                "\"byte_start\": 206" "\"byte_start\": 205" json t t))
    (should-error (isled-snapshot-decode json)
                  :type 'isled-snapshot-error)))

(ert-deftest isled-snapshot-rejects-invalid-readiness ()
  (let ((json (isled-test--fixture "snapshot-v3.json")))
    (setq json (replace-regexp-in-string
                "\"status\": \"closed\",\n      \"ready\": false"
                "\"status\": \"closed\",\n      \"ready\": true"
                json t t))
    (should-error (isled-snapshot-decode json)
                  :type 'isled-snapshot-error)))

(ert-deftest isled-snapshot-reports-command-stderr ()
  (let ((isled-snapshot-runner-function
         (lambda (_directory)
           (isled-command-result-create
            :status 1 :stdout "" :stderr "not initialized\n"))))
    (should-error (isled-snapshot-load "/tmp")
                  :type 'isled-snapshot-error)))

(ert-deftest isled-snapshot-runs-real-program ()
  (skip-unless isled-test-program)
  (let ((root (make-temp-file "isled-ledger-" t))
        (isled-program isled-test-program))
    (unwind-protect
        (progn
          (make-directory (expand-file-name ".issues" root))
          (with-temp-file (expand-file-name ".issues/.next-id" root)
            (insert "1\n"))
          (let ((snapshot (isled-snapshot-load root)))
            (should (equal (isled-snapshot-root snapshot)
                           (file-truename root)))
            (should-not (isled-snapshot-issues snapshot)))
          (should (zerop (process-file isled-program nil nil nil
                                       "--root" root "add" "Classified issue"
                                       "--kind" "maintenance" "Exercise kind display.")))
          (let ((issue (car (isled-snapshot-issues
                             (isled-snapshot-load root)))))
            (should (equal (isled-issue-kind issue) "maintenance"))))
      (delete-directory root t))))

(ert-deftest isled-snapshot-encodes-content-once-per-reference-batch ()
  (let* ((json (isled-test--fixture "snapshot-v3.json"))
         (wire (json-parse-string json :object-type 'alist :array-type 'list))
         (issue (car (alist-get 'issues wire)))
         (content (alist-get 'value (alist-get 'content issue)))
         (references (alist-get 'references issue))
         (encode (symbol-function 'encode-coding-string))
         (encodings 0))
    (should (> (length references) 1))
    (cl-letf (((symbol-function 'encode-coding-string)
               (lambda (string &rest arguments)
                 (when (eq string content) (cl-incf encodings))
                 (apply encode string arguments))))
      (should (= (length (isled-snapshot--references
                          references content "0001"))
                 (length references)))
      (should (= encodings 1))
      (should-not (isled-snapshot--references nil content "0001"))
      (should (= encodings 1)))))

(ert-deftest isled-snapshot-rejects-overlapping-recovery-identities ()
  (let ((issues (mapcar (lambda (id) (isled-issue-create :id id))
                        '("0001" "0004" "0008")))
        (files (mapcar (lambda (id) (isled-unavailable-create :id id))
                       '("0002" "0005" "0009"))))
    (isled-snapshot--validate-distinct-identities issues files)
    (setf (isled-unavailable-id (cadr files)) "0008")
    (should-error
     (isled-snapshot--validate-distinct-identities issues files)
     :type 'isled-snapshot-error)))

(provide 'isled-snapshot-test)
;;; isled-snapshot-test.el ends here
