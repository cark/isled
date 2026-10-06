;;; isled-filter-interfaces-test.el --- Filter interface contracts -*- lexical-binding: t; -*-

;;; Commentary:
;; Token bounds, insertion, prompt setup and automatic completion lifecycle.
;;; Code:
(require 'ert)
(require 'isled-loading-test)
(require 'isled-filter)

(ert-deftest isled-filter-inline-scopes-current-token ()
  (dolist (case '(("s:open t:ru suffix" 11 8 12 ("t:rust" "t:runtime"))
                  ("s:open   suffix" 8 9 9 ("t:rust" "t:runtime" "k:bug" "s:open" "o:oldest-first" "o:id"))
                  ("k: suffix" 2 1 3 ("k:bug"))
                  ("s: suffix" 2 1 3 ("s:open"))))
    (with-temp-buffer
      (insert (nth 0 case))
      (goto-char (1+ (nth 1 case)))
      (setq-local isled-filter-completion-values
                  '("t:rust" "t:runtime" "k:bug" "s:open"))
      (pcase-let ((`(,start ,end ,table . ,_) (isled-filter-inline-at-point)))
        (should (= start (nth 2 case)))
        (should (= end (nth 3 case)))
        (should (equal (all-completions "" table) (nth 4 case))))))
  (dolist (input '("\"t:ru\"" "\"unfinished t:ru"))
    (with-temp-buffer
      (insert input)
      (should-not (isled-filter-inline-at-point)))))

(ert-deftest isled-filter-inline-in-region-preserves-query ()
  (with-temp-buffer
    (insert "s:open t:rus  \"two words\" k:bug")
    (goto-char 12)
    (setq-local completion-at-point-functions
                '(isled-filter-inline-at-point)
                isled-filter-completion-values '("t:rust" "t:runtime"))
    (let ((completion-styles '(basic))) (completion-at-point))
    (should (equal (buffer-string) "s:open t:rust  \"two words\" k:bug"))
    (should (= (point) 14))))

(ert-deftest isled-filter-automatic-completion-coalesces-and-cleans-up ()
  (with-temp-buffer
    (insert "t:")
    (unwind-protect
        (progn
          (isled-filter-inline-changed)
          (let ((first isled-filter-inline--timer))
            (should (memq first timer-list))
            ;; An unchanged point/input must not rearm after UI dismissal.
            (isled-filter-inline-changed)
            (should (eq first isled-filter-inline--timer))
            (goto-char (point-min))
            (isled-filter-inline-changed)
            (should-not (memq first timer-list))
            (should (timerp isled-filter-inline--timer)))
          (let ((pending isled-filter-inline--timer))
            (isled-filter-inline-stop)
            (should-not (memq pending timer-list))
            (isled-filter-inline-changed)
            (should-not isled-filter-inline--timer)))
      (isled-filter-inline-stop))))

(ert-deftest isled-filter-inline-ignores-stale-and-other-prompts ()
  (with-temp-buffer
    (insert "t:ru k:b")
    (unwind-protect
        (progn
          (isled-filter-inline-changed)
          (let ((old-state isled-filter-inline--state))
            (goto-char 5)
            (isled-filter-inline-changed)
            (let ((pending isled-filter-inline--timer))
              (isled-filter-inline--show (current-buffer) old-state)
              (should (eq pending isled-filter-inline--timer))))
          ;; Another (including recursive) prompt must not display this query.
          (cl-letf (((symbol-function 'active-minibuffer-window) #'minibuffer-window)
                    ((symbol-function 'completion-help-at-point)
                     (lambda () (ert-fail "Displayed completion in another prompt"))))
            (isled-filter-inline--show
             (current-buffer) isled-filter-inline--state)))
      (isled-filter-inline-stop))))

(ert-deftest isled-filter-picker-preserves-surroundings-and-cancellation ()
  (dolist (cancel '(nil t))
    (with-temp-buffer
      (insert "s:open t:rust  \"two words\" k:bug")
      (goto-char 12)
      (let ((before (buffer-string)) (position (point))
            (isled-filter-completion-values '("t:rust" "t:runtime")))
        (cl-letf (((symbol-function 'minibuffer-contents-no-properties)
                   (lambda () (buffer-string)))
                  ((symbol-function 'minibuffer-prompt-end) (lambda () 1))
                  ((symbol-function 'completing-read)
                   (lambda (_prompt choices &rest _)
                     (should (equal (all-completions "" choices) '("t:rust" "t:runtime")))
                     (if cancel (signal 'quit nil) "t:runtime"))))
          (isled-filter-picker-pick))
        (if cancel
            (progn (should (equal (buffer-string) before))
                   (should (= (point) position)))
          (should (equal (buffer-string) "s:open t:runtime  \"two words\" k:bug"))
          (should (= (point) 17)))))))

(ert-deftest isled-filter-minibuffer-scopes-current-token ()
  (let* ((choices '("t:rust" "t:runtime" "k:bug" "s:open"))
         (table (apply-partially #'isled-filter-minibuffer-table choices)))
    (should (equal (all-completions "s:open t:ru" table) '("t:rust" "t:runtime")))
    (should (equal (all-completions "s:open " table)
                   (append choices '("o:oldest-first" "o:id"))))
    (should (equal (completion-boundaries "s:open t:ru" table nil "st k:bug") '(7 . 2)))
    (should (equal (try-completion "s:open k:b" table) "s:open k:bug "))))

(ert-deftest isled-filter-minibuffer-falls-back-without-local-vertico ()
  (with-temp-buffer
    (let ((called nil))
      (cl-letf (((symbol-function 'minibuffer-complete) (lambda () (setq called t))))
        (isled-filter-minibuffer-insert))
      (should called))))

(ert-deftest isled-filter-minibuffer-retains-suffix-and-cursor ()
  (dolist (input '("s:open t:ru|" "s:open t:ru| word"
                   "s:open t:ru|st word" "t:ru| \"two words\" k:bug"
                   "s:open t:ru|  word" "s:open t:ru| t:rust"))
    (with-temp-buffer
      (let* ((cursor (string-match-p "|" input))
             (text (concat (substring input 0 cursor) (substring input (1+ cursor))))
             (minibuffer-completion-table
              (apply-partially #'isled-filter-minibuffer-table '("t:rust" "t:runtime")))
             (minibuffer-completion-predicate nil)
             (bounds (completion-boundaries (substring text 0 cursor)
                                            minibuffer-completion-table nil
                                            (substring text cursor)))
             (replacement (concat (substring text 0 (car bounds)) "t:runtime"))
             (suffix (substring text (+ cursor (cdr bounds)))))
        (setq-local vertico--input (list text) vertico--total 2)
        (insert text)
        (goto-char (1+ cursor))
        (cl-letf (((symbol-function 'vertico-insert)
                   (lambda () (delete-minibuffer-contents) (insert replacement))))
          (isled-filter-minibuffer-insert))
        (should (equal (buffer-string) (concat replacement suffix)))
        (should (= (point) (1+ (length replacement))))))))

(ert-deftest isled-filter-minibuffer-stock-refresh-observes-text-and-point ()
  (isled-loading-test--with-displayed-buffer
    (let ((calls 0))
      (cl-letf (((symbol-function 'minibuffer-window) #'selected-window)
                ((symbol-function 'isled-filter-minibuffer--show)
                 (lambda () (setq calls (1+ calls)))))
        (isled-filter-minibuffer-changed)
        (isled-filter-minibuffer-changed)
        (should (= calls 1))
        (insert "t:ru k:bug")
        (isled-filter-minibuffer-changed)
        (should (= calls 2))
        (backward-char)
        (isled-filter-minibuffer-changed)
        (should (= calls 3))
        (isled-filter-minibuffer-changed)
        (should (= calls 3))))))

(ert-deftest isled-filter-common-token-retains-bounds-and-text ()
  (should (equal (isled-filter-completion-token "s:open t:rust k:bug" 11)
                 '(7 13 "t:ru" "t:rust")))
  (should (equal (isled-filter-completion-token "s:open  k:bug" 7)
                 '(7 7 "" "")))
  (dolist (text '("\"t:ru\"" "\"unfinished"))
    (should-not (isled-filter-completion-token text 2)))
  (should (equal (isled-filter-completion-token "word" 2)
                 '(0 4 "wo" "word"))))

(ert-deftest isled-filter-adapters-scope-once-at-their-own-boundary ()
  (let* ((choices '("t:rust" "k:bug" "s:open"))
         (scope (symbol-function 'isled-filter-completion-choices)) calls)
    (cl-letf (((symbol-function 'isled-filter-completion-choices)
               (lambda (part items) (push part calls) (funcall scope part items))))
      ;; Point before the colon distinguishes whole-token inline scoping from
      ;; the picker's before-point initial input: the picker offers all kinds.
      (with-temp-buffer
        (insert "t:rust suffix") (goto-char 2)
        (setq-local isled-filter-completion-values choices)
        (let ((table (nth 2 (isled-filter-inline-at-point))))
          (should (equal (all-completions "" table) '("t:rust"))))
        (should (equal calls '("t:rust"))))
      (setq calls nil)
      (should (equal (isled-filter-picker-context "t:rust suffix" 1)
                     (list 0 6 "t")))
      (should-not calls)
      (setq calls nil)
      (isled-filter-minibuffer-table choices "s:open t:r" nil t)
      (should (equal calls '("t:r"))))))

(ert-deftest isled-filter-picker-rejects-literal-text ()
  (dolist (text '("word" "\"t:ru\"" "\"unfinished"))
    (should-error (isled-filter-picker-context text 2)
                  :type 'user-error)))

(ert-deftest isled-filter-interface-setup-stays-local ()
  (let ((global-capfs (default-value 'completion-at-point-functions))
        (global-post-command (default-value 'post-command-hook)))
    (dolist (case '((inline-suggestions . isled-filter-inline-complete)
                    (separate-filter-picker . isled-filter-picker-pick)
                    (minibuffer-suggestions . isled-filter-minibuffer-insert)))
      (with-temp-buffer
        (use-local-map (copy-keymap minibuffer-local-map))
        (isled-filter--setup (selected-window) '("t:rust") (car case))
        (should (eq (key-binding (kbd "TAB")) (cdr case)))
        (should (eq (key-binding (kbd "RET")) #'isled-filter--accept))
        (should (memq #'isled-filter--changed post-command-hook))
        (should (eq isled-filter--origin (selected-window)))
        (pcase (car case)
          ('inline-suggestions
           (should (equal isled-filter-completion-values '("t:rust")))
           (should (equal completion-at-point-functions '(isled-filter-inline-at-point)))
           (should (memq #'isled-filter-inline-stop minibuffer-exit-hook)))
          ('separate-filter-picker
           (should (equal isled-filter-completion-values '("t:rust")))
           (should-not (memq #'isled-filter-inline-changed post-command-hook)))
          ('minibuffer-suggestions
           (should completion-no-auto-exit)
           (should (memq #'isled-filter-minibuffer-stop minibuffer-exit-hook))))))
    (should (equal (default-value 'completion-at-point-functions) global-capfs))
    (should (equal (default-value 'post-command-hook) global-post-command))
    (with-temp-buffer
      ;; A subsequent or nested plain prompt must not inherit adapter state.
      (should-not isled-filter--origin)
      (should-not (memq #'isled-filter--changed post-command-hook))
      (should-not (memq #'isled-filter-inline-at-point completion-at-point-functions)))))

(ert-deftest isled-filter-interface-dispatches-the-reader ()
  (dolist (interface '(inline-suggestions separate-filter-picker minibuffer-suggestions))
    (let (observed)
      (cl-letf (((symbol-function 'read-from-minibuffer)
                 (lambda (_prompt initial _map _read history &rest _)
                   (setq observed (list 'plain initial history)) "t:rust"))
                ((symbol-function 'isled-filter-minibuffer-read)
                 (lambda (initial choices)
                   (setq observed (list 'minibuffer initial choices)) "t:rust")))
        (should (equal (isled-filter--read "t:r" '("t:rust") interface) "t:rust")))
      (should (equal observed
                     (if (eq interface 'minibuffer-suggestions)
                         '(minibuffer "t:r" ("t:rust"))
                       '(plain "t:r" isled-filter-history)))))))

(ert-deftest isled-filter-rejects-unknown-interface-before-opening ()
  (with-temp-buffer
    (isled-mode)
    (let ((isled-filter-interface 'unknown-interface))
      (cl-letf (((symbol-function 'isled-filter--read)
                 (lambda (&rest _) (ert-fail "Opened an invalid interface"))))
        (should-error (isled-filter) :type 'user-error))
      (should-not isled-filter-active))))

(ert-deftest isled-filter-minibuffer-preserves-vertico-scroll-binding ()
  (dolist (vertico '(nil t))
    (with-temp-buffer
      (let ((parent (make-sparse-keymap)))
        (define-key parent (kbd "M-v") #'scroll-down-command)
        (use-local-map parent)
        (when vertico (setq-local vertico--input t))
        (isled-filter-minibuffer-setup nil)
        (should (eq (key-binding (kbd "M-v"))
                    (if vertico #'scroll-down-command #'switch-to-completions)))
        (when vertico
          (should-not (memq #'isled-filter-minibuffer-changed post-command-hook))
          (should-not (memq #'isled-filter-minibuffer-stop minibuffer-exit-hook)))))))

(ert-deftest isled-filter-public-names-and-key ()
  (should (eq (lookup-key isled-mode-map (kbd "f")) #'isled-filter))
  (should-not (eq (lookup-key isled-mode-map (kbd "s"))
                  #'isled-filter))
  (should (eq (indirect-function 'isled-search)
              (indirect-function 'isled-filter)))
  (let ((isled-search-interface 'separate-filter-picker))
    (should (eq isled-filter-interface 'separate-filter-picker)))
  (let ((isled-filter-interface 'minibuffer-suggestions))
    (should (eq isled-search-interface 'minibuffer-suggestions))))

(ert-deftest isled-filter-display-keeps-valid-optional-ui-selection ()
  (with-temp-buffer
    (insert "t:r suffix") (goto-char 4)
    (setq-local vertico--input '("t:r" . 3)
                vertico--index 1 vertico--candidates '("t:runtime" "t:rust"))
    (progn
      (cl-letf (((symbol-function 'vertico--update)
                 (lambda () (setq vertico--candidates '("t:rust") vertico--index 0)))
                ((symbol-function 'vertico--exhibit) #'ignore))
               (should (isled-filter-display-vertico))
               (should (equal (nth vertico--index vertico--candidates) "t:rust"))))
    (setq-local completion-in-region-function 'corfu--in-region
                  corfu-mode t corfu--index 1 corfu--candidates '("t:runtime" "t:rust"))
    (let ((completion-in-region-mode t))
      (cl-letf (((symbol-function 'corfu-quit)
                 (lambda () (setq completion-in-region-mode nil corfu--index -1
                                  corfu--candidates nil)))
                ((symbol-function 'corfu--auto-complete-deferred)
                 (lambda () (setq completion-in-region-mode t corfu--index -1
                                  corfu--candidates '("t:rust"))))
                ((symbol-function 'corfu--exhibit) #'ignore))
               (setq isled-filter-completion-pending t)
               (should (isled-filter-display-corfu))
               (should-not completion-in-region-mode)
               (setq isled-filter-completion-pending nil)
               (should (isled-filter-display-corfu))
               (should (equal (nth corfu--index corfu--candidates) "t:rust"))))
    (should (equal (buffer-string) "t:r suffix"))
    (should (= (point) 4))))

(ert-deftest isled-filter-display-does-not-carry-selection-between-contexts ()
  (with-temp-buffer
    (let ((old (isled-filter-completion-context "s:o" 3))
          (next (isled-filter-completion-context "s:open " 7)))
      (setq-local isled-filter-display--selection "s:open"
                  isled-filter-display--selection-context old
                  isled-filter-completion-context next
                  completion-in-region-function 'corfu--in-region
                  corfu-mode t corfu--index 0 corfu--candidates '("s:open"))
      (let ((completion-in-region-mode t))
        (cl-letf (((symbol-function 'corfu-quit)
                   (lambda () (setq completion-in-region-mode nil corfu--index -1
                                    corfu--candidates nil)))
                  ((symbol-function 'corfu--auto-complete-deferred)
                   (lambda () (setq completion-in-region-mode t corfu--index 0
                                    corfu--candidates '("k:bug" "s:open"))))
                  ((symbol-function 'corfu--exhibit) #'ignore))
          (should (isled-filter-display-corfu))
          (should (equal (nth corfu--index corfu--candidates) "k:bug"))
          (should-not isled-filter-display--selection)
          (should (eq isled-filter-display--selection-context next))
          ;; A second refresh of this exact request may retain its selection.
          (setq corfu--index 1)
          (should (isled-filter-display-corfu))
          (should (equal (nth corfu--index corfu--candidates) "s:open"))
          (should (equal isled-filter-display--selection "s:open")))))))

(ert-deftest isled-filter-stock-display-preserves-selection-across-rebuild ()
  (let ((completions (get-buffer-create "*Completions*")))
    (unwind-protect
        (with-temp-buffer
          (insert "t:r suffix") (goto-char 4)
          (with-current-buffer completions
            (let ((inhibit-read-only t))
              (erase-buffer)
              (insert (propertize "t:runtime" 'completion--string "t:runtime") "\n"
                      (propertize "t:rust" 'completion--string "t:rust"))
              (goto-char (point-max)) (backward-char)))
          (isled-filter-display-stock
           (lambda ()
             (with-current-buffer completions
               (let ((inhibit-read-only t))
                 (erase-buffer) (completion-list-mode)
                 (insert (propertize "t:rust" 'completion--string (copy-sequence "t:rust"))
                         "\n" (propertize "t:other" 'completion--string "t:other"))))))
          (should (with-current-buffer completions
                    (equal (get-text-property (point) 'completion--string) "t:rust")))
          (should (equal (buffer-string) "t:r suffix"))
          (should (= (point) 4)))
      (kill-buffer completions))))

(ert-deftest isled-filter-inline-manual-does-not-open-on-edit-or-reply ()
  (isled-loading-test--with-displayed-buffer
    (let ((isled-filter-inline-auto nil) completed)
      (insert "s:")
      (isled-filter-inline-setup '("s:open" "s:closed"))
      (cl-letf (((symbol-function 'minibuffer-window) #'selected-window)
                ((symbol-function 'isled-filter-display-stock)
                 (lambda (&rest _) (ert-fail "Opened stock completion without TAB")))
                ((symbol-function 'isled-filter-display-corfu)
                 (lambda () (ert-fail "Opened Corfu without TAB")))
                ((symbol-function 'completion-at-point) (lambda () (setq completed t))))
        (isled-filter-inline-changed)
        (isled-filter-inline-refresh)
        (should-not isled-filter-inline--timer)
        (isled-filter-inline-complete)
        (should completed)
        (cl-letf (((symbol-function 'isled-filter-inline--visible-p) (lambda () t)))
          (isled-filter-inline-changed)
          (should-not isled-filter-inline--timer))))))

(ert-deftest isled-filter-inline-manual-pending-tab-is-context-bound ()
  (isled-loading-test--with-displayed-buffer
    (let ((isled-filter-inline-auto nil) (shown 0))
      (insert "s:")
      (setq-local isled-filter-completion-pending t)
      (isled-filter-inline-complete)
      (should isled-filter-inline--requested)
      (setq isled-filter-completion-pending nil)
      (cl-letf (((symbol-function 'minibuffer-window) #'selected-window)
                ((symbol-function 'isled-filter-inline--show)
                 (lambda (&rest _) (cl-incf shown))))
        (isled-filter-inline-refresh)
        (should (= shown 1))
        (should-not isled-filter-inline--requested)
        ;; Once dismissed, delivery alone must not reopen suggestions.
        (isled-filter-inline-refresh)
        (should (= shown 1))
        (setq isled-filter-completion-pending t)
        (isled-filter-inline-complete)
        (insert "x")
        (setq isled-filter-completion-pending nil)
        (isled-filter-inline-refresh)
        (should (= shown 1))))))

(ert-deftest isled-filter-inline-manual-corfu-settings-are-local ()
  (cl-progv '(corfu-auto) '(t)
    (with-temp-buffer
      (let ((isled-filter-inline-auto nil))
        (setq-local corfu-mode t completion-in-region-function 'corfu--in-region)
        (add-hook 'post-command-hook #'corfu--auto-post-command nil t)
        (isled-filter-inline-setup '("s:open"))
        (should-not (symbol-value 'corfu-auto))
        (should-not (memq #'corfu--auto-post-command post-command-hook))))
    (should (symbol-value 'corfu-auto))))

(provide 'isled-filter-interfaces-test)
;;; isled-filter-interfaces-test.el ends here
