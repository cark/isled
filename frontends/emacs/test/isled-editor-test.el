;;; isled-editor-test.el --- Draft editing behavior -*- lexical-binding: t; -*-
(require 'ert)
(require 'isled-editor)
(defvar isled-test-program nil)

(defun isled-editor-test-reply (callback response)
  "Deliver fixture RESPONSE through the decoded CALLBACK boundary."
  (dolist (key '(record current))
    (when (alist-get key response)
      (setf (alist-get key response)
            (isled-editor-decode-record (alist-get key response)
                                        (and (eq key 'record) (alist-get 'path response))))))
  (funcall callback response))


(defmacro isled-editor-test-buffer (&rest body)
  "Run BODY in a disposable draft buffer."
  `(with-temp-buffer
     (isled-editor-mode)
     (setq isled-editor-root temporary-file-directory)
     (isled-editor-form-render (isled-editor-empty-draft))
     (set-buffer-modified-p nil)
     (unwind-protect (progn ,@body)
       (set-buffer-modified-p nil) (isled-editor-cleanup))))

(ert-deftest isled-editor-fields-keys-and-protected-labels ()
  (isled-editor-test-buffer
   (should (equal (alist-get 'kind (isled-editor-form-draft)) "task"))
   (should (equal (alist-get 'evidence (isled-editor-form-draft)) []))
   (should (eq (key-binding (kbd "C-x C-s")) #'isled-editor-save))
   (should (eq (key-binding (kbd "TAB")) #'isled-editor-complete))
   (should (eq (key-binding (kbd "C-<tab>")) #'isled-editor-next-field))
   (insert "Title")
   (should (equal (alist-get 'title (isled-editor-form-draft)) "Title"))
   (goto-char (point-min))
   (should-error (insert "Bad") :type 'text-read-only)))

(ert-deftest isled-editor-multiline-and-evidence-list ()
  (isled-editor-test-buffer
   (let ((draft (isled-editor-empty-draft)))
     (setf (alist-get 'statement draft) "Hello\n\nWorld")
     (setf (alist-get 'evidence draft) ["First" "Second"])
     (isled-editor-form-render draft)
     (should (equal (alist-get 'statement (isled-editor-form-draft)) "Hello\n\nWorld"))
     (isled-editor-form-change-list 'evidence 0)
     (should (equal (alist-get 'evidence (isled-editor-form-draft)) ["Second"])))))

(ert-deftest isled-editor-validation-discards-stale-errors ()
  (isled-editor-test-buffer
   (let (reply)
     (cl-letf (((symbol-function 'isled-editor-request)
                (lambda (_root _mode _record _draft callback &optional _close) (setq reply callback))))
       (isled-editor-validate-buffer (current-buffer))
       (cl-incf isled-editor-generation)
       (isled-editor-test-reply reply '((ok . :false) (errors . [((field . "title") (message . "Old error"))])))
       (should-not isled-editor-errors)))))

(ert-deftest isled-editor-errors-do-not-become-authored-text ()
  (isled-editor-test-buffer
   (let ((draft (isled-editor-form-draft)) (position (point)))
     (isled-editor-form-errors [((field . "title") (message . "Title required"))])
     (should (= position (point)))
     (should (equal draft (isled-editor-form-draft)))
     (should (= (length isled-editor-errors) 1)))))

(ert-deftest isled-editor-revert-new-draft ()
  (isled-editor-test-buffer
   (insert "Draft")
   (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
     (isled-editor-revert))
   (should (equal (alist-get 'title (isled-editor-form-draft)) ""))
   (should-not (buffer-modified-p))))

(ert-deftest isled-editor-save-preserves-newer-typing ()
  (isled-editor-test-buffer
   (let (reply)
     (cl-letf (((symbol-function 'isled-editor-request)
                (lambda (_root _mode _record _draft callback &optional _close) (setq reply callback))))
       (isled-editor-save)
       (insert "More typing")
       (isled-editor-test-reply reply `((ok . t) (path . "/tmp/record.md")
                       (record . ((id . "0001") (status . "open") (version . "v1")
                                  (source . "source")
                                  (work . ((state . "not-queued") (reason . :json-null) (question . :json-null)
                                           (since . :json-null) (recorded_seconds . 0) (running_since . :json-null) (spans . []))) (draft . ,(isled-editor-empty-draft))))))
       (should (equal (alist-get 'title (isled-editor-form-draft)) "More typing"))
       (should (buffer-modified-p))
       (should (equal (isled-editor-record-id isled-editor-record) "0001"))))))

(ert-deftest isled-editor-real-rust-create-validate-and-edit ()
  (let* ((directory (make-temp-file "isled-editor-test-" t))
         (isled-program (or isled-test-program (expand-file-name "target/debug/isled" default-directory))))
    (unwind-protect
        (progn
          (should (zerop (call-process isled-program nil nil nil "--root" directory "init")))
          (isled-editor-test-buffer
           (setq isled-editor-root directory)
           (let ((draft (isled-editor-empty-draft)))
             (setf (alist-get 'title draft) "An issue")
             (setf (alist-get 'statement draft) "Hello\n\nWorld\n"
                   (alist-get 'tags draft) ["hello" "hello"])
             (isled-editor-form-render draft))
           (isled-editor-save)
           (let ((deadline (+ (float-time) 5)))
             (while (and isled-editor-busy (< (float-time) deadline)) (accept-process-output nil 0.02)))
           (should-not isled-editor-busy)
           (should isled-editor-record)
           (should (equal (alist-get 'statement (isled-editor-record-draft isled-editor-record)) "Hello\n\nWorld"))
           (should (equal (alist-get 'tags (isled-editor-record-draft isled-editor-record)) ["hello"]))
           (should (file-exists-p (isled-editor-record-path isled-editor-record)))
           (should-not (buffer-modified-p))
           (let ((widget (cdr (assoc "title" isled-editor-fields))))
             (goto-char (widget-field-start widget)) (insert "Updated "))
           (isled-editor-save)
           (let ((deadline (+ (float-time) 5)))
             (while (and isled-editor-busy (< (float-time) deadline)) (accept-process-output nil 0.02)))
           (should (equal (alist-get 'title (isled-editor-record-draft isled-editor-record)) "Updated An issue"))))
      (delete-directory directory t))))

(ert-deftest isled-editor-source-buffer-prevents-overwrite ()
  (isled-editor-test-buffer
   (let ((source (generate-new-buffer " *modified issue source*")))
     (unwind-protect
         (progn
           (with-current-buffer source (insert "Unsaved"))
           (cl-letf (((symbol-function 'isled-editor-source-conflict-p) (lambda () source)))
             (should-error (isled-editor-save) :type 'user-error))
           (should (buffer-modified-p source)))
       (with-current-buffer source (set-buffer-modified-p nil)) (kill-buffer source)))))

(ert-deftest isled-editor-window-return-does-not-delete-repurposed-window ()
  (save-window-excursion
    (isled-editor-test-buffer
     (let ((origin (generate-new-buffer " *ledger origin*"))
           (replacement (generate-new-buffer " *other work*")))
       (unwind-protect
           (let ((window (split-window)))
             (setq isled-editor-origin origin isled-editor-window window)
             (set-window-buffer window replacement)
             (isled-editor-return)
             (should (window-live-p window))
             (should (eq (window-buffer window) replacement)))
         (kill-buffer origin) (kill-buffer replacement))))))

(ert-deftest isled-editor-preview-settings-are-not-overridden ()
  (let ((corfu-popupinfo-mode nil) (company-show-quick-access nil))
    (isled-editor-test-buffer
     (should-not corfu-popupinfo-mode)
     (should-not company-show-quick-access))))

(ert-deftest isled-editor-issue-completion-matches-title-and-inserts-id ()
  (isled-editor-test-buffer
   (setq isled-editor-candidates
         (list (isled-issue-create :id "0002" :title "Widget validation" :status "open")))
   (let ((widget (cdr (assoc "statement" isled-editor-fields))))
     (goto-char (widget-field-start widget))
     (insert "#Widget")
     (let* ((capf (isled-editor-completion-at-point))
            (table (nth 2 capf))
            (metadata (completion-metadata "Widget" table nil)))
       (should (eq (completion-metadata-get metadata 'category) 'isled-issue))
       (delete-region (nth 0 capf) (nth 1 capf))
       (insert "0002 — Widget validation")
       (funcall (plist-get (nthcdr 3 capf) :exit-function) "0002 — Widget validation" 'finished)
       (should (equal (isled-editor-form-value "statement") "#0002"))))))

(ert-deftest isled-editor-preview-is-populated-when-framework-requests-it ()
  (isled-editor-test-buffer
   (let ((file (make-temp-file "isled-doc-test-")))
     (unwind-protect
         (progn
           (with-temp-file file (insert "Issue body preview"))
           (setq isled-editor-candidates (list (isled-issue-create :id "0002" :path file :title "Preview" :status "open")))
           (should-not isled-editor-documents)
           (let ((document (isled-editor-completion-document "#0002 — Preview")))
             (should (equal (with-current-buffer document (buffer-string)) "Issue body preview"))))
       (delete-file file)))))

(ert-deftest isled-editor-local-link-completion-wins-over-earlier-reference ()
  (isled-editor-test-buffer
   (goto-char (widget-field-start (cdr (assoc "statement" isled-editor-fields))))
   (insert "See #0002 and [guide](docs/re")
   (let ((capf (isled-editor-completion-at-point)))
     (should (equal (buffer-substring-no-properties (nth 0 capf) (nth 1 capf)) "re")))))

(ert-deftest isled-editor-title-tab-error-recovery-and-copy ()
  (isled-editor-test-buffer
   (let* ((widget (cdr (assoc "title" isled-editor-fields)))
          (start (widget-field-start widget)))
     (isled-editor-complete)
     (should (equal (isled-editor-form-value "title") ""))
     (insert "\t")
     (isled-editor-form-errors
      [((field . "title") (message . "title must be one non-empty title line"))])
     (goto-char (point-min))
     (search-forward "title must be")
     (let ((begin (- (point) (length "title must be"))))
       (end-of-line)
       (kill-ring-save begin (point))
       (should (equal (current-kill 0) "title must be one non-empty title line")))
     (goto-char (point-min))
     (search-forward "Title: ")
     (beginning-of-line)
     (should (= (current-column) 0))
     (forward-char 7)
     (should (= (point) start))
     (delete-char 1)
     (insert "Recovered title")
     (isled-editor-form-errors nil)
     (should (equal (isled-editor-form-value "title") "Recovered title"))
     (should-not (string-match-p "title must be" (buffer-string)))
     (should (equal (isled-editor-form-value "kind") "task")))))

(ert-deftest isled-editor-reverse-navigation-events-and-transient ()
  (isled-editor-test-buffer
   (dolist (key '("C-S-<tab>" "C-<backtab>" "C-S-<iso-lefttab>" "C-<iso-lefttab>"))
     (should (eq (key-binding (kbd key)) #'isled-editor-previous-field))))
  (should (get 'isled-editor-help 'transient--prefix)))


(ert-deftest isled-editor-empty-fields-navigation-and-completion ()
  (isled-editor-test-buffer
   (setq isled-editor-choices '("k:feature" "k:bug" "t:hello" "t:coucou"))
   (let ((draft (isled-editor-empty-draft)))
     (setf (alist-get 'kind draft) "")
     (isled-editor-form-render draft))
   (isled-editor-next-field)
   (should (= (point) (widget-field-start (cdr (assoc "kind" isled-editor-fields)))))
   (let ((capf (isled-editor-completion-at-point)))
     (should (member "feature" (all-completions "" (nth 2 capf)))))
   (isled-editor-next-field)
   (should (= (point) (widget-field-start (cdr (assoc "tags" isled-editor-fields)))))
   (let ((capf (isled-editor-completion-at-point)))
     (should (member "hello" (all-completions "" (nth 2 capf)))))
   (isled-editor-next-field)
   (should (= (point) (widget-field-start (cdr (assoc "statement" isled-editor-fields)))))
   (isled-editor-previous-field)
   (should (= (point) (widget-field-start (cdr (assoc "tags" isled-editor-fields)))))
   (insert "hello coucou, needs-review")
   (should (equal (alist-get 'tags (isled-editor-form-draft)) ["hello" "coucou" "needs-review"]))))

(ert-deftest isled-editor-kind-completion-covers-value-at-every-position ()
  (isled-editor-test-buffer
   (let* ((widget (cdr (assoc "kind" isled-editor-fields)))
          (start (widget-field-start widget)) (end (widget-field-end widget)))
     (dolist (position (list start (1+ start) end))
       (goto-char position)
       (let ((capf (isled-editor-completion-at-point)))
         (should (= (nth 0 capf) start))
         (should (= (nth 1 capf) end)))))))


(ert-deftest isled-editor-added-evidence-receives-point ()
  (isled-editor-test-buffer
   (isled-editor-form-change-list 'evidence nil)
   (should (= (point) (widget-field-start (cdr (assoc "evidence.0" isled-editor-fields)))))
   (insert "First")
   (isled-editor-form-change-list 'evidence nil)
   (should (= (point) (widget-field-start (cdr (assoc "evidence.1" isled-editor-fields)))))
   (insert "Second")
   (should (equal (alist-get 'evidence (isled-editor-form-draft)) ["First" "Second"]))))

(ert-deftest isled-editor-label-face-does-not-leak-into-typing ()
  (isled-editor-test-buffer
   (insert "New")
   (should-not (get-text-property (1- (point)) 'face))
   (goto-char (widget-field-start (cdr (assoc "title" isled-editor-fields))))
   (insert "Prefix ")
   (should-not (get-text-property (1- (point)) 'face))))

(ert-deftest isled-editor-title-reference-and-completed-prose-boundary ()
  (isled-editor-test-buffer
   (setq isled-editor-candidates (list (isled-issue-create :id "0002" :title "Widget" :status "open")))
   (insert "Fix #Widget")
   (let ((capf (isled-editor-completion-at-point)))
     (should capf)
     (delete-region (nth 0 capf) (nth 1 capf))
     (insert "0002 — Widget")
     (funcall (plist-get (nthcdr 3 capf) :exit-function) "0002 — Widget" 'finished))
   (should (equal (isled-editor-form-value "title") "Fix #0002"))
   (should-not (isled-editor-completion-at-point))
   (insert " some ordinary prose")
   (should-not (isled-editor-completion-at-point))
   (insert " #Wid")
   (should (isled-editor-completion-at-point))))


(ert-deftest isled-editor-removing-last-row-stays-in-its-section ()
  (isled-editor-test-buffer
   (dolist (field '(evidence waiting_on blocking))
     (isled-editor-form-change-list field nil)
     (isled-editor-form-change-list field 0)
     (should (= (point) (cdr (assq field isled-editor-add-buttons)))))))

(ert-deftest isled-editor-submission-normalizes-without-changing-draft ()
  (isled-editor-test-buffer
   (let ((draft (isled-editor-empty-draft)))
     (setf (alist-get 'statement draft) "\n Hello\n\nWorld. \n"
           (alist-get 'tags draft) ["hello" "hello" "coucou"])
     (isled-editor-form-render draft)
     (let ((submission (isled-editor-form-submission)))
       (should (equal (alist-get 'statement submission) "Hello\n\nWorld."))
       (should (equal (alist-get 'tags submission) ["hello" "coucou"])))
     (should (equal (isled-editor-form-draft) draft)))))

(ert-deftest isled-editor-render-retains-field-and-offset ()
  (isled-editor-test-buffer
   (let ((draft (isled-editor-empty-draft)))
     (setf (alist-get 'statement draft) "Some statement")
     (isled-editor-form-render draft)
     (goto-char (+ 4 (widget-field-start (cdr (assoc "statement" isled-editor-fields)))))
     (isled-editor-form-render draft)
     (should (= (point) (+ 4 (widget-field-start (cdr (assoc "statement" isled-editor-fields)))))))))

(ert-deftest isled-editor-relation-completion-with-hash-and-diagnostics ()
  (isled-editor-test-buffer
   (setq isled-editor-candidates (list (isled-issue-create :id "0002" :title "Widget" :status "open")))
   (dolist (field '(waiting_on blocking))
     (isled-editor-form-change-list field nil)
     (insert "#Wid")
     (let* ((capf (isled-editor-completion-at-point))
            (begin (copy-marker (nth 0 capf))) (end (copy-marker (nth 1 capf) t)))
       (should (member "0002 — Widget" (all-completions "" (nth 2 capf))))
       (isled-editor-form-errors [((field . "title") (message . "Title required"))])
       (delete-region begin end)
       (goto-char begin)
       (insert "0002 — Widget")
       (funcall (plist-get (nthcdr 3 capf) :exit-function) "0002 — Widget" 'finished)
       (should (equal (isled-editor-form-value (format "%s.0.id" field)) "#0002"))))))

(ert-deftest isled-editor-conflict-save-keeps-field-position ()
  (isled-editor-test-buffer
   (let ((draft (isled-editor-form-draft)) reply)
     (setf (alist-get 'statement draft) "Long enough statement")
     (isled-editor-form-render draft)
     (goto-char (+ 5 (widget-field-start (cdr (assoc "statement" isled-editor-fields)))))
     (cl-letf (((symbol-function 'isled-editor-request)
                (lambda (_root _mode _record _draft callback &optional _close) (setq reply callback))))
       (isled-editor-save)
       (isled-editor-test-reply reply `((ok . :false) (code . "conflict")
                       (current . ((id . "0001") (status . "open") (version . "new")
                                   (source . "source")
                                  (work . ((state . "not-queued") (reason . :json-null) (question . :json-null)
                                           (since . :json-null) (recorded_seconds . 0) (running_since . :json-null) (spans . []))) (draft . ,draft)))
                       (errors . [((field . "record") (message . "Changed on disk"))])))
       (should (= (point) (+ 5 (widget-field-start (cdr (assoc "statement" isled-editor-fields))))))
       (should isled-editor-save-failed)
       (should isled-editor-conflict)
       (should (equal (isled-editor-form-draft) draft))
       (should (string-match-p "Changed on disk" (format "%S" (isled-editor-header))))))))

(ert-deftest isled-editor-disk-check-keeps-draft-and-rejects-old-baseline ()
  (isled-editor-test-buffer
   (let* ((draft (isled-editor-form-draft))
          (baseline (isled-editor-record-create :id "0001" :version "old")) reply)
     (setq isled-editor-record baseline)
     (cl-letf (((symbol-function 'isled-editor-request)
                (lambda (_root _mode _record _draft callback &optional _close) (setq reply callback))))
       (isled-editor-disk-check)
       (isled-editor-test-reply reply `((ok . t) (record . ((id . "0001") (status . "open") (version . "new")
                                         (source . "source")
                                  (work . ((state . "not-queued") (reason . :json-null) (question . :json-null)
                                           (since . :json-null) (recorded_seconds . 0) (running_since . :json-null) (spans . []))) (draft . ,draft)))))
       (should isled-editor-conflict)
       (should (eq isled-editor-record baseline))
       (should (equal (isled-editor-form-draft) draft))
       (isled-editor-disk-check)
       (setq isled-editor-record (isled-editor-record-create :id "0001" :version "saved")
             isled-editor-conflict nil)
       (isled-editor-test-reply reply `((ok . t) (record . ((id . "0001") (status . "open") (version . "new")
                                         (source . "source")
                                  (work . ((state . "not-queued") (reason . :json-null) (question . :json-null)
                                           (since . :json-null) (recorded_seconds . 0) (running_since . :json-null) (spans . []))) (draft . ,draft)))))
       (should-not isled-editor-conflict)))))

(ert-deftest isled-editor-subscription-survives-last-view ()
  (let ((view (generate-new-buffer " *editor watch view*")) session called)
    (unwind-protect
        (isled-editor-test-buffer
         (with-current-buffer view
           (isled-mode)
           (setq isled--root "/tmp/isled-editor-listener")
           (isled-session-attach)
           (setq session isled-session))
         (setq isled-editor-session
               (isled-session-subscribe "/tmp/isled-editor-listener" (lambda () (setq called t))))
         (kill-buffer view)
         (should (eq session (gethash "/tmp/isled-editor-listener" isled-session--sessions)))
         (let ((isled-session session)) (isled-session-refresh))
         (should called)
         (isled-editor-cleanup)
         (setq isled-editor-session nil)
         (should-not (gethash "/tmp/isled-editor-listener" isled-session--sessions)))
      (when (buffer-live-p view) (kill-buffer view)))))

(ert-deftest isled-editor-unsaved-header-has-attention-face ()
  (isled-editor-test-buffer
   (cl-letf (((symbol-function 'isled-header-mode-line) #'identity))
     (dolist (saved '(nil t))
       (setq isled-editor-record (when saved (isled-editor-record-create :id "0001")))
       (set-buffer-modified-p saved)
       (let* ((header (isled-editor-header)) (start (string-match "Not saved" header)))
         (should start)
         (should (eq (get-text-property start 'face header) 'warning)))))))

(ert-deftest isled-editor-close-reuses-unsaved-fields-and-focuses-outcome ()
  (isled-editor-test-buffer
   (setq isled-editor-record (isled-editor-record-create :id "0001" :status "open" :version "old"))
   (insert "Unsaved title")
   (let ((before (isled-editor-form-draft)) (buffer (current-buffer)))
     (cl-letf (((symbol-function 'isled-sections-id-at-point) (lambda () "0001"))
               ((symbol-function 'isled-editor-open) (lambda (&rest _) buffer)))
       (isled-close-issue))
     (should isled-editor-closing)
     (should (buffer-modified-p))
     (should (equal before (isled-editor-form-draft)))
     (should (= (point) (widget-field-start (cdr (assoc "outcome" isled-editor-fields)))))
     (should (string-match-p "Closing issue" (format "%S" (isled-editor-header)))))))

(ert-deftest isled-editor-revert-retains-closing-intent ()
  (isled-editor-test-buffer
   (setq isled-editor-closing t
         isled-editor-record (isled-editor-record-create :id "0001" :status "open" :version "old"))
   (insert "Unsaved")
   (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
             ((symbol-function 'isled-editor-request)
              (lambda (_root mode _record _draft callback &optional close)
                (should (equal mode "load")) (should-not close)
                (funcall callback `((ok . t) (record . ,(isled-editor-record-create
                      :id "0001" :status "open" :version "new" :draft (isled-editor-empty-draft))))))))
     (isled-editor-revert))
   (should isled-editor-closing)
   (should-not (buffer-modified-p))
   (should (= (point) (widget-field-start (cdr (assoc "outcome" isled-editor-fields)))))))

(ert-deftest isled-editor-close-success-clears-intent-and-failure-keeps-it ()
  (dolist (success '(nil t))
    (isled-editor-test-buffer
     (setq isled-editor-closing t
           isled-editor-record (isled-editor-record-create :id "0001" :status "open" :version "old"))
     (goto-char (widget-field-start (cdr (assoc "outcome" isled-editor-fields))))
     (cl-letf (((symbol-function 'isled-editor-request)
                (lambda (_root mode _record _draft callback &optional close)
                  (should close) (should (equal mode "save"))
                  (funcall callback
                   (if success
                       `((ok . t) (record . ,(isled-editor-record-create :id "0001" :status "closed"
                             :version "new" :draft (isled-editor-empty-draft))))
                     '((ok . :false) (errors . [((field . "outcome") (message . "Outcome required"))])))))))
       (isled-editor-save))
     (should (eq isled-editor-closing (not success)))
     (should (= (point) (widget-field-start (cdr (assoc "outcome" isled-editor-fields))))))))

(ert-deftest isled-editor-close-retains-pending-initial-load ()
  (isled-editor-test-buffer
   (let ((buffer (current-buffer)) reply)
     (setq isled-editor-record (isled-editor-record-create :id "0001" :status "loading"))
     (cl-letf (((symbol-function 'isled-editor-request)
                (lambda (_root _mode _record _draft callback &optional _close)
                  (setq reply callback)))
               ((symbol-function 'isled-sections-id-at-point) (lambda () "0001"))
               ((symbol-function 'isled-editor-open)
                (lambda (&rest _) (isled-editor-load "0001") buffer)))
       (isled-close-issue))
     (let ((draft (isled-editor-empty-draft)))
       (setf (alist-get 'title draft) "Saved title")
       (funcall reply `((ok . t) (record . ,(isled-editor-record-create
                          :id "0001" :status "open" :version "loaded" :draft draft)))))
     (should (equal (alist-get 'title (isled-editor-form-draft)) "Saved title"))
     (should isled-editor-closing)
     (should-not isled-editor-busy)
     (should (= (point) (widget-field-start (cdr (assoc "outcome" isled-editor-fields))))))))
