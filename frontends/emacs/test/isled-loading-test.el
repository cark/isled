;;; isled-loading-test.el --- Bounded loading tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Delayed transport checks plus a real Rust process exercise the production
;; wire decoder, sequencing, caching and stale-reply fence.

;;; Code:

(require 'isled-browser)
(require 'isled-snapshot-test)
(require 'isled-loading-fixture)

(defun isled-loading-test--wire (mode &optional details graph)
  "Return compact fixture wire for MODE, optional DETAILS and requested GRAPH."
  (let* ((full (json-parse-string (isled-test--fixture "snapshot-v4.json")
                                :object-type 'alist :array-type 'array
                                :null-object :json-null :false-object :json-false))
         (rows (alist-get 'issues full))
         (summary (mapcar (lambda (issue)
                           (seq-remove (lambda (field)
                                         (memq (car field) '(content references warnings)))
                                       issue)) rows)))
    (json-serialize
     `((schema_version . 4) (root . ,(alist-get 'root full))
       (view_hash . ,(if (memq mode '(details choices)) :json-null "0000000000000001"))
       (view . ,(if (memq mode '(details choices)) :json-null
                  `((issues . ,(vconcat summary)) (unavailable . []))))
       ,@(when graph
           `((graph . ((hash . "0000000000000001")
                       (direction . ,(alist-get 'direction graph))
                       (plan . ((lanes . 1)
                                (rows . ,(vconcat
                                          (mapcar (lambda (row)
                                                    `((id . ,(alist-get 'id row)) (lane . 0)
                                                      (start . :json-null) (targets . [])
                                                      (filtered_prerequisites . 0)
                                                      (filtered_dependents . 0))) summary)))
                                (drawing . ((lanes . 1)
                                            (steps . ,(vconcat
                                                       (cl-loop for index below (length summary)
                                                                collect `((row . ,index) (lane . 0)
                                                                          (start . :json-null)))))))))))))
       (choices . ["s:open" "s:closed" "t:rust" "k:bug"])
       (changes . ,(vconcat
                    (mapcar (lambda (id)
                              `((id . ,id) (hash . "0000000000000002") (type . "issue")
                                (detail . ((issue . ,(seq-find
                                                     (lambda (row) (equal (alist-get 'id row) id)) rows))
                                           (targets . ,(vconcat summary)) (unavailable . [])))))
                            details))))
     :null-object :json-null :false-object :json-false)))

(defun isled-loading-test--reply (call mode &optional details)
  "Complete queued CALL using MODE and optional changed DETAILS."
  (funcall (cadr call)
           (isled-command-result-create
            :status 0 :stderr "" :stdout (isled-loading-test--wire
                                         mode details
                                         (alist-get 'graph (json-parse-string
                                                            (car call) :object-type 'alist))))))

(defmacro isled-loading-test--with-buffer (&rest body)
  "Run BODY in an ordinary disposable buffer with lifecycle hooks enabled."
  (declare (indent 0) (debug t))
  `(let ((buffer (generate-new-buffer " *loading-test*")))
     (unwind-protect
         (with-current-buffer buffer ,@body)
       (when (buffer-live-p buffer) (kill-buffer buffer)))))

(defmacro isled-loading-test--with-displayed-buffer (&rest body)
  "Run BODY in a disposable buffer displayed in the selected window."
  (declare (indent 0) (debug t))
  `(save-window-excursion
     (isled-loading-test--with-buffer
       (set-window-buffer (selected-window) (current-buffer))
       ,@body)))

(defun isled-loading-test--idle (buffer)
  "Fire BUFFER's pending idle work without retaining its scheduled timer."
  (with-current-buffer buffer
    (when (timerp isled-loading-timer)
      (cancel-timer isled-loading-timer)))
  (isled-loading--request-needed buffer))

(ert-deftest isled-loading-repeated-views-do-not-retain-generated-undo ()
  ;; Space-prefixed test buffers start with undo disabled; real views do not.
  (isled-loading-test--with-displayed-buffer
    (buffer-enable-undo)
    (should-not (eq buffer-undo-list t))
    (isled-mode)
    (let* (call
           (isled-process-function
            (lambda (_directory request callback) (setq call (list request callback)))))
      (dolist (filter '(open closed open closed open))
        (isled-loading-request 'view (isled--initial-view-state filter))
        (isled-loading-test--reply call 'view)
        (should-not isled--auto-revert-error)
        (should (eq isled--filter filter))
        (should (> (length isled-rows) 0))
        (should (eq buffer-undo-list t))))))

(ert-deftest isled-loading-reply-restores-gc-policy-after-success-and-error ()
  (isled-loading-test--with-displayed-buffer
    (isled-mode)
    (dolist (threshold '(800000 33554432))
      (let* ((gc-cons-threshold threshold) call observed
             (decode (symbol-function 'isled-frontend-decode))
             (isled-process-function
              (lambda (_directory request callback) (setq call (list request callback)))))
        (cl-letf (((symbol-function 'isled-frontend-decode)
                   (lambda (text)
                     (setq observed gc-cons-threshold)
                     (funcall decode text))))
          (isled-loading-request 'refresh)
          (isled-loading-test--reply call 'refresh))
        (should-not isled--auto-revert-error)
        (should (>= observed threshold))
        (should (> observed 800000))
        (should (= gc-cons-threshold threshold))
        (cl-letf (((symbol-function 'isled-frontend-decode)
                   (lambda (_text) (error "Rejected test reply"))))
          (isled-loading-request 'refresh)
          (isled-loading-test--reply call 'refresh))
        (should (string-match-p "Rejected test reply" isled--auto-revert-error))
        (should (= gc-cons-threshold threshold))))))

(ert-deftest isled-loading-summaries-precede-range-and-detail-hashes ()
  (isled-loading-test--with-displayed-buffer
    (isled-mode)
    (let* (calls
           (isled-process-function
            (lambda (_directory request callback)
              (setq calls (append calls (list (list request callback)))))))
      (isled-loading-request 'refresh)
      (should (= (length calls) 1))
      (should-not isled--snapshot)
      (should (equal (alist-get 'details (json-parse-string (caar calls) :object-type 'alist)) []))
      (isled-loading-test--reply (pop calls) 'refresh)
      (should-not isled--auto-revert-error)
      (should-not (isled-issue-content (car (isled--visible-issues))))
      (isled-sections-goto-id "0001")
      (isled--toggle-issue)
      (should (string-match-p "Loading issue details" (buffer-string)))
      (isled-loading-test--idle (current-buffer))
      (should (= (length calls) 1))
      (isled-loading-test--reply (pop calls) 'details '("0001"))
      (should-not isled--auto-revert-error)
      (should (isled-issue-content (car (isled--visible-issues))))
      (should-not (string-match-p "Loading issue details" (buffer-string)))
      (isled-loading-test--idle (current-buffer))
      (should-not calls)
      ;; Collapse and re-enter requests the retained live hash.
      (isled-sections-goto-id "0001")
      (isled--toggle-issue)
      (isled-loading-test--idle (current-buffer))
      (isled--toggle-issue)
      (isled-loading-test--idle (current-buffer))
      (let ((entry (aref (alist-get 'details
                                    (json-parse-string (caar calls) :object-type 'alist)) 0)))
        (should (equal (alist-get 'hash entry) "0000000000000002"))))))

(ert-deftest isled-loading-fences-obsolete-replies-and-coalesces-work ()
  (isled-loading-test--with-buffer
    (isled-mode)
    (let* (calls
           (isled-process-function
            (lambda (_dir request callback)
              (setq calls (append calls (list (list request callback)))))))
      (isled-loading-request 'refresh)
      (isled-loading-request 'view (isled--initial-view-state 'closed))
      (isled-loading-request 'view (isled--initial-view-state 'all))
      (should (= (length calls) 1))
      (isled-loading-test--reply (pop calls) 'refresh)
      (should-not isled--snapshot)
      (should (= (length calls) 1))
      (isled-loading-test--reply (pop calls) 'view)
      (should (eq isled--filter 'all))
      (should-not isled-loading-running))))

(ert-deftest isled-loading-failure-and-invalid-response-keep-good-view ()
  (isled-loading-test--with-displayed-buffer
    (isled-mode)
    (let* (call
           (isled-process-function
            (lambda (_dir request callback) (setq call (list request callback)))))
      (isled-loading-request 'refresh)
      (isled-loading-test--reply call 'refresh)
      (let ((snapshot isled--snapshot) (contents (buffer-string)))
        (isled-loading-request 'refresh)
        (funcall (cadr call) (isled-command-result-create :status 1 :stderr "Locked"))
        (should (eq snapshot isled--snapshot))
        (should (equal contents (buffer-string)))
        (should (string-match-p "Locked" isled--auto-revert-error))
        (isled--toggle-issue)
        (isled-loading-request 'details)
        ;; Unrequested data must fail before mutating the detail cache.
        (isled-loading-test--reply call 'details '("0002"))
        (should (string-match-p "Unrequested" isled--auto-revert-error))
        (should (eq snapshot isled--snapshot))))))

(ert-deftest isled-loading-range-ignores-expanded-body-height ()
  (isled-loading-test--with-displayed-buffer
    (isled-mode)
    (setq isled--snapshot
          (apply #'isled-view-test--open-snapshot
                 (mapcar (lambda (n) (format "%04d" n)) (number-sequence 1 100)))
          isled--expanded-ids '("0001" "0049" "0050" "0051" "0100")
          isled--selected-id "0050")
    (setf (isled-issue-content (car (isled-snapshot-issues isled--snapshot)))
          (apply #'concat (make-list 1000 "Long body.\n")))
    (isled--render)
    (let ((isled-windows-chunk-size 8)
          (isled-windows-screen-margin 1))
     (cl-letf (((symbol-function 'window-body-height) (lambda (&rest _) 10)))
      (should (equal (isled-windows-nearby) '("0049" "0050" "0051")))))))

(ert-deftest isled-loading-real-process-preserves-lock-cleanup ()
  (skip-unless isled-test-program)
  (let ((root (make-temp-file "isled-bounded-" t))
        (isled-program isled-test-program)
        (isled-process-function #'isled-process-start)
        (isled-auto-revert nil))
    (unwind-protect
        (progn
          (should (zerop (call-process isled-program nil nil nil "--root" root "init")))
          (should (zerop (call-process isled-program nil nil nil "--root" root
                                      "add" "First" "--kind" "feature" "Body.")))
          (isled-loading-test--with-displayed-buffer
            (isled-mode)
            (setq default-directory (file-name-as-directory root))
            (isled-loading-request 'refresh)
            (isled-loading-test--await)
            (should-not isled--auto-revert-error)
            (should (= (length (isled--visible-issues)) 1))
            (isled--toggle-issue)
            (isled-loading-test--idle (current-buffer))
            (isled-loading-test--await)
            (should-not isled--auto-revert-error)
            (should (string-match-p "Body" (buffer-string)))
            (should-not (file-exists-p (expand-file-name ".issues/.cache/.isled-lock" root)))))
      (delete-directory root t))))

(defun isled-loading-test--await ()
  "Wait with a bounded deadline for the current test process."
  (let ((deadline (+ (float-time) 5)))
    (while (and isled-loading-running (< (float-time) deadline))
      (accept-process-output nil 0.01))
    (should-not isled-loading-running)))

(ert-deftest isled-loading-rapid-filter-return-rejects-the-intermediate-list ()
  (isled-loading-test--with-buffer
    (isled-mode)
    (let* (calls
           (isled-process-function
            (lambda (_dir request callback)
              (setq calls (append calls (list (list request callback)))))))
      (isled-loading-request 'refresh)
      (isled-loading-test--reply (pop calls) 'refresh)
      (let ((original isled--snapshot))
        (isled-filter-closed)
        (isled-filter-open)
        (should (= (length calls) 1))
        (isled-loading-test--reply (pop calls) 'view)
        (should (eq original isled--snapshot))
        (should (= (length calls) 1))
        (isled-loading-test--reply (pop calls) 'view)
        (should (eq isled--filter 'open))))))

(ert-deftest isled-loading-failed-history-destination-retains-history ()
  (isled-loading-test--with-buffer
    (isled-mode)
    (let* (call
           (isled-process-function
            (lambda (_dir request callback) (setq call (list request callback)))))
      (isled-loading-request 'refresh)
      (isled-loading-test--reply call 'refresh)
      (setq isled--back-history (list (isled--initial-view-state 'closed)))
      (let ((history isled--back-history))
        (isled-history-back)
        (funcall (cadr call) (isled-command-result-create :status 1 :stderr "Locked"))
        (should (eq history isled--back-history))
        (should-not isled--forward-history)
        (should (eq isled--filter 'open))))))

(ert-deftest isled-loading-unchanged-details-skip-rendering ()
  (isled-loading-test--with-displayed-buffer
    (isled-mode)
    (let* (call
           (isled-process-function
            (lambda (_dir request callback) (setq call (list request callback)))))
      (isled-loading-request 'refresh)
      (isled-loading-test--reply call 'refresh)
      (isled--toggle-issue)
      (isled-loading-request 'details)
      (isled-loading-test--reply call 'details '("0001"))
      (isled-loading-request 'details)
      (cl-letf (((symbol-function 'isled--render)
                 (lambda (&rest _) (ert-fail "Unchanged data was rendered again"))))
        (isled-loading-test--reply call 'details))
      (should-not isled--auto-revert-error))))

(ert-deftest isled-loading-discarded-view-cannot-be-resurrected ()
  (let ((buffer (generate-new-buffer " *bounded-discarded*")) call)
    (unwind-protect
        (let ((isled-process-function
               (lambda (_dir request callback) (setq call (list request callback)))))
          (with-current-buffer buffer
            (isled-mode)
            (isled-loading-request 'refresh)
            (fundamental-mode))
          (isled-loading-test--reply call 'refresh)
          (with-current-buffer buffer
            (should (eq major-mode 'fundamental-mode))
            (should-not isled--snapshot)))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest isled-loading-fresh-missing-target-removes-cached-navigation ()
  (isled-loading-test--with-buffer
    (isled-mode)
    (isled-data-accept
     (isled-frontend-decode (isled-loading-test--wire 'refresh)))
    (isled-data-accept
     (isled-frontend-decode (isled-loading-test--wire 'details '("0001"))))
    (let* ((response (isled-frontend-decode
                      (isled-loading-test--wire 'details '("0001"))))
           (detail (car (isled-response-changes response))))
      (dolist (ref (isled-issue-references (isled-detail-issue detail)))
        (when (equal (isled-inline-reference-target-id ref) "0002")
          (setf (isled-inline-reference-resolution ref) 'missing)))
      (setf (isled-detail-targets detail)
            (seq-remove (lambda (issue) (equal (isled-issue-id issue) "0002"))
                        (isled-detail-targets detail)))
      (setq isled--snapshot (isled-data-accept response)
            isled--expanded-ids '("0001"))
      (should-not (isled-view-find-target isled--snapshot "0002"))
      (isled--render)
      (let ((position (point-min)))
        (while (< position (point-max))
          (when-let ((ref (get-text-property position 'isled-reference)))
            (when (equal (isled-inline-reference-target-id ref) "0002")
              (should-not (get-text-property position 'isled-target))))
          (setq position (next-single-property-change
                          position 'isled-reference nil (point-max))))))))

(ert-deftest isled-loading-filter-during-opening-still-finishes-setup ()
  (let ((isled-auto-revert nil) calls buffer
        (isled-process-function nil))
    (setq isled-process-function
          (lambda (_dir request callback)
            (setq calls (append calls (list (list request callback))))))
    (unwind-protect
        (save-window-excursion
          (setq buffer (isled-buffers-open "/tmp/example" "/tmp/example" nil nil))
          (with-current-buffer buffer
            (isled-filter-closed)
            (isled-loading-test--reply (pop calls) 'refresh)
            (should (equal isled--root "/tmp/example"))
            (isled-loading-test--reply (pop calls) 'view)
            (should (eq isled--filter 'closed))
            (should (equal (buffer-name) (isled--buffer-name isled--root)))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest isled-loading-reopening-restores-window-observation ()
  (let ((isled-auto-revert nil) calls first placeholder
        (isled-process-function nil))
    (setq isled-process-function
          (lambda (_dir request callback)
            (setq calls (append calls (list (list request callback))))))
    (unwind-protect
        (save-window-excursion
          (setq first (isled-buffers-open "/tmp/example" "/tmp/example" nil nil))
          (isled-loading-test--reply (pop calls) 'refresh)
          (setq placeholder (isled-buffers-open "/tmp/example" "/tmp/example" nil nil))
          (should (eq first placeholder))
          (should-not calls)
          (should (memq first isled-windows--buffers))
          (should (eq (window-buffer (selected-window)) first)))
      (when (buffer-live-p first) (kill-buffer first))
      (when (buffer-live-p placeholder) (kill-buffer placeholder)))))

(ert-deftest isled-loading-hidden-initial-view-defers-rendering ()
  (isled-loading-test--with-displayed-buffer
    (isled-mode)
    (let* ((buffer (current-buffer)) calls
           (isled-process-function
            (lambda (_root request callback) (push (list request callback) calls))))
      (setq isled-loading-initializer #'ignore)
      (isled-loading-request 'refresh)
      (set-window-buffer (selected-window) (get-buffer-create "*scratch*"))
      (isled-loading-test--reply (pop calls) 'refresh)
      (should isled-loading-dirty)
      (should (= (length isled-rows) 0))
      (set-window-buffer (selected-window) buffer)
      (isled-loading--display-changed)
      (should-not isled-loading-dirty)
      (should (> (length isled-rows) 0)))))

(ert-deftest isled-loading-failure-does-not-retry-on-every-deadline ()
  (isled-loading-test--with-displayed-buffer
   (isled-mode)
   (let* (calls
         (isled-process-function
          (lambda (_directory request callback) (push (list request callback) calls))))
     (isled-loading-request 'refresh)
     (isled-loading-test--reply (pop calls) 'refresh)
     (isled--toggle-issue)
     (isled-loading-test--idle (current-buffer))
     (should (= (length calls) 1))
     (funcall (cadar calls) (isled-command-result-create :status 1 :stderr "Failure"))
     (setq calls nil)
     (should isled--auto-revert-error)
     (dotimes (_ 3) (isled-loading-test--idle (current-buffer)))
     (should-not calls)
     (isled-loading-request 'refresh)
     (should (= (length calls) 1)))))

(ert-deftest isled-loading-schedule-dispatches-without-firing-a-timer ()
  (isled-loading-test--with-displayed-buffer
   (isled-mode)
   (let* (calls
          (isled-process-function
           (lambda (_directory request callback) (push (list request callback) calls))))
     (isled-loading-request 'refresh)
     (isled-loading-test--reply (pop calls) 'refresh)
     (isled--toggle-issue)
     (isled-loading-schedule)
     (should (= (length calls) 1))
     (should (equal (alist-get 'mode (json-parse-string (caar calls) :object-type 'alist)) "details"))
     (dotimes (_ 4) (isled-loading-schedule))
     (should (= (length calls) 1))
     (should-not isled-loading-pending))))

(provide 'isled-loading-test)
;;; isled-loading-test.el ends here
