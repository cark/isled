;;; isled-presentation.el --- Issue text presentation  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Assisted-by: Codex:GPT-6
;; Keywords: tools

;;; Commentary:

;; Style canonical issue text and typed diagnostics without owning list positions
;; or folds.  Markdown mode supplies presentation, never issue semantics.

;;; Code:

(require 'markdown-mode)
(require 'isled-snapshot)
(require 'isled-view)
(require 'seq)
(declare-function isled-activate-mouse "isled-browser")

(defface isled-header-filter-face
  '((t :inherit font-lock-constant-face))
  "Face used for the active issue filter."
  :group 'isled)

(defface isled-header-title-face
  '((t :inherit font-lock-keyword-face))
  "Face used for the product name in the issue-view header."
  :group 'isled)

(defface isled-header-directory-face
  '((t :inherit font-lock-function-name-face))
  "Face used for the project directory in the issue-view header."
  :group 'isled)

(defface isled-header-count-face
  '((t :inherit shadow))
  "Face used for the visible issue count in the issue-view header."
  :group 'isled)

(defface isled-warning-face
  '((t :inherit warning))
  "Face used for warnings and degraded-state messages."
  :group 'isled)

(defface isled-error-face
  '((t :inherit error))
  "Face used for errors in the issue-view header."
  :group 'isled)

(defface isled-action-face
  '((t :inherit link))
  "Face used for diagnostic action controls."
  :group 'isled)

(defface isled-subdued-face
  '((t :inherit shadow))
  "Face used for empty-state and loading text."
  :group 'isled)

(defface isled-target-highlight-face
  '((t :inherit highlight))
  "Face used while the pointer is over an actionable target."
  :group 'isled)

(defface isled-issue-id-face
  '((t :weight bold))
  "Base face used for an issue identifier in a section heading."
  :group 'isled)

(defface isled-ready-issue-id-face
  '((t :inherit (success isled-issue-id-face) :underline nil))
  "Face used for a ready issue identifier in a section heading."
  :group 'isled)

(defface isled-waiting-issue-id-face
  '((t :inherit (link isled-issue-id-face) :underline nil))
  "Face used for a waiting issue identifier in a section heading."
  :group 'isled)

(defface isled-closed-issue-id-face
  '((t :inherit (shadow isled-issue-id-face)
       :underline nil :strike-through t))
  "Face used for a closed issue identifier in a section heading."
  :group 'isled)

(defface isled-issue-title-face
  '((t :inherit font-lock-function-name-face :weight bold))
  "Face used for an issue title in a section heading."
  :group 'isled)

(defface isled-issue-kind-face
  '((t :inherit font-lock-type-face :weight normal :slant normal))
  "Face used for the issue classification between its ID and title."
  :group 'isled)

(defface isled-issue-kind-bracket-face
  '((t :inherit shadow :weight normal :slant normal))
  "Subdued brackets surrounding an issue classification."
  :group 'isled)

(defface isled-issue-work-face
  '((t :inherit default :weight normal :slant normal))
  "Face used for work state and time in an issue heading."
  :group 'isled)

(defface isled-expanded-body-face
  '((t :extend t))
  "Theme-aware background face used for expanded issue content.

Its background follows the active theme's inactive mode line without
inheriting that face's text attributes."
  :group 'isled)

(defvar isled--expanded-body-theme-background nil
  "Last theme-derived background installed for expanded issue bodies.")

(defun isled--face-spec-sets-background-p (spec)
  "Return non-nil if face SPEC has a background attribute."
  (seq-some
   (lambda (entry)
     (and (listp entry)
          (seq-some (lambda (attribute)
                      (eq attribute :background))
                    (cadr entry))))
   spec))

(defun isled--expanded-body-theme-background (&optional _theme)
  "Refresh the expanded-body background after a theme change.

Respect a user or theme face specification that explicitly sets a background,
as well as a direct face customization made after the last refresh."
  (let* ((face 'isled-expanded-body-face)
         (current (face-attribute face :background nil t))
         (theme-faces (get face 'theme-face))
         (custom-background
          (seq-some
           (lambda (entry)
             (and (listp entry)
                  (isled--face-spec-sets-background-p (cadr entry))))
           theme-faces))
         (theme-background
          (face-attribute 'mode-line-inactive :background nil t)))
    (when (and (not custom-background)
               (or (eq current 'unspecified)
                   (equal current isled--expanded-body-theme-background)))
      (set-face-attribute face nil :background theme-background)
      (setq isled--expanded-body-theme-background theme-background))))

(add-hook 'enable-theme-functions #'isled--expanded-body-theme-background)
(add-hook 'disable-theme-functions #'isled--expanded-body-theme-background)
(isled--expanded-body-theme-background)

(defface isled-ledger-warning-face
  '((t :inherit header-line :extend t :box nil))
  "Theme-aware background for ledger-wide diagnostics, outside issue bodies."
  :group 'isled)

(defface isled-body-bracket-face
  '((t :inherit (shadow default)))
  "Subdued bracket connecting an expanded issue body to its heading."
  :group 'isled)

(defface isled-panel-rule-face
  '((t :inherit (shadow default) :strike-through t :extend nil))
  "Subdued horizontal panel rule stretched to the window edge."
  :group 'isled)

(defface isled-panel-title-face
  '((t :extend nil))
  "Uncolored expanded panel title and padding, retaining semantic text faces."
  :group 'isled)

(defface isled-panel-title-background-face
  '((t :inherit isled-expanded-body-face :extend nil))
  "Optional background for an expanded panel title and its padding."
  :group 'isled)

(defcustom isled-title-background nil
  "Whether expanded titles and their padding have a colored background.

Changes take effect on the next redraw or section toggle."
  :type 'boolean
  :group 'isled)

(defun isled-sections--title-face ()
  "Return the configured face for a panel title and its padding."
  (if isled-title-background
      'isled-panel-title-background-face
    'isled-panel-title-face))

(defface isled-waiting-reference-face
  '((t :inherit link :weight bold :underline t))
  "Face used for a waiting open compact issue reference."
  :group 'isled)

(defface isled-ready-reference-face
  '((t :inherit success :weight bold :underline t))
  "Face used for a ready compact issue reference."
  :group 'isled)

(defface isled-closed-reference-face
  '((t :inherit shadow :weight bold :underline t :strike-through t))
  "Face used for a closed compact issue reference."
  :group 'isled)

(defface isled-missing-target-reference-face
  '((t :inherit error :weight bold :underline nil :strike-through nil))
  "Face used for a compact issue reference whose target is missing."
  :group 'isled)

(defface isled-markdown-link-face
  '((t :inherit markdown-link-face :weight normal :underline t))
  "Face used to keep ordinary Markdown links visibly actionable."
  :group 'isled)

(defvar-keymap isled-target-map
  "<mouse-2>" #'isled-activate-mouse)

(defun isled-sections--insert-ledger-warnings (files)
  "Insert a padded ledger diagnostic area for unavailable FILES, if any."
  (when files
    (insert "\n")
    (let ((start (point))
          content-start
          (prefix (concat (propertize "  " 'face 'default)
                          (propertize "  " 'face 'isled-ledger-warning-face))))
      (insert "\n" (propertize "Ledger warnings\n" 'face 'isled-warning-face))
      (setq content-start (point))
      (dolist (file files)
        (insert (propertize (format "Cannot read #%s: %s\n"
                                    (isled-unavailable-id file)
                                    (isled-unavailable-error file))
                            'isled-warning-id (isled-unavailable-id file)))
        (when (isled-unavailable-path file)
          (isled-sections--action
           "Open file" (list 'open-file (isled-unavailable-path file)))
          (isled-sections--action
           "Move to trash" (list 'trash-file (isled-unavailable-path file))))
        (insert "\n"))
      (insert "\n")
      (add-face-text-property start (point) 'isled-ledger-warning-face t)
      (add-text-properties start (point)
                           (list 'line-prefix prefix 'wrap-prefix prefix))
      (let ((content-prefix
             (concat prefix (propertize "  " 'face 'isled-ledger-warning-face))))
        (add-text-properties content-start (1- (point))
                             (list 'line-prefix content-prefix
                                   'wrap-prefix content-prefix))))
    (insert "\n")))

(defun isled-sections--insert-warnings (issue issue-index &optional unavailable)
  "Insert ISSUE warnings using ISSUE-INDEX and UNAVAILABLE files."
  (when-let ((warnings (isled-issue-warnings issue)))
    (insert (propertize "Warnings\n" 'face 'isled-warning-face
                        'markdown-heading t))
    (cl-loop for warning in warnings for index from 0 do
	     (let ((start (point)))
	       (insert (propertize (concat "- " (isled-warning-message warning))
				   'face 'isled-warning-face
				   'help-echo (isled-warning-code warning)))
	       (dolist (id (isled-warning-related-ids warning))
		 (let* ((target (gethash id issue-index))
			(label (propertize (concat "#" id)
					   'face (isled-sections--reference-face
						  target))))
		   (when target
		     (put-text-property 0 (length label) 'isled-target-id id label)
		     (isled-sections--mark-target
		      label 0 (length label) 'issue-reference))
		   (insert " [" label "]")))
	       (insert "\n")
	       (when (equal (isled-warning-code warning) "RELATION_UNREADABLE")
		 (dolist (file unavailable)
		   (when (member (isled-unavailable-id file)
				 (isled-warning-related-ids warning))
		     (insert "    " (isled-unavailable-error file) "\n")
		     (isled-sections--action
		      "Open file" (list 'open-file (isled-unavailable-path file)))
		     (isled-sections--action
		      "Move to trash" (list 'trash-file (isled-unavailable-path file)))
		     (insert "\n"))))
	       (let ((code (isled-warning-code warning))
		     (source (isled-warning-source-id warning))
		     (target (isled-warning-target-id warning)))
		 (when (and source target)
		   (when (equal code "RELATION_RECIPROCAL")
		     (isled-sections--action "Complete relation"
						      (list 'complete source target (isled-warning-needs-reason warning))))
		   (when (member code '("RELATION_RECIPROCAL" "RELATION_MISSING"))
		     (isled-sections--action "Remove relation" (list 'remove source target)))
		   (when (member code '("RELATION_RECIPROCAL" "RELATION_MISSING")) (insert "\n"))))
	       (put-text-property start (point) 'isled-warning-index index)))
    (insert "\n")))

(defun isled-sections--action (label action)
  "Insert ASCII LABEL for typed ACTION using ordinary target navigation."
  (let ((text (propertize (concat "[" label "]")
                          'face 'isled-action-face)))
    (put-text-property 0 (length text) 'isled-warning-action action text)
    (isled-sections--mark-target text 0 (length text) 'warning-action)
    (insert "    " text)))

(defun isled-sections--body-prefix (&optional plain)
  "Return the expanded body's gutter and padding, without background if PLAIN."
  (concat (propertize "│" 'face 'isled-body-bracket-face)
          (propertize " " 'face 'default)
          (propertize " " 'face (if plain 'default 'isled-expanded-body-face))))

(defun isled-sections--indent-body (start end &optional plain)
  "Indent START to END with headings at the padded edge and PLAIN background."
  (let* ((heading-prefix
          (isled-sections--body-prefix plain))
         (content-prefix
          (concat heading-prefix
                  (propertize "  " 'face (if plain 'default 'isled-expanded-body-face)))))
    (save-excursion
      (goto-char start)
      (while (< (point) end)
        (let* ((line-start (point))
               (line-end (min end (line-beginning-position 2)))
               (prefix
                (if (or (get-text-property line-start 'markdown-heading)
                        (looking-at-p "[ \t]*$"))
                    heading-prefix
                  content-prefix)))
          (add-text-properties line-start line-end
                               (list 'line-prefix prefix 'wrap-prefix prefix))
          (goto-char line-end))))))

(defun isled-sections--present-issue (issue issue-index)
  "Present ISSUE using target state from ISSUE-INDEX."
  (let ((content
         (isled-sections--markdown-view
          (isled-issue-content issue))))
    (dolist (reference (isled-issue-references issue))
      (let* ((start
              (isled-inline-reference-character-start reference))
             (end
              (+ start
                 (isled-inline-reference-character-length reference)))
             (target (and (eq (isled-inline-reference-resolution reference) 'resolved)
                          (gethash (isled-inline-reference-target-id reference)
                                   issue-index)))
             (face (isled-sections--reference-face target)))
        (add-face-text-property start end face nil content)
        (put-text-property start end 'isled-reference reference content)
        (when target
          (isled-sections--mark-target
           content start end 'issue-reference))))
    ;; Rust's record contract fixes the title on the first line.  Hide it,
    ;; including its newline, without deleting bytes or reparsing Markdown.
    ;; The following canonical blank line supplies the top inner padding.
    (let ((end (if-let ((newline (string-match "\n" content)))
                   (1+ newline)
                 (length content))))
      (put-text-property 0 end 'display "" content)
      (put-text-property 0 end 'invisible t content))
    content))

(defun isled-sections--reference-face (target)
  "Return the semantic reference face for TARGET, or nil if missing."
  (if (null target)
      'isled-missing-target-reference-face
    (pcase (isled-sections--issue-state target)
      ('ready 'isled-ready-reference-face)
      ('waiting 'isled-waiting-reference-face)
      ('closed 'isled-closed-reference-face))))

(defun isled-sections--issue-id-face (issue)
  "Return the semantic section-heading ID face for ISSUE."
  (pcase (isled-sections--issue-state issue)
    ('ready 'isled-ready-issue-id-face)
    ('waiting 'isled-waiting-issue-id-face)
    ('closed 'isled-closed-issue-id-face)))

(defun isled-sections--issue-state (issue)
  "Return the semantic presentation state for ISSUE."
  (cond
   ((equal (isled-issue-status issue) "closed") 'closed)
   ((isled-issue-ready issue) 'ready)
   (t 'waiting)))

(defun isled-sections--markdown-view (content)
  "Return CONTENT with Markdown View presentation properties."
  (with-temp-buffer
    (insert content)
    (delay-mode-hooks (markdown-view-mode))
    (font-lock-ensure)
    (isled-sections--copy-presentation
     (point-min) (point-max))))

(defun isled-sections--copy-presentation (start end)
  "Copy text from START to END, retaining presentation properties."
  (let ((text (buffer-substring-no-properties start end))
        (position start))
    (while (< position end)
      (let* ((next (next-property-change position nil end))
             (target-start (- position start))
             (target-end (- next start)))
        (dolist (property '(face font-lock-face display invisible help-echo
                           markdown-heading))
          (when-let ((value (get-text-property position property)))
            ;; Retain heading identity, not temporary-buffer match positions.
            (when (eq property 'markdown-heading)
              (setq value t))
            (when (eq property 'face)
              (when (isled-sections--face-includes-p
                     value 'markdown-link-face)
                (isled-sections--mark-target
                 text target-start target-end 'markdown-link))
              (setq value
                    (isled-sections--replace-face
                     value 'markdown-link-face
                     'isled-markdown-link-face)))
            (put-text-property target-start target-end property value text)))
        (setq position next)))
    text))

(defun isled-sections--mark-target (text start end kind)
  "Mark TEXT from START to END as an actionable target of KIND."
  (put-text-property start end 'isled-target kind text)
  (put-text-property start end 'mouse-face 'isled-target-highlight-face text)
  (put-text-property start end 'keymap isled-target-map text)
  (put-text-property start end 'follow-link t text))

(defun isled-sections--face-includes-p (value face)
  "Return non-nil when face property VALUE includes FACE."
  (if (listp value)
      (seq-some
       (lambda (item)
         (isled-sections--face-includes-p item face))
       value)
    (eq value face)))

(defun isled-sections--replace-face (value old new)
  "Replace OLD with NEW in face property VALUE."
  (cond
   ((eq value old) new)
   ((consp value)
    (mapcar
     (lambda (item)
       (isled-sections--replace-face item old new))
     value))
   (t value)))

(defun isled-sections--body-string (issue targets unavailable rich)
  "Build ISSUE text using TARGETS and UNAVAILABLE, with full styling when RICH."
  (with-temp-buffer
    (insert (propertize "\n" 'invisible t))
    (let ((start (point)))
      (isled-sections--insert-warnings issue targets unavailable)
      (isled-sections--indent-body start (point) t))
    (let ((start (point)))
      (insert (if (isled-issue-content issue)
                  (if rich (isled-sections--present-issue issue targets)
                    (isled-issue-content issue))
                (propertize "Loading issue details…\n"
                            'face 'isled-subdued-face)))
      (unless (bolp) (insert "\n"))
      (insert "\n")
      (when rich
        (add-face-text-property start (point) 'isled-expanded-body-face)
        (isled-sections--indent-body start (point))))
    (insert (propertize "\n" 'line-prefix
                        (propertize "└────" 'face 'isled-body-bracket-face)))
    (buffer-string)))

(provide 'isled-presentation)
;;; isled-presentation.el ends here
