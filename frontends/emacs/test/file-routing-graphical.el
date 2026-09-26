;;; file-routing-graphical.el --- Private file-open acceptance -*- lexical-binding: t; -*-

;;; Commentary:
;; Run via scripts/private-graphical-emacs.py with frontend/test and agent-shell
;; Markdown load paths, and PI_PROGRAM naming the unchanged Rust executable.

;;; Code:
(setq load-prefer-newer t)
(require 'isled-file-visit-test)
(require 'markdown-mode)
(require 'org)
(require 'agent-shell-markdown)
(defvar agent-shell-file-display-action nil)
(setq isled-test-program (getenv "PI_PROGRAM"))

(ert-deftest isled-file-graphical-real-link-callers ()
  (isled-file-visit-test--with-ledger
    (let* ((path (expand-file-name ".issues/0001-one.md" root))
           (agent-shell-file-display-action '(display-buffer-same-window))
           (agent-shell-markdown-open-file-function
            (lambda (target)
              (when-let ((window (display-buffer (find-file-noselect target)
                                                 '(display-buffer-same-window))))
                (select-window window)))))
      (markdown-mode)
      (erase-buffer)
      (insert (format "[Open issue](%s)\n" path))
      (goto-char 3)
      (call-interactively #'markdown-follow-thing-at-point)
      (isled-file-visit-test--await (lambda () (isled-file-visit-test--ready "0001")))
      (let ((view (current-buffer)))
        (markdown--browse-url (concat path "#statement"))
        (should (equal buffer-file-name path))
        (should-not isled-file-visit--pending)
        (org-open-file path t)
        (isled-file-visit-test--await (lambda () (isled-file-visit-test--ready "0001")))
        (should (eq (current-buffer) view))
        (org-open-file path t 3)
        (should (equal buffer-file-name path))
        (should (= (line-number-at-pos) 3))
        (should-not isled-file-visit--pending)
        (agent-shell-markdown-visit-file :file path)
        (isled-file-visit-test--await (lambda () (isled-file-visit-test--ready "0001")))
        (should (eq (current-buffer) view))
        (agent-shell-markdown-visit-file :file path :line-start 3 :line-end 5 :column 2)
        (should (equal buffer-file-name path))
        (should (= (line-number-at-pos) 3))
        (should (= (current-column) 1))
        (should mark-active)
        (should-not isled-file-visit--pending)))))

(ert-deftest isled-file-graphical-requested-window-and-frame ()
  (isled-file-visit-test--with-ledger
    (let ((original (selected-frame)) (original-window (selected-window)) frame)
      (unwind-protect
          (progn
            (find-file-other-window (expand-file-name ".issues/0001-one.md" root))
            (should (eq (selected-window) original-window))
            (isled-file-visit-test--await (lambda () (isled-file-visit-test--ready "0001")))
            (should-not (eq (selected-window) original-window))
            (should-not (find-buffer-visiting (expand-file-name ".issues/0001-one.md" root)))
            (find-file-other-frame (expand-file-name ".issues/0003-three.md" root))
            (should (eq (selected-frame) original))
            (isled-file-visit-test--await (lambda () (isled-file-visit-test--ready "0003")))
            (setq frame (selected-frame))
            (should-not (eq frame original))
            (should-not (find-buffer-visiting (expand-file-name ".issues/0003-three.md" root))))
        (when (and frame (frame-live-p frame)) (delete-frame frame))
        (select-frame original)))))

(ert-deftest isled-file-graphical-agent-shell-no-display ()
  (isled-file-visit-test--with-ledger
    (let ((agent-shell-file-display-action
           '(display-buffer-no-window (allow-no-window . t)))
          (origin (current-buffer)))
      (agent-shell-markdown-visit-file :file (expand-file-name ".issues/0001-one.md" root))
      (isled-file-visit-test--await (lambda () (not isled-file-visit--pending)))
      (should (eq (current-buffer) origin))
      (should-not (isled--buffer-for-root root))
      (should-not (find-buffer-visiting (expand-file-name ".issues/0001-one.md" root))))))

(condition-case failure
    (let ((stats (ert-run-tests-batch "^isled-file-graphical-")))
      (unless (zerop (ert-stats-completed-unexpected stats)) (error "Graphical routing checks failed"))
      (with-temp-file (getenv "PI_RESULT") (prin1 '(:passed t :scenarios 3) (current-buffer)))
      (kill-emacs 0))
  (error (message "Routing graphical failure: %S" failure) (kill-emacs 1)))

;;; file-routing-graphical.el ends here
