;;; isled-test.el --- Browser tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused ERT coverage for buffer ownership and independent state.

;;; Code:

(require 'ert)

(let ((test-directory
       (file-name-directory (or load-file-name buffer-file-name))))
  (add-to-list 'load-path test-directory)
  (add-to-list 'load-path
               (file-name-directory (directory-file-name test-directory))))

(require 'isled-view-test)
(require 'isled-browser)

(ert-deftest isled-mode-uses-responsive-sections ()
  (with-temp-buffer
    (hl-line-mode 1)
    (isled-mode)
    (should (derived-mode-p 'special-mode))
    (should-not truncate-lines)
    (should word-wrap)
    (should-not font-lock-mode)
    (should-not hl-line-mode)
    (should (eq revert-buffer-function #'isled--revert-buffer))
    (should (eq buffer-stale-function #'isled--buffer-stale-p))
    (should-not buffer-auto-revert-by-notification)
    (should-not isled--notification-watch)
    (should-not isled--notification-timer)
    (should (eq (key-binding (kbd "TAB")) #'isled-next))
    (should (eq (key-binding (kbd "<backtab>")) #'isled-previous))
    (should (eq (key-binding (kbd "C-<return>")) #'isled-collapse-all))
    (should (eq (key-binding "n") #'undefined))
    (should (eq (key-binding "p") #'undefined))
    (should (eq (key-binding (kbd "C-n")) #'next-line))
    (should (eq (key-binding (kbd "C-p")) #'previous-line))
    (should (eq (key-binding (kbd "<down>")) #'next-line))
    (should (eq (key-binding (kbd "<up>")) #'previous-line))
    (should (eq (key-binding (kbd "M-."))
                #'isled-jump-to-reference))
    (should (eq (key-binding (kbd "M-,"))
                #'isled-history-back))
    (should (eq (key-binding (kbd "C-M-,"))
                #'isled-history-forward))
    (should (string-match-p "Isled" (isled--header-line)))
    (should (eq (get-text-property 0 'face (isled--fontified-help))
                'isled-help-delimiter-face))
    (should (eq (get-text-property 1 'face (isled--fontified-help))
                'isled-help-key-face))
    (should (eq (get-text-property 4 'face (isled--fontified-help))
                'isled-help-text-face))
    (should (string-suffix-p "[?] Help" (isled--header-line)))
    (should (eq (key-binding "?") #'isled-help))))

(ert-deftest isled-help-dispatches-in-the-originating-view ()
  (save-window-excursion
    (with-temp-buffer
      (switch-to-buffer (current-buffer))
      (isled-mode)
      (setq isled--snapshot (isled-view-test--snapshot))
      (isled--render)
      (let ((origin (current-buffer)))
        (execute-kbd-macro (kbd "?"))
        (should (eq (current-buffer) origin))
        (should (eq isled--filter 'open))
        (with-current-buffer transient--buffer
          (dolist (label '("Previous line" "Next line" "Backward character"
                           "Forward character" "Page down" "Page up"))
            (should-not (string-match-p label (buffer-string)))))
        (execute-kbd-macro (kbd "RET C-f C-b"))
        (should (isled-sections-expanded-ids))
        (dolist (binding '(("<up>" . previous-line)
                           ("<down>" . next-line)
                           ("<left>" . left-char)
                           ("<right>" . right-char)
                           ("C-v" . scroll-up-command)
                           ("<next>" . scroll-up-command)))
          (should (eq (key-binding (kbd (car binding))) (cdr binding))))
        (let ((start (point)))
          (execute-kbd-macro (kbd "<right>"))
          (should (= (point) (1+ start)))
          (execute-kbd-macro (kbd "<left> <down>"))
          (should (> (point) start))
          (execute-kbd-macro (kbd "<up>"))
          (should (= (point) start)))
        (should (eq (window-buffer (selected-window)) origin))
        (should (transient-active-prefix 'isled-help))
        (execute-kbd-macro (kbd "q"))
        (should-not (transient-active-prefix))))))

(ert-deftest isled-help-splits-only-the-origin-window ()
  (save-window-excursion
    (delete-other-windows)
    (with-temp-buffer
      (switch-to-buffer (current-buffer))
      (isled-mode)
      (setq isled--snapshot (isled-view-test--snapshot))
      (isled--render)
      (let* ((origin (selected-window))
             (neighbor (split-window-right))
             (edges (window-edges neighbor))
             (buffer (window-buffer neighbor)))
        (unwind-protect
            (progn
              (execute-kbd-macro (kbd "?"))
              (should (= (length (window-list)) 3))
              (should (eq (selected-window) origin))
              (should (equal (window-edges neighbor) edges))
              (should (eq (window-buffer neighbor) buffer))
              (execute-kbd-macro (kbd "q"))
              (should (= (length (window-list)) 2)))
          (when (transient-active-prefix)
            (execute-kbd-macro (kbd "q"))))))))

(ert-deftest isled-tab-return-and-collapse-all-navigation ()
  (dolist (help '(nil t))
    (save-window-excursion
      (with-temp-buffer
        (switch-to-buffer (current-buffer))
        (isled-mode)
        (setq isled--snapshot
              (isled-view-test--open-snapshot "0001" "0002")
              isled--selected-id "0001")
        (isled--render)
        (unwind-protect
            (progn
              (when help (execute-kbd-macro (kbd "?")))
              (execute-kbd-macro (kbd "RET TAB"))
              (should (equal (isled-sections-id-at-point) "0002"))
              (execute-kbd-macro (kbd "RET"))
              (should (equal (isled-sections-expanded-ids)
                             '("0001" "0002")))
              (execute-kbd-macro (kbd "<backtab>"))
              (should (equal (isled-sections-id-at-point) "0001"))
              (execute-kbd-macro (kbd "C-<return>"))
              (should-not (isled-sections-expanded-ids))
              (execute-kbd-macro (kbd "C-<return>"))
              (should-not (isled-sections-expanded-ids))
              (should (eq (not (null (transient-active-prefix))) help)))
          (when (transient-active-prefix)
            (execute-kbd-macro (kbd "q"))))))))

(ert-deftest isled-collapse-remembers-only-the-last-issue ()
  (with-temp-buffer
    (isled-mode)
    (setq isled--snapshot
          (isled-view-test--open-snapshot "0001" "0002")
          isled--selected-id "0001"
          isled--expanded-ids '("0001" "0002"))
    (isled--render)
    (search-forward "Body 0001.")
    (let ((saved (isled-sections-point-state)))
      (isled-activate)
      (should (= (cdr (isled-sections-point-state)) 0))
      (isled-activate)
      (should (equal (isled-sections-point-state) saved))
      (isled-activate)
      (isled-sections-goto-id "0002")
      (search-forward "Body 0002.")
      (isled-activate)
      (isled-sections-goto-id "0001")
      (isled-activate)
      (should (= (cdr (isled-sections-point-state)) 0)))))

(ert-deftest isled-collapse-memory-is-filter-local ()
  (with-temp-buffer
    (isled-mode)
    (setq isled--snapshot (isled-view-test--snapshot)
          isled--selected-id "0001")
    (isled--render)
    (isled-activate)
    (goto-char (+ (isled-row-content (isled-row-at)) 5))
    (let ((open-point (isled-sections-point-state)))
      (isled-activate)
      (isled-filter-closed)
      (isled-activate)
      (goto-char (+ (isled-row-content (isled-row-at)) 5))
      (isled-activate)
      (isled-collapse-all)
      (isled-activate)
      (should (= (cdr (isled-sections-point-state)) 0))
      (isled-filter-open)
      (isled-activate)
      (should (equal (isled-sections-point-state) open-point)))))

(ert-deftest isled-collapse-position-survives-refresh-and-clamps ()
  (with-temp-buffer
    (isled-mode)
    (setq isled--snapshot
          (isled-view-test--open-snapshot "0001")
          isled--selected-id "0001"
          isled--expanded-ids '("0001"))
    (setf (isled-issue-content
           (car (isled-snapshot-issues isled--snapshot)))
          (concat "# Long body\n\n" (make-string 200 ?x) "\n"))
    (isled--render)
    (goto-char (- (isled-row-end (isled-row-at)) 3))
    (isled-activate)
    (let ((state (isled--capture-view-state)))
      (setq isled--snapshot
            (isled-view-test--open-snapshot "0001"))
      (isled--restore-view-state state))
    (isled-activate)
    (should (equal (isled-sections-id-at-point) "0001"))
    (should (= (point) (1- (isled-row-end (isled-row-at)))))))

(ert-deftest isled-control-tab-skips-expanded-links ()
  (dolist (help '(nil t))
    (save-window-excursion
      (with-temp-buffer
        (switch-to-buffer (current-buffer))
        (isled-mode)
        (setq isled--snapshot
              (isled-view-test--open-snapshot "0001" "0002")
              isled--selected-id "0001"
              isled--expanded-ids '("0001" "0002"))
        (isled--render)
        (search-forward "Body 0001.")
        (let ((link (1- (point))) (inhibit-read-only t))
          (put-text-property link (1+ link) 'isled-target 'markdown-link)
          (isled-sections-goto-id "0001")
          (unwind-protect
              (progn
                (when help (execute-kbd-macro (kbd "?")))
                (execute-kbd-macro (kbd "TAB"))
                (should (= (point) link))
                (execute-kbd-macro (kbd "C-<tab>"))
                (should (equal (isled-sections-id-at-point) "0002"))
                (search-forward "Body 0002.")
                (execute-kbd-macro (kbd "C-S-<tab>"))
                (should (equal (isled-sections-point-state) '("0001" . 0)))
                (execute-kbd-macro (kbd "C-<backtab>"))
                (should (equal (isled-sections-point-state) '("0001" . 0)))
                (execute-kbd-macro (kbd "C-<tab> C-<tab>"))
                (should (equal (isled-sections-point-state) '("0002" . 0)))
                (execute-kbd-macro (kbd "C-S-<iso-lefttab>"))
                (should (equal (isled-sections-point-state) '("0001" . 0))))
            (when (transient-active-prefix)
              (execute-kbd-macro (kbd "q")))))))))

(ert-deftest isled-help-refuses-unsplittable-windows ()
  (with-temp-buffer
    (isled-mode)
    (cl-letf (((symbol-function 'split-window)
               (lambda (&rest _) (error "Too small"))))
      (should-error (isled-help) :type 'user-error)
      (should-not (transient-active-prefix)))))

(ert-deftest isled-help-dismissal-preserves-the-view ()
  (save-window-excursion
    (with-temp-buffer
      (switch-to-buffer (current-buffer))
      (isled-mode)
      (setq isled--snapshot (isled-view-test--snapshot))
      (isled--render)
      (let ((origin (current-buffer)))
        (execute-kbd-macro (kbd "? q"))
        (should (eq (current-buffer) origin))
        (should (eq isled--filter 'open))
        (should-not (transient-active-prefix))))))

(ert-deftest isled-filter-first-visit-starts-collapsed ()
  (with-temp-buffer
    (isled-mode)
    (setq isled--root "/tmp/example"
          isled--snapshot
          (isled-view-test--snapshot)
          isled--filter 'open
          isled--selected-id "0001"
          isled--expanded-ids nil)
    (isled--render)
    (should-not (isled-sections-expanded-ids))
    (should-not (string-match-p "Body\\." (buffer-string)))
    (isled-filter-closed)
    (should-not (isled-sections-expanded-ids))
    (should-not (string-match-p "Done\\." (buffer-string)))))

(ert-deftest isled-filters-restore-independent-view-state ()
  (with-temp-buffer
    (isled-mode)
    (setq isled--root "/tmp/example"
          isled--snapshot
          (isled-view-test--snapshot)
          isled--filter 'open
          isled--selected-id "0001"
          isled--expanded-ids '("0001"))
    (isled--render)
    (search-forward "Body.")
    (backward-char 2)
    (let ((open-point (isled-sections-point-state)))
      (isled-filter-closed)
      (should-not (isled-sections-expanded-ids))
      (isled-sections-show (isled-row-at))
      (search-forward "Done.")
      (backward-char 2)
      (let ((closed-point (isled-sections-point-state)))
        (cl-letf (((symbol-function 'isled--load-snapshot)
                   (lambda (_directory) isled--snapshot)))
          (isled--revert-buffer))
        (should (equal (isled-sections-point-state) closed-point))
        (isled-filter-open)
        (should (equal (isled-sections-point-state) open-point))
        (should (equal (isled-sections-expanded-ids) '("0001")))
        (isled-filter-closed)
        (should (equal (isled-sections-point-state) closed-point))
        (should (equal (isled-sections-expanded-ids) '("0002")))))))

(ert-deftest isled-render-preserves-expanded-issues ()
  (with-temp-buffer
    (isled-mode)
    (setq isled--snapshot
          (isled-view-test--snapshot)
          isled--filter 'open
          isled--selected-id "0001"
          isled--expanded-ids '("0001"))
    (isled--render)
    (should-not (buffer-modified-p))
    (should (string-match-p "Body\\." (buffer-string)))
    (isled-sections-hide (isled-row-at))
    (isled--remember-expanded-ids)
    (isled--render)
    (save-excursion
      (search-forward "Body.")
      (should (invisible-p (1- (point)))))
    (isled-sections-show (isled-row-at))
    (run-hooks 'post-command-hook)
    (should-not (buffer-modified-p))
    (isled--remember-expanded-ids)
    (isled--render)
    (should (string-match-p "Body\\." (buffer-string)))))

(ert-deftest isled-auto-revert-preserves-point-and-view-state ()
  (with-temp-buffer
    (isled-mode)
    (setq isled--root "/tmp/example"
          isled--snapshot (isled-view-test--snapshot)
          isled--filter 'open
          isled--selected-id "0001"
          isled--expanded-ids '("0001"))
    (isled--render)
    (search-forward "Body.")
    (backward-char 2)
    (let ((point-state (isled-sections-point-state)))
      (cl-letf (((symbol-function 'isled--load-snapshot)
                 (lambda (_directory)
                   (isled-view-test--snapshot))))
        (isled--revert-buffer))
      (should (equal (isled-sections-point-state) point-state))
      (should (equal (isled-sections-expanded-ids) '("0001")))
      (should (eq isled--filter 'open))
      (should (equal isled--selected-id "0001"))
      (should-not isled--auto-revert-error)
      (should-not (buffer-modified-p)))))

(ert-deftest isled-refresh-replaces-a-vanished-point-with-its-successor ()
  (with-temp-buffer
    (isled-mode)
    (setq isled--root "/tmp/example"
          isled--snapshot
          (isled-view-test--open-snapshot "0001" "0003" "0005")
          isled--filter 'open
          isled--selected-id "0003"
          isled--expanded-ids '("0003"))
    (isled--render)
    (search-forward "Body 0003.")
    (backward-char 2)
    (cl-letf (((symbol-function 'isled--load-snapshot)
               (lambda (_directory)
                 (isled-view-test--open-snapshot "0001" "0005"))))
      (isled--revert-buffer))
    (should (equal (isled-sections-point-state) '("0005" . 0)))
    (should (equal isled--selected-id "0005"))
    (should-not (isled-sections-expanded-ids))))

(ert-deftest isled-auto-revert-failure-keeps-the-last-good-view ()
  (with-temp-buffer
    (isled-mode)
    (setq isled--root "/tmp/example"
          isled--snapshot (isled-view-test--snapshot)
          isled--filter 'open
          isled--selected-id "0001"
          isled--expanded-ids '("0001"))
    (isled--render)
    (let ((snapshot isled--snapshot)
          (contents (buffer-string)))
      (cl-letf (((symbol-function 'isled--load-snapshot)
                 (lambda (_directory)
                   (signal 'isled-snapshot-error '("temporary")))))
        (isled--revert-buffer))
      (should (eq isled--snapshot snapshot))
      (should (equal (buffer-string) contents))
      (should (string-match-p "temporary"
                              isled--auto-revert-error))
      (should (string-match-p "Auto-refresh failed"
                              (isled--header-line)))
      (cl-letf (((symbol-function 'isled--load-snapshot)
                 (lambda (_directory) snapshot)))
        (isled--revert-buffer))
      (should-not isled--auto-revert-error)
      (should-not (string-match-p
                   "Auto-refresh failed"
                   (isled--header-line))))))

(ert-deftest isled-open-uses-the-issue-at-point ()
  (with-temp-buffer
    (isled-mode)
    (setq isled--snapshot
          (isled-view-test--snapshot)
          isled--filter 'closed
          isled--selected-id "0001"
          isled--expanded-ids '("0002"))
    (isled--render)
    (isled-sections-goto-id "0002")
    (let (opened)
      (cl-letf (((symbol-function 'find-file-read-only)
                 (lambda (path)
                   (setq opened path))))
        (isled-open))
      (should (equal opened
                     "/tmp/example/.issues/0002-second-issue.md")))))

(ert-deftest isled-activate-reference-selects-its-filter-and-target ()
  (with-temp-buffer
    (isled-mode)
    (setq isled--snapshot (isled-view-test--snapshot)
          isled--filter 'open
          isled--selected-id "0001"
          isled--expanded-ids '("0001"))
    (isled--render)
    (search-forward "#0002")
    (backward-char 1)
    (let ((source-point (isled-sections-point-state)))
      (isled-activate)
      (should (eq isled--filter 'closed))
      (should (equal isled--selected-id "0002"))
      (should (equal (isled-sections-id-at-point) "0002"))
      (should (equal (isled-sections-expanded-ids) '("0002")))
      (should (string-match-p "Done\\." (buffer-string)))
      (isled-filter-open)
      (should (equal (isled-sections-point-state) source-point))
      (should (equal (isled-sections-expanded-ids) '("0001"))))))

(ert-deftest isled-warning-links-use-issue-history ()
  (with-temp-buffer
    (isled-mode)
    (setq isled--root "/tmp/example"
          isled--snapshot (isled-view-test--snapshot)
          isled--filter 'open
          isled--selected-id "0001"
          isled--expanded-ids '("0001"))
    (setf (isled-issue-warnings
           (car (isled-snapshot-issues isled--snapshot)))
          (list (isled-warning-create
                 :code "RELATION_TITLE" :message "Stale copied title."
                 :related-ids '("0002"))))
    (isled--render)
    (search-forward "Warnings")
    (search-forward "#0002")
    (backward-char 1)
    (let ((origin (isled-sections-point-state)))
      (isled-activate)
      (should (equal isled--selected-id "0002"))
      (should (member "0002" (isled-sections-expanded-ids)))
      (isled-history-back)
      (should (equal origin (isled-sections-point-state))))))

(ert-deftest isled-reference-history-restores-semantic-views ()
  (with-temp-buffer
    (isled-mode)
    (setq isled--root "/tmp/example"
          isled--snapshot (isled-view-test--snapshot)
          isled--filter 'open
          isled--selected-id "0001"
          isled--expanded-ids '("0001"))
    (isled--render)
    (search-forward "#0002")
    (backward-char 1)
    (let ((source-point (isled-sections-point-state)))
      (isled-jump-to-reference)
      (should (eq isled--filter 'closed))
      (should (equal isled--selected-id "0002"))
      (should (equal (isled-sections-expanded-ids) '("0002")))
      (should (= (length isled--back-history) 1))
      (should-not isled--forward-history)
      (isled-history-back)
      (should (eq isled--filter 'open))
      (should (equal (isled-sections-point-state) source-point))
      (should (equal (isled-sections-expanded-ids) '("0001")))
      (should-not isled--back-history)
      (should (= (length isled--forward-history) 1))
      (isled-history-forward)
      (should (eq isled--filter 'closed))
      (should (equal isled--selected-id "0002"))
      (should (equal (isled-sections-expanded-ids) '("0002")))
      (should (= (length isled--back-history) 1))
      (should-not isled--forward-history))))

(ert-deftest isled-reference-jump-clears-forward-history ()
  (with-temp-buffer
    (isled-mode)
    (setq isled--root "/tmp/example"
          isled--snapshot (isled-view-test--snapshot)
          isled--filter 'open
          isled--selected-id "0001"
          isled--expanded-ids '("0001"))
    (isled--render)
    (search-forward "#0002")
    (backward-char 1)
    (isled-jump-to-reference)
    (isled-history-back)
    (should isled--forward-history)
    (isled-jump-to-reference)
    (should-not isled--forward-history)
    (should (= (length isled--back-history) 1))))

(ert-deftest isled-history-delegates-vanished-state-restoration ()
  (with-temp-buffer
    (isled-mode)
    (setq isled--root "/tmp/example"
          isled--snapshot
          (isled-view-test--open-snapshot "0001" "0005")
          isled--filter 'open
          isled--selected-id "0001"
          isled--expanded-ids nil
          isled--back-history
          (list
           (isled--view-state-create
            :filter 'open
            :selected-id "0003"
            :expanded-ids '("0003")
            :point-state '("0003" . 4))))
    (isled--render)
    (isled-history-back)
    (should (equal isled--selected-id "0005"))
    (should (equal (isled-sections-point-state) '("0005" . 0)))
    (should-not (isled-sections-expanded-ids))
    (should-not isled--back-history)
    (should (= (length isled--forward-history) 1))))

(ert-deftest isled-reference-history-reports-unavailable-actions ()
  (with-temp-buffer
    (isled-mode)
    (setq isled--snapshot (isled-view-test--snapshot)
          isled--filter 'open
          isled--selected-id "0001"
          isled--expanded-ids nil)
    (isled--render)
    (should-error (isled-jump-to-reference) :type 'user-error)
    (should-error (isled-history-back) :type 'user-error)
    (should-error (isled-history-forward) :type 'user-error)))

(ert-deftest isled-activate-reference-expands-in-current-filter ()
  (with-temp-buffer
    (isled-mode)
    (setq isled--snapshot (isled-view-test--snapshot)
          isled--filter 'open
          isled--selected-id "0001"
          isled--expanded-ids nil)
    (isled--render)
    (let ((reference
           (copy-isled-inline-reference
            (car (isled-issue-references
                  (car (isled-snapshot-issues
                        isled--snapshot)))))))
      (setf (isled-inline-reference-target-id reference) "0001")
      (let ((inhibit-read-only t))
        (put-text-property (point) (1+ (point))
                           'isled-target 'issue-reference)
        (put-text-property (point) (1+ (point))
                           'isled-reference reference))
      (isled-activate))
    (should (eq isled--filter 'open))
    (should (equal isled--selected-id "0001"))
    (should (equal (isled-sections-expanded-ids) '("0001")))
    (should (string-match-p "Body\\." (buffer-string)))))

(ert-deftest isled-activate-markdown-link-uses-record-location ()
  (with-temp-buffer
    (isled-mode)
    (setq isled--snapshot (isled-view-test--snapshot)
          isled--filter 'open
          isled--selected-id "0001"
          isled--expanded-ids '("0001"))
    (isled--render)
    (search-forward "documentation")
    (backward-char 1)
    (let (location)
      (cl-letf (((symbol-function 'markdown-follow-thing-at-point)
                 (lambda (&optional _other-window)
                   (setq location (cons buffer-file-name default-directory)))))
        (isled-activate))
      (should (equal
               location
               '("/tmp/example/.issues/0001-first-issue.md"
                 . "/tmp/example/.issues/"))))))

(ert-deftest isled-missing-reference-is-not-actionable ()
  (with-temp-buffer
    (isled-mode)
    (setq isled--snapshot (isled-view-test--snapshot)
          isled--filter 'open
          isled--selected-id "0001"
          isled--expanded-ids '("0001"))
    (isled--render)
    (search-forward "#9999")
    (backward-char 1)
    (should-error (isled-activate) :type 'user-error)))

(ert-deftest isled-keeps-one-buffer-per-canonical-root ()
  (let ((first (generate-new-buffer " *isled-first*"))
        (second (generate-new-buffer " *isled-second*")))
    (unwind-protect
        (progn
          (with-current-buffer first
            (isled-mode)
            (setq isled--root "/tmp/first"))
          (with-current-buffer second
            (isled-mode)
            (setq isled--root "/tmp/second"))
          (should (eq (isled--buffer-for-root "/tmp/first") first))
          (should (eq (isled--buffer-for-root "/tmp/second") second)))
      (kill-buffer first)
      (kill-buffer second))))

(ert-deftest isled-filter-state-is-buffer-local ()
  (let ((first (generate-new-buffer " *isled-first*"))
        (second (generate-new-buffer " *isled-second*")))
    (unwind-protect
        (progn
          (with-current-buffer first
            (isled-mode)
            (setq isled--filter 'closed))
          (with-current-buffer second
            (isled-mode))
          (should (eq (buffer-local-value 'isled--filter first)
                      'closed))
          (should (eq (buffer-local-value 'isled--filter second)
                      'open)))
      (kill-buffer first)
      (kill-buffer second))))

(ert-deftest isled-command-reuses-only-the-matching-root-buffer ()
  (let ((isled-snapshot-runner-function
         (lambda (directory)
           (isled-command-result-create
            :status 0
            :stderr ""
            :stdout
            (json-serialize
             `((schema_version . 5)
               (root . ((encoding . "utf-8") (value . ,directory)))
               (issues . []))))))
        first second first-again)
    (unwind-protect
        (save-window-excursion
          (setq first (isled-buffers-open "/tmp/first" "/tmp/first" nil nil)
                second (isled-buffers-open "/tmp/second" "/tmp/second" nil nil)
                first-again (isled-buffers-open "/tmp/first" "/tmp/first" nil nil))
          (should-not (eq first second))
          (should (eq first first-again)))
      (when (buffer-live-p first) (kill-buffer first))
      (when (buffer-live-p second) (kill-buffer second)))))

(ert-deftest isled-warning-actions-dispatch-and-refresh ()
  (dolist (action '(complete remove))
    (with-temp-buffer
      (insert (propertize "Action" 'isled-warning-action
                          (list action "0001" "0002" t)))
      (goto-char (point-min))
      (let ((isled--root "/tmp/example") called refreshed)
        (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "Needed first"))
                  ((symbol-function 'isled-snapshot--run-process)
                   (lambda (root args)
                     (setq called (cons root args))
                     (isled-command-result-create :status 0 :stderr "")))
                  ((symbol-function 'isled--refresh-after-warning)
                   (lambda () (setq refreshed t))))
          (isled--warning-action))
        (should refreshed)
        (should (equal called
                       (append (list "/tmp/example" "wait" "repair"
                                     (symbol-name action) "0001" "0002")
                               (when (eq action 'complete)
                                 '("--reason" "Needed first")))))))))

(ert-deftest isled-warning-action-failure-keeps-view ()
  (with-temp-buffer
    (insert (propertize "Action" 'isled-warning-action
                        '(remove "0001" "0002")))
    (goto-char (point-min))
    (let (refreshed)
      (cl-letf (((symbol-function 'isled-snapshot--run-process)
                 (lambda (&rest _)
                   (isled-command-result-create
                    :status 1 :stderr "issue store is locked")))
                ((symbol-function 'isled--refresh-after-warning)
                 (lambda () (setq refreshed t))))
        (should-error (isled--warning-action) :type 'user-error))
      (should-not refreshed))))

(ert-deftest isled-warning-trash-requires-confirmation ()
  (with-temp-buffer
    (insert (propertize "Action" 'isled-warning-action
                        '(trash-file "/tmp/example/.issues/0001-broken.md")))
    (goto-char (point-min))
    (let (consent trashed refreshed)
      (cl-letf (((symbol-function 'file-regular-p) (lambda (_) t))
                ((symbol-function 'file-symlink-p) (lambda (_) nil))
                ((symbol-function 'yes-or-no-p) (lambda (_) consent))
                ((symbol-function 'move-file-to-trash)
                 (lambda (file) (setq trashed file)))
                ((symbol-function 'isled--refresh-after-warning)
                 (lambda () (setq refreshed t))))
        (isled--warning-action)
        (should-not trashed)
        (should-not refreshed)
        (setq consent t)
        (isled--warning-action)
        (should (equal trashed "/tmp/example/.issues/0001-broken.md"))
        (should refreshed)))))

(provide 'isled-test)
;;; isled-test.el ends here
