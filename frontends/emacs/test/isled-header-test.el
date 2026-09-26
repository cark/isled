;;; isled-header-test.el --- Header tests  -*- lexical-binding: t; -*-

;;; Commentary:
;; Pure sizing and directory tests plus the buffer/window integration boundary.

;;; Code:

(require 'ert)
(require 'isled-browser)

(ert-deftest isled-header-mode-line-retains-faces-and-literal-percent ()
  (dotimes (_ 3)
    (should
     (equal (isled-header-mode-line
             (concat (propertize "100%project" 'face 'success 'help-echo "/100%project/")
                     (propertize " Help" 'face 'font-lock-doc-face)))
            '("" (:propertize "100%%project" face success help-echo "/100%project/" keymap nil mouse-face nil)
              (:propertize " Help" face font-lock-doc-face help-echo nil keymap nil mouse-face nil))))))

(ert-deftest isled-header-distinguishes-directory-suffixes ()
  (let ((roots '("/home/me/work/app/" "/tmp/work/app/" "/tmp/other/")))
    (should (equal (isled-header-directory (car roots) roots)
                   "me/work/app"))
    (should (equal (isled-header-directory (cadr roots) roots)
                   "tmp/work/app"))
    (should (equal (isled-header-directory "/tmp/other/" roots)
                   "other"))
    (should (equal (isled-header-directory (car roots) (list (car roots)))
                   "app"))
    (should (equal (isled-header-directory "/app/" '("/a/app/"))
                   "/app"))
    (should (equal (isled-header-directory "/" roots) "/"))))

(ert-deftest isled-header-fits-with-help-and-themed-identity ()
  (let* ((directory (propertize "long-parent/project" 'help-echo "/long-parent/project/"))
         (help (isled--fontified-help))
         (wide (isled-header-format directory 'open 12 90 help nil)))
    (should (string-match-p "Isled · /long-parent/project · 12 \\[s:open\\]" wide))
    (should (eq (get-text-property 0 'face wide)
                'isled-header-title-face))
    (let ((start (string-match "long-parent" wide)))
      (should (equal (get-text-property start 'help-echo wide) "/long-parent/project/"))
      (should (eq (get-text-property start 'face wide)
                  'isled-header-directory-face)))
    (dolist (width '(0 1 7 8 12 20 30 50 90))
      (let ((line (isled-header-format directory 'closed 0 width help nil)))
        (should (<= (string-width line) width))
        (when (>= width (string-width help))
          (should (string-suffix-p "[?] Help" line)))))
    (should (<= (string-width (isled-header-format "目录/项目很长" 'all 0 7 help nil)) 7))))

(ert-deftest isled-header-search-shrinks-after-path ()
  (let* ((directory (propertize "parent/project" 'help-echo "/long/path/parent/project"))
         (query "s:open t:rust k:bug timeout")
         (medium (isled-header-format directory query 12 65 "[?]" nil))
         (small (isled-header-format directory query 12 42 "[?]" nil)))
    (should-not (string-match-p "/long/path" medium))
    (should (string-match-p (regexp-quote (concat "[" query "]")) medium))
    (should (string-match-p "\\[s:.*…\\]" small))
    (should (string-match-p "Isled" small))
    (should (string-match-p "12" small))))

(ert-deftest isled-header-keeps-diagnostics-visible ()
  (let* ((warning (propertize "Auto-refresh failed: a long diagnostic" 'face 'error))
         (line (isled-header-format "project" 'open 1 32 "[?] Help" warning)))
    (should (string-prefix-p "Auto-refresh failed:" line))
    (should (eq (get-text-property 0 'face line) 'error))
    (should (equal (get-text-property 0 'help-echo line)
                   (substring-no-properties warning)))
    (should (<= (string-width line) 32))
    (should (string-suffix-p "[?] Help" line))))

(ert-deftest isled-header-uses-rendered-count-and-window-width ()
  (save-window-excursion
    (with-temp-buffer
      (switch-to-buffer (current-buffer))
      (isled-mode)
      (setq isled--root "/tmp/100%project/"
            isled--snapshot (isled-view-test--snapshot))
      (isled--render)
      (should (= isled--header-count 1))
      (isled-filter-closed)
      (should (string-match-p "1 \\[s:closed · prerequisites first\\]" (isled--header-line)))
      (let ((wide (selected-window))
            (narrow (split-window-right 50)))
        (set-window-buffer narrow (current-buffer))
        (dolist (window (list wide narrow))
          (with-selected-window window
            (let ((line (isled--header-line)))
              (should (= (string-width line) (window-body-width)))
              (should (string-match-p "100%project" line)))))))))

(provide 'isled-header-test)
;;; isled-header-test.el ends here
