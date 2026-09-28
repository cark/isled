;;; isled-installation-view-test.el --- Installation notice tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Keep first-use paths visible while the invoking command opens its ledger.

;;; Code:
(require 'ert)
(require 'isled-installation-view)

(ert-deftest isled-installation-notice-survives-ledger-display-until-dismissed ()
  (let ((display-buffer-alist nil)
        (display-buffer-base-action nil)
        (split-height-threshold 0)
        (split-width-threshold nil)
        (project (generate-new-buffer " installation-project"))
        (ledger (generate-new-buffer " installation-ledger")))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (switch-to-buffer project)
          (isled-installation-display
           '((version . "0.33.0") (executable . "/tmp/isled/current/isled")
             (skill . "/tmp/isled/current/skill")
             (skill_file . "/tmp/isled/current/skill/SKILL.md")
             (path_directory . "/tmp/isled/current")))
          (should (eq project (window-buffer (selected-window))))
          ;; A small frame cannot split again when first use opens the ledger.
          (let ((split-height-threshold nil)) (pop-to-buffer ledger))
          (should (eq ledger (window-buffer (selected-window))))
          (let ((notice (get-buffer-window "*Isled installation*")))
            (should (window-live-p notice))
            (with-selected-window notice
              (call-interactively (key-binding (kbd "q")))))
          (should-not (get-buffer-window "*Isled installation*"))
          (should (get-buffer-window ledger)))
      (dolist (buffer (list project ledger (get-buffer "*Isled installation*")))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest isled-installation-folder-button-opens-current-without-hiding-notice ()
  (let* ((root (make-temp-file "isled-installation-view-" t))
         (current (expand-file-name "current" root))
         (display-buffer-alist nil)
         (display-buffer-base-action nil)
         (project (generate-new-buffer " installation-project"))
         directory-buffer)
    (unwind-protect
        (save-window-excursion
          (make-directory current)
          (delete-other-windows)
          (switch-to-buffer project)
          (isled-installation-display
           `((version . "0.33.0") (path_directory . ,current)
             (executable . ,(expand-file-name "isled" current))
             (skill . ,(expand-file-name "skill" current))
             (skill_file . ,(expand-file-name "skill/SKILL.md" current))))
          (with-selected-window (get-buffer-window "*Isled installation*")
            (goto-char (point-min))
            (should (search-forward "M-x isled-show-installation" nil t))
            (button-activate (next-button (point)))
            (setq directory-buffer (window-buffer (selected-window))))
          (with-current-buffer directory-buffer
            (should (derived-mode-p 'dired-mode))
            (should (equal default-directory (file-name-as-directory current))))
          (should (get-buffer-window "*Isled installation*")))
      (dolist (buffer (list project directory-buffer (get-buffer "*Isled installation*")))
        (when (buffer-live-p buffer) (kill-buffer buffer)))
      (delete-directory root t))))

(provide 'isled-installation-view-test)
;;; isled-installation-view-test.el ends here
