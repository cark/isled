;;; isled-appearance-graphical.el --- Private appearance check -*- lexical-binding: t; -*-

;;; Commentary:
;; Run with scripts/private-graphical-emacs.py, never in a working daemon.

;;; Code:

(require 'use-package)

(defun isled-appearance-check (condition message)
  "Fail with MESSAGE unless CONDITION is non-nil."
  (unless condition (error "%s" message)))

(defun isled-appearance-check-attribute (face attribute expected)
  "Require FACE ATTRIBUTE to equal EXPECTED on the selected frame."
  (isled-appearance-check
   (equal (face-attribute face attribute (selected-frame) t) expected)
   (format "%s %s did not equal %S" face attribute expected)))

(defun isled-appearance-check-rendering ()
  "Require fresh production rendering to retain the customizable body face."
  (let* ((issue (isled-issue-create
                 :id "0001" :status "open" :ready t :kind "feature"
                 :title "Appearance" :references nil :warnings nil
                 :content "# 0001 — Appearance\n\nBody with **emphasis**.\n"))
         (body (isled-sections--body-string
                issue (make-hash-table :test #'equal) nil t))
         (position (string-match "Body" body)))
    (isled-appearance-check position "Body was not rendered")
    (let ((face (get-text-property position 'face body)))
      (isled-appearance-check
       (if (listp face) (memq 'isled-expanded-body-face face)
         (eq face 'isled-expanded-body-face))
       "Rendered body did not retain its named base face"))))

;; This is the form written by Customize, deliberately evaluated before the
;; package defines the face.
(custom-set-faces
 '(isled-expanded-body-face
   ((t (:background "#20242b" :foreground "#e6e6e6"
        :family "Monospace" :height 1.1 :weight medium)))))

(require 'isled-browser)

(dolist (pair '((:background . "#20242b") (:foreground . "#e6e6e6")
                (:family . "Monospace") (:height . 1.1) (:weight . medium)))
  (isled-appearance-check-attribute
   'isled-expanded-body-face (car pair) (cdr pair)))
(isled-appearance-check-rendering)

;; This is the documented use-package form.
(use-package isled
  :ensure nil
  :custom-face
  (isled-issue-title-face
   ((t (:foreground "#5fafff" :family "Monospace"
        :height 1.15 :weight semi-bold))))
  (isled-ready-issue-id-face
   ((t (:foreground "#5faf5f" :weight bold)))))

(dolist (pair '((:foreground . "#5fafff") (:family . "Monospace")
                (:height . 1.15) (:weight . semi-bold)))
  (isled-appearance-check-attribute
   'isled-issue-title-face (car pair) (cdr pair)))

;; Face symbols retained in rendered strings keep custom attributes authoritative
;; through redraws without rewriting text properties.
(let ((header (isled-header-format
               (propertize "project" 'help-echo "/tmp/project")
               "s:open" 2 80 (isled--fontified-help) nil)))
  (isled-appearance-check
   (memq (get-text-property (string-match "project" header) 'face header)
         '(isled-header-title-face isled-header-directory-face))
   "Header did not retain a named face")
  (isled-appearance-check
   (eq (get-text-property (string-match "s:open" header) 'face header)
       'isled-header-filter-face)
   "Filter did not retain its named face"))

(let ((body (propertize "Markdown" 'face 'markdown-bold-face)))
  (add-face-text-property 0 (length body) 'isled-expanded-body-face nil body)
  (isled-appearance-check
   (equal (get-text-property 0 'face body)
          '(isled-expanded-body-face markdown-bold-face))
   "Expanded-body customization did not precede Markdown styling"))

;; Reloading the package must not replace either pre-load Customize settings or
;; use-package settings.
(load (locate-library "isled-presentation") nil t)
(isled-appearance-check-attribute
 'isled-expanded-body-face :background "#20242b")
(isled-appearance-check-attribute
 'isled-issue-title-face :weight 'semi-bold)
(isled-appearance-check-rendering)

;; Remove the explicit body customization and verify stock light and dark theme
;; fallback, including the disable-theme hook.
(custom-set-faces
 '(isled-expanded-body-face ((t (:extend t)))))
(setq isled--expanded-body-theme-background nil)
(dolist (theme '(modus-operandi modus-vivendi))
  (mapc #'disable-theme custom-enabled-themes)
  (load-theme theme t)
  (isled--expanded-body-theme-background)
  (isled-appearance-check
   (equal (face-attribute 'isled-expanded-body-face :background nil t)
          (face-attribute 'mode-line-inactive :background nil t))
   (format "Body background did not follow %s" theme)))
(mapc #'disable-theme custom-enabled-themes)
(isled-appearance-check
 (equal (face-attribute 'isled-expanded-body-face :background nil t)
        (face-attribute 'mode-line-inactive :background nil t))
 "Body background did not refresh after disabling the theme")

;; Conventional themes may set package faces directly and remain authoritative.
(deftheme isled-appearance-check-theme)
(custom-theme-set-faces
 'isled-appearance-check-theme
 '(isled-warning-face ((t (:foreground "#ff5f5f" :weight bold))))
 '(isled-expanded-body-face ((t (:background "#303030")))))
(provide-theme 'isled-appearance-check-theme)
(enable-theme 'isled-appearance-check-theme)
(isled-appearance-check-attribute
 'isled-warning-face :foreground "#ff5f5f")
(isled-appearance-check-attribute
 'isled-expanded-body-face :background "#303030")

(with-temp-file (getenv "PI_RESULT")
  (prin1 '(:success t :passed t) (current-buffer)))
(kill-emacs 0)

;;; isled-appearance-graphical.el ends here
