;;; isled-filter-interaction-test.el --- Filter interaction contracts -*- lexical-binding: t; -*-

;;; Commentary:
;; Query grammar, completion boundaries, state restoration and asynchronous fences.
;;; Code:
(require 'ert)
(require 'isled-loading-test)

(ert-deftest isled-filter-parses-conjunctive-terms-and-literals ()
  (let ((criteria (isled-filter-query-criteria
                   "s:closed t:rust k:bug timeout \"two words\" \"t:rust\"")))
    (should (equal (alist-get 'status criteria) "closed"))
    (should (equal (alist-get 'tags criteria) ["rust"]))
    (should (equal (alist-get 'kinds criteria) ["bug"]))
    (should (equal (alist-get 'text criteria) ["timeout" "two words" "t:rust"])))
  (should (equal (alist-get 'status (isled-filter-query-criteria "")) "all"))
  (should (equal (alist-get 'status (isled-filter-query-criteria "s:open s:closed"))
                 "closed"))
  (dolist (input '("t:" "k:" "s:all" "s:close" "\"unfinished"))
    (should-error (isled-filter-query-criteria input) :type 'user-error))
  (should (equal (alist-get 'text (isled-filter-query-criteria "\"t:\"")) ["t:"])))

(ert-deftest isled-filter-status-buttons-preserve-other-terms ()
  (should (equal (isled-filter-query-status "s:open t:rust \"two words\"" 'all)
                 "t:rust \"two words\""))
  (should (equal (isled-filter-query-status "t:rust s:open" 'closed)
                 "s:closed t:rust"))
  (should (equal (isled-filter-query-text 'open) "s:open ")))

(ert-deftest isled-filter-initial-leaves-room-for-next-term ()
  (dolist (case '(("" . "") (all . "") (open . "s:open ")
                  ("t:rust" . "t:rust ") ("t:rust " . "t:rust ")
                  ("t:rust  " . "t:rust  ") ("t:rust\t" . "t:rust\t")
                  ("\"two words\"" . "\"two words\" ")))
    (should (equal (isled-filter-query-initial (car case)) (cdr case)))))

(ert-deftest isled-filter-preview-coalesces-and-rejects-obsolete-replies ()
  (isled-loading-test--with-displayed-buffer
    (isled-mode)
    (let* (calls
           (isled-process-function
            (lambda (_root request callback) (push (list request callback) calls))))
      (isled-loading-request 'refresh)
      (isled-loading-test--reply (pop calls) 'refresh)
      (isled-filter--request "t:rust")
      (isled-filter--request "t:rust word")
      (isled-filter--request "t:rust newer")
      (should (= (length calls) 1))
      (isled-loading-test--reply (pop calls) 'view)
      (should (eq isled--filter 'open))
      (should (= (length calls) 1))
      (should (equal (alist-get 'text (alist-get 'filter
                               (json-parse-string (caar calls) :object-type 'alist))) ["newer"]))
      (isled-loading-test--reply (pop calls) 'view)
      (should (equal isled--filter "t:rust newer"))
      (should-not isled--auto-revert-error))))

(ert-deftest isled-filter-cancellation-restores-query-and-position ()
  (isled-loading-test--with-displayed-buffer
    (isled-mode)
    (let* (calls
           (isled-process-function
            (lambda (_root request callback) (push (list request callback) calls))))
      (isled-loading-request 'refresh)
      (isled-loading-test--reply (pop calls) 'refresh)
      (isled-sections-goto-id "0001")
      (forward-char 2)
      (let ((before (point)))
        (cl-letf (((symbol-function 'read-from-minibuffer)
                   (lambda (&rest _)
                     (isled-filter--request "s:closed")
                     (signal 'quit nil))))
          (condition-case nil (isled-filter) (quit nil)))
        (should-not isled-filter-active)
        (isled-loading-test--reply (pop calls) 'view)
        (isled-loading-test--reply (pop calls) 'view)
        (should (eq isled--filter 'open))
        (should (= (point) before))
        (should-not isled--auto-revert-error)))))

(ert-deftest isled-filter-retains-criteria-through-preview-and-acceptance ()
  (isled-loading-test--with-displayed-buffer
    (isled-mode)
    (let* ((view (current-buffer)) (window (selected-window)) calls
           (parses 0) (parse (symbol-function 'isled-filter-query-criteria))
           (isled-process-function
            (lambda (_root request callback) (push (list request callback) calls)))
           (isled-filter--accepted-query nil))
      (cl-letf (((symbol-function 'isled-filter-query-criteria)
                 (lambda (query) (cl-incf parses) (funcall parse query))))
        (isled-loading-request 'refresh)
        (isled-loading-test--reply (pop calls) 'refresh)
        (setq parses 0 isled-filter-active t)
        (with-temp-buffer
          (setq-local isled-filter--origin window
                      isled-filter--view view)
          (insert "t:rust")
          (isled-filter--changed)
          (insert " newer")
          (isled-filter--changed)
          (isled-filter--changed)
          (should (= parses 4))
          (cl-letf (((symbol-function 'exit-minibuffer) #'ignore))
            (isled-filter--accept)))
        (should (= parses 4))
        (with-current-buffer view
          (isled-filter--request
           (car isled-filter--accepted-query)
           (cdr isled-filter--accepted-query)))
        (isled-loading-test--reply (pop calls) 'view)
        (isled-loading-test--reply (pop calls) 'view)
        (should (= parses 4))
        (should (equal isled--filter "t:rust newer"))))))

(ert-deftest isled-filter-invalid-edit-clears-proof-and-fences-replies ()
  (isled-loading-test--with-displayed-buffer
    (isled-mode)
    (let* ((view (current-buffer)) (window (selected-window)) calls
           (isled-process-function
            (lambda (_root request callback) (push (list request callback) calls))))
      (isled-loading-request 'refresh)
      (isled-loading-test--reply (pop calls) 'refresh)
      (setq isled-filter-active t)
      (with-temp-buffer
        (setq-local isled-filter--origin window
                      isled-filter--view view)
        (insert "t:rust")
        (isled-filter--changed)
        (should isled-filter--criteria)
        (erase-buffer) (insert "t:")
        (isled-filter--changed)
        (should-not isled-filter--criteria)
        (should-error (isled-filter--accept) :type 'user-error))
      (with-current-buffer view
        (should isled-filter-feedback)
        (should (eq (car isled-loading-pending) 'choices))
        (isled-loading-test--reply (pop calls) 'view)
        (should (eq isled--filter 'open))))))

(ert-deftest isled-filter-noninteractive-loading-still-validates ()
  (with-temp-buffer
    (isled-mode)
    (let ((isled-loading-running t))
      (isled-loading-request 'view (isled--initial-view-state 'closed))
      (let ((pending isled-loading-pending)
            (generation isled-loading-generation))
        (should-error
         (isled-loading-request 'view (isled--initial-view-state "t:"))
         :type 'user-error)
        (should (eq pending isled-loading-pending))
        (should (eq generation isled-loading-generation))
        (should (equal (alist-get 'status (nth 5 pending)) "closed"))))))

(ert-deftest isled-filter-displaced-view-cleans-up-without-restoring ()
  (isled-loading-test--with-displayed-buffer
    (isled-mode)
    (let ((view (current-buffer))
          (replacement (generate-new-buffer " *filter replacement*")))
      (unwind-protect
          (cl-letf (((symbol-function 'isled-filter--read)
                     (lambda (&rest _)
                       (set-window-buffer (selected-window) replacement)
                       "t:rust"))
                    ((symbol-function 'isled-loading-request)
                     (lambda (&rest _) (ert-fail "Requested a displaced view"))))
            (should-error (isled-filter) :type 'user-error)
            (with-current-buffer view
              (should-not isled-filter-active)
              (should-not isled-filter-feedback)
              (should-not isled-loading-pending)
              (should isled-loading-generation)))
        (kill-buffer replacement)))))

(ert-deftest isled-filter-reader-result-still-validates-without-ret ()
  (isled-loading-test--with-displayed-buffer
    (isled-mode)
    (let ((requests 0))
      (cl-letf (((symbol-function 'isled-filter--read)
                 (lambda (&rest _) "t:"))
                ((symbol-function 'isled-loading-request)
                 (lambda (mode state &rest _)
                   (cl-incf requests)
                   (should (eq mode 'view))
                   (should (eq (isled--view-state-filter state) 'open)))))
        (should-error (isled-filter) :type 'user-error))
      (should (= requests 1))
      (should-not isled-filter-active))))

(ert-deftest isled-filter-context-excludes-only-the-edited-occurrence ()
  (let* ((query "t:rust  t:rust k:bug Straße \"two words\" tail")
         (context (isled-filter-completion-context query 3))
         (criteria (isled-filter-context-criteria context)))
    (should (= (isled-filter-context-start context) 0))
    (should (= (isled-filter-context-end context) 6))
    (should (equal (isled-filter-context-whole context) "t:rust"))
    (should (equal (alist-get 'tags criteria) ["rust"]))
    (should (equal (alist-get 'kinds criteria) ["bug"]))
    (should (equal (alist-get 'text criteria) ["Straße" "two words" "tail"])))
  (let ((criteria (isled-filter-context-criteria
                   (isled-filter-completion-context "word word k:bug" 2))))
    (should (equal (alist-get 'text criteria) ["word"])))
  (dolist (query '("t: k:bug" "k: t:rust" "s:cl s:open t:rust"))
    (should (isled-filter-completion-context query 2)))
  (should-error (isled-filter-completion-context "t:rust k:" 2) :type 'user-error)
  (should-not (isled-filter-completion-context "\"two words\" t:rust" 3)))

(ert-deftest isled-filter-context-status-removes-every-status-constraint ()
  (let* ((query "s:open t:rust s:closed \"two words\"")
         (context (isled-filter-completion-context query 3)))
    (should (equal (isled-filter-context-criteria context)
                   '((status . "all") (tags . ["rust"]) (kinds . [])
                     (text . ["two words"])))))
  ;; Manually written queries still use their last status.
  (should (equal (alist-get 'status (isled-filter-query-criteria
                                     "s:open t:rust s:closed")) "closed")))

(ert-deftest isled-filter-completion-insertion-replaces-statuses-in-place ()
  (dolist (query '("s:closed t:rust s:open  \"two words\""
                   "t:rust s:closed  \"two words\" s:open"))
    (with-temp-buffer
      (insert query)
      (goto-char (1+ (+ (string-match "s:closed" query) 8)))
      (isled-filter-completion-status-exit
       (buffer-substring-no-properties (point-min) (point)) 'finished)
      (should (equal (alist-get 'status (isled-filter-query-criteria (buffer-string)))
                     "closed"))
      (should (equal (alist-get 'text (isled-filter-query-criteria (buffer-string)))
                     ["two words"]))
      (should-not (string-match-p "s:open" (buffer-string)))
      (should (= (point) (1+ (+ (string-match "s:closed" (buffer-string)) 8)))))))

(ert-deftest isled-filter-cursor-move-retains-view-generation-and-queues-only-choices ()
  (isled-loading-test--with-displayed-buffer
   (isled-mode)
   (let* ((view (current-buffer)) (window (selected-window)) calls
          (isled-process-function
           (lambda (_root request callback) (push (list request callback) calls))))
     (isled-loading-request 'refresh)
     (isled-loading-test--reply (pop calls) 'refresh)
     (setq isled-filter-active (list t))
     (with-temp-buffer
       (setq-local isled-filter--origin window isled-filter--view view)
       (insert "t:rust k:bug")
       (isled-filter--changed)
       (let ((generation (buffer-local-value 'isled-loading-generation view)))
         (goto-char 4)
         (isled-filter--changed)
         (with-current-buffer view
           (should (eq generation isled-loading-generation))
           (should (eq (car isled-loading-pending) 'choices))
           ;; Current view is still useful despite obsolete choice context.
           (isled-loading-test--reply (pop calls) 'view)
           (should (equal isled--filter "t:rust k:bug"))
           (let ((wire (json-parse-string (caar calls) :object-type 'alist)))
             (should (equal (alist-get 'mode wire) "choices"))
             (should (equal (alist-get 'kinds (alist-get 'choice_filter wire)) ["bug"]))
             (should (equal (alist-get 'tags (alist-get 'choice_filter wire)) [])))
           (isled-loading-test--reply (pop calls) 'choices))
         (should (equal isled-filter-completion-values
                        '("s:open" "s:closed" "t:rust" "k:bug")))
         (should-not isled-filter-completion-pending))))))

(ert-deftest isled-filter-choice-delivery-fences-text-point-session-and-displacement ()
  (isled-loading-test--with-displayed-buffer
   (let* ((view (current-buffer)) (window (selected-window))
          (session (list t))
          (context (isled-filter-completion-context "t:" 2)))
     (setq isled-filter-active session)
     (with-temp-buffer
       (let ((prompt (current-buffer)))
         (insert "t:")
         (setq-local isled-filter-completion-context context
                     isled-filter-completion-pending t)
         (isled-filter--choices-received prompt context window view session '("t:rust"))
         (should (equal isled-filter-completion-values '("t:rust")))
         (setq isled-filter-completion-values nil)
         (backward-char)
         (isled-filter--choices-received prompt context window view session '("t:rust"))
         (should-not isled-filter-completion-values)
         (goto-char (point-max)) (insert "r")
         (isled-filter--choices-received prompt context window view session '("t:rust"))
         (should-not isled-filter-completion-values)
         (delete-char -1)
         (with-current-buffer view (setq isled-filter-active nil))
         (isled-filter--choices-received prompt context window view session '("t:rust"))
         (should-not isled-filter-completion-values)
         (with-current-buffer view (setq isled-filter-active session))
         (set-window-buffer window prompt)
         (isled-filter--choices-received prompt context window view session '("t:rust"))
         (should-not isled-filter-completion-values))))))

(ert-deftest isled-filter-choices-merge-into-pending-view-without-replacing-it ()
  (with-temp-buffer
    (isled-mode)
    (let ((isled-loading-running t))
      (isled-loading-request 'view (isled--initial-view-state "t:rust"))
      (let ((generation isled-loading-generation)
            (completion (list '((status . "all") (kinds . ["bug"])) #'ignore))
            (clears 0))
        (cl-letf (((symbol-function 'isled-expansion-clear)
                   (lambda () (setq clears (1+ clears)))))
          (isled-loading-request 'choices nil nil nil completion))
        (should (= clears 0))
        (should (eq (car isled-loading-pending) 'view))
        (should (equal (nth 4 isled-loading-pending) "t:rust"))
        (should (eq (nth 6 isled-loading-pending) completion))
        (should (eq generation isled-loading-generation))))))

(ert-deftest isled-filter-invalid-other-term-does-not-request-choices ()
  (isled-loading-test--with-displayed-buffer
   (isled-mode)
   (let ((view (current-buffer)) (window (selected-window)) calls)
     (setq isled-filter-active (list t))
     (with-temp-buffer
       (setq-local isled-filter--origin window isled-filter--view view)
       (insert "t:rust k:") (goto-char 4)
       (cl-letf (((symbol-function 'isled-loading-request)
                  (lambda (&rest args) (push args calls))))
                (isled-filter--changed))
       (should-not calls)
       (should-not isled-filter-completion-context)
       (should (buffer-local-value 'isled-filter-feedback view))))))

(ert-deftest isled-filter-empty-and-failed-choices-clear-pending-state ()
  (isled-loading-test--with-displayed-buffer
   (let* ((view (current-buffer)) (window (selected-window)) (session (list t))
          (context (isled-filter-completion-context "t:" 2)))
     (setq isled-filter-active session)
     (with-temp-buffer
       (insert "t:")
       (setq-local isled-filter-completion-context context
                   isled-filter-completion-values '("t:old")
                   isled-filter-completion-pending t)
       (isled-filter--choices-received
        (current-buffer) context window view session nil)
       (should-not isled-filter-completion-values)
       (should-not isled-filter-completion-pending)
       (setq isled-filter-completion-pending t)
       (isled-filter--choices-received
        (current-buffer) context window view session nil '(error "request failed"))
       (should-not isled-filter-completion-pending)
       (should (equal (buffer-local-value 'isled-filter-feedback view)
                      "request failed"))))))

(provide 'isled-filter-interaction-test)
;;; isled-filter-interaction-test.el ends here
