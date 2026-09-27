;;; isled-sections.el --- Expandable project issue sections  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT

;; Author: Sacha De Vos
;; Assisted-by: Codex:GPT-6
;; Keywords: tools

;;; Commentary:

;; Indexed text presentation for validated project issue snapshots.  Issue
;; content is opaque to the frontend: Markdown View mode contributes display
;; properties in an isolated temporary buffer, but never supplies issue
;; semantics.

;;; Code:

(require 'isled-rows)
(require 'isled-fold)
(require 'isled-presentation)
(require 'isled-snapshot)
(require 'isled-view)
(require 'isled-graph-gutter)
(require 'seq)

(declare-function isled-activate-mouse "isled-browser")

(defvar-local isled-sections--targets nil "Target metadata for body presentation.")
(defvar-local isled-sections--unavailable nil "Ledger diagnostics for bodies.")
(declare-function isled-loading-schedule "isled-loading")

(defconst isled-sections--heading-font-base
  (list :font (font-spec))
  "Sparse font specification used below semantic heading faces.
Avoid copying a named default font specification on every weight merge.
Keep font selection frame-local and semantic faces theme-aware.")

(defun isled-sections--heading-text (text face)
  "Return heading TEXT styled with semantic FACE above a sparse font base."
  (propertize text 'face (list face isled-sections--heading-font-base)))

(defun isled-sections--heading (issue)
  "Return the complete semantic heading for ISSUE."
  (concat (isled-sections--heading-text
           (concat "#" (isled-issue-id issue))
           (isled-sections--issue-id-face issue))
          "  " (isled-sections--heading-text
                 "[" 'isled-issue-kind-bracket-face)
          (isled-sections--heading-text
           (isled-issue-kind issue) 'isled-issue-kind-face)
          (isled-sections--heading-text
           "]" 'isled-issue-kind-bracket-face)
          " " (isled-sections--heading-text
                (isled-issue-title issue) 'isled-issue-title-face)
          "\n"))

(defvar-local isled-sections--filter nil "Filter of the rendered row sequence.")
(defvar-local isled-sections--body-keys nil "Presentation inputs for retained bodies.")
(defvar-local isled-sections--graph-key nil "Graph token of the rendered row sequence.")

(defun isled-sections-render (snapshot filter expanded-ids)
  "Synchronize SNAPSHOT and FILTER, preserving unaffected rows and EXPANDED-IDS."
  (let ((issues (isled-view-visible-issues snapshot filter
                                          (and isled-graph-direction isled-graph-layout)))
        (graph-key (and isled-graph-direction isled-graph-hash)))
    (if (and (equal filter isled-sections--filter)
             (equal graph-key isled-sections--graph-key)
             (equal (mapcar #'isled-issue-id issues)
                    (cl-loop for row across isled-rows collect (isled-row-value row)))
             (equal isled-sections--unavailable (isled-snapshot-unavailable snapshot)))
        (isled-sections--update issues snapshot expanded-ids)
      (setq isled-sections--graph-key graph-key
            isled-graph-gutter--painted nil)
      (erase-buffer)
      (isled-sections-insert snapshot filter expanded-ids))))

(defun isled-sections--body-key (issue targets unavailable)
  "Describe ISSUE presentation inputs using TARGETS and relevant UNAVAILABLE files."
  (list (isled-issue-content issue)
        (isled-issue-references issue) (isled-issue-warnings issue)
        (and (isled-issue-warnings issue) unavailable)
        (mapcar (lambda (reference)
                  (let ((target (gethash (isled-inline-reference-target-id reference) targets)))
                    (and target (isled-sections--issue-state target))))
                (isled-issue-references issue))
        (mapcar (lambda (warning)
                  (mapcar (lambda (id)
                            (let ((target (gethash id targets)))
                              (and target (isled-sections--issue-state target))))
                          (isled-warning-related-ids warning)))
                (isled-issue-warnings issue))))

(defun isled-sections--update (issues snapshot expanded-ids)
  "Update matching row identities from ISSUES and SNAPSHOT, restoring EXPANDED-IDS."
  (let ((expanded (make-hash-table :test #'equal)))
    (dolist (id expanded-ids) (puthash id t expanded))
    (setq isled-sections--targets
          (or (isled-snapshot-targets snapshot)
              (isled-view-index-issues (isled-snapshot-issues snapshot)))
          isled-sections--unavailable (isled-snapshot-unavailable snapshot))
    (dolist (issue issues)
      (isled-sections--update-row
       (gethash (isled-issue-id issue) isled-rows-index) issue expanded))))

(defun isled-sections--update-row (row issue expanded)
  "Update ROW from ISSUE and desired EXPANDED membership."
  (let* ((hidden (not (gethash (isled-issue-id issue) expanded)))
         (changed (not (isled-rows-heading-matches-p row issue)))
         (style-changed (or changed (not (eq hidden (isled-row-hidden row))))))
    (setf (isled-row-issue row) issue (isled-row-hidden row) hidden)
    (when changed (isled-rows-write-heading row (isled-sections--heading issue)))
    (when (or (isled-row-materialized row) (not hidden))
      (let ((key (isled-sections--body-key
                  issue isled-sections--targets isled-sections--unavailable)))
        (unless (and (isled-row-materialized row)
                     (equal key (gethash (isled-row-value row) isled-sections--body-keys)))
          (setf (isled-row-materialized row) nil)
          (isled-sections--materialize row)
          (setq style-changed t))))
    (when style-changed (isled-sections--sync-visibility-style row))
    (isled-fold-update row)))

(defun isled-sections-insert (snapshot filter expanded-ids)
  "Insert SNAPSHOT using FILTER and logical EXPANDED-IDS."
  (setq isled-sections--filter filter
        isled-sections--body-keys (make-hash-table :test #'equal))
  (let ((issues (isled-view-visible-issues snapshot filter
                                          (and isled-graph-direction isled-graph-layout)))
        (materialized (make-hash-table :test #'equal))
        (expanded (make-hash-table :test #'equal)))
    (seq-doseq (row isled-rows)
      (when (isled-row-materialized row)
        (puthash (isled-row-value row) t materialized)))
    (dolist (id expanded-ids) (puthash id t expanded))
    (setq isled-sections--targets
          (or (isled-snapshot-targets snapshot)
              (isled-view-index-issues (isled-snapshot-issues snapshot)))
          isled-sections--unavailable (isled-snapshot-unavailable snapshot))
    (isled-sections--insert-ledger-warnings isled-sections--unavailable)
    (isled-rows-insert issues #'isled-sections--heading #'isled-graph-gutter-routing)
    (seq-doseq (row isled-rows)
      (setf (isled-row-hidden row) (not (gethash (isled-row-value row) expanded)))
      (when (or (not (isled-row-hidden row))
                (gethash (isled-row-value row) materialized))
        (isled-sections--materialize row))
      (isled-sections--sync-visibility-style row))
    (unless issues
      (insert (propertize (cond ((stringp filter) "No matching issues.\n")
                                ((eq filter 'all) "No issues.\n")
                                (t (format "No %s issues.\n" filter)))
                         'face 'isled-subdued-face)))))

(defun isled-sections-expanded-ids ()
  "Return explicitly expanded issue identities, excluding temporary reveals."
  (cl-loop for row across isled-rows
           unless (isled-row-hidden row) collect (isled-row-value row)))

(defun isled-sections-id-at-point (&optional position)
  "Return the issue identifier at POSITION or point."
  (when-let ((row (isled-row-at position))) (isled-row-value row)))

(defun isled-sections-goto-id (id)
  "Move to the issue heading ID, returning non-nil when it exists."
  (when-let ((row (and isled-rows-index (gethash id isled-rows-index))))
    (goto-char (isled-row-start row)) t))

(defun isled-sections-move (direction &optional issues-only)
  "Move to the next actionable position in DIRECTION.

Issue headings and actionable targets inside expanded bodies are stops.
With ISSUES-ONLY, skip links and move relative to the containing issue heading.
Return the issue identifier at the destination, or nil at a boundary."
  (let* ((positions (isled-sections--navigation-positions issues-only))
         (origin (if (and issues-only (isled-sections-id-at-point))
                     (isled-row-start (isled-row-at))
                   (point)))
         (destination
          (if (> direction 0)
              (seq-find (lambda (position) (> position origin)) positions)
            (car (last
                  (seq-take-while
                   (lambda (position) (< position origin)) positions))))))
    (when destination
      (goto-char destination)
      (isled-sections-id-at-point))))

(defun isled-sections-point-state ()
  "Return issue ID and character offset describing point, or nil."
  (when-let ((section (isled-row-at)))
    (when (isled-row-p section)
      (cons (isled-row-value section)
            (- (point) (isled-row-start section))))))

(defun isled-sections-ledger-point-state ()
  "Return the diagnostic identity and offset at point outside issue rows."
  (when-let ((id (get-text-property (point) 'isled-warning-id)))
    (cons id (- (point) (text-property-any (point-min) (point-max) 'isled-warning-id id)))))

(defun isled-sections-restore-ledger-point (state)
  "Restore the diagnostic identity and offset in STATE when still present."
  (when-let ((start (and state (text-property-any (point-min) (point-max)
                                                'isled-warning-id (car state)))))
    (goto-char (min (+ start (cdr state))
                    (1- (next-single-property-change start 'isled-warning-id nil (point-max)))))
    t))

(defun isled-sections-restore-point-state (state)
  "Restore point from issue-relative STATE and return non-nil on success."
  (when (and state (isled-sections-goto-id (car state)))
    (let* ((section (isled-row-at))
           (start (isled-row-start section))
           (end (isled-row-end section)))
      (goto-char (min (+ start (cdr state)) (max start (1- end)))))
    t))

(defvar isled-sections--defer-rich nil
  "Non-nil while a batch inserts text before the viewport is restored.")

(defun isled-sections--materialize (row)
  "Insert ROW's available body or placeholder without fetching data."
  (unless (isled-row-materialized row)
    (let ((issue (isled-row-issue row))
          (targets isled-sections--targets)
          (unavailable isled-sections--unavailable)
          (rich (not isled-sections--defer-rich)))
      (isled-rows-write-body
       row (isled-sections--body-string issue targets unavailable rich))
      (setf (isled-row-materialized row) t (isled-row-rich row) rich)
      (puthash (isled-row-value row)
               (isled-sections--body-key issue targets unavailable)
               isled-sections--body-keys)))
  (isled-fold-update row))

(defun isled-sections-format (row)
  "Format ROW's retained text without changing expansion state or fetching data."
  (when (and (isled-row-materialized row) (not (isled-row-rich row))
             (isled-issue-content (isled-row-issue row)))
    (with-silent-modifications
      (isled-rows-style-body
       row (isled-sections--body-string
            (isled-row-issue row) isled-sections--targets
            isled-sections--unavailable t))
      (setf (isled-row-rich row) t)
      (isled-sections--sync-visibility-style row))
    t))

(defun isled-sections--sync-visibility-style (section)
  "Match SECTION's boundary indentation and heading face to its visibility.

Call after initial insertion and after showing or hiding an issue.  The public
show/hide wrappers below own that synchronization for frontend commands."
  (if (isled-row-hidden section)
      (remhash section isled-rows-expanded)
    (puthash section t isled-rows-expanded))
  (let ((inhibit-read-only t))
    (add-text-properties
     (isled-row-start section) (isled-row-heading-end section)
     (list 'line-prefix nil 'wrap-prefix
           (unless (isled-row-hidden section)
             (concat (propertize "│  " 'face 'isled-body-bracket-face)
                     (propertize " " 'face 'default)
                     (propertize " " 'face (isled-sections--title-face)))))))
  ;; Clear the rule on collapse so its display prefix cannot leak into the
  ;; following heading through the invisible section body.
  (when-let ((start (isled-row-content section)))
    (when (< start (isled-row-end section))
      (let ((inhibit-read-only t)
            (prefix (unless (isled-row-hidden section)
                      (get-text-property (1+ start) 'line-prefix))))
        (add-text-properties start (1+ start)
                             (list 'line-prefix prefix 'wrap-prefix prefix)))))
  (when-let ((overlay (isled-row-heading-background section)))
    (delete-overlay overlay)
    (setf (isled-row-heading-background section) nil))
  (unless (isled-row-hidden section)
    ;; Follow the heading when a preceding lazy body is inserted at its start.
    (let ((overlay (make-overlay (isled-row-start section)
                                 (1- (isled-row-heading-end section)) nil t)))
      (overlay-put overlay 'face (isled-sections--title-face))
      ;; A line prefix can disappear during redisplay across a folded neighbor.
      ;; Anchor the opening corner to the same overlay as the closing rule.
      (overlay-put overlay 'before-string
                   (concat (propertize "┌──" 'face 'isled-body-bracket-face)
                           (propertize " " 'face 'default)
                           (propertize " " 'face (isled-sections--title-face))))
      (overlay-put overlay 'after-string
                   (concat (propertize " " 'face (isled-sections--title-face))
                           (propertize " " 'face 'default)
                           (propertize " " 'face 'isled-panel-rule-face
                                       'display '(space :align-to right))))
      (overlay-put overlay 'evaporate t)
      (setf (isled-row-heading-background section) overlay)))
  (isled-graph-gutter-style section))

(defun isled-sections-show (section)
  "Show issue SECTION and synchronize its expansion styling.

Search acceptance and explicit expansion share this operation."
  (when-let ((overlay (isled-row-fold section)))
    (overlay-put overlay 'isled-preview nil))
  (setf (isled-row-hidden section) nil)
  (isled-sections--materialize section)
  (isled-sections-format section)
  (isled-sections--sync-visibility-style section)
  (when (fboundp 'isled-loading-schedule) (isled-loading-schedule)))

(defun isled-sections-hide (section)
  "Hide issue SECTION and synchronize its expansion styling.

Retain materialized text so ordinary search can still find it."
  (when-let ((overlay (isled-row-fold section)))
    (overlay-put overlay 'isled-preview nil))
  (setf (isled-row-hidden section) t)
  (isled-fold-update section)
  (isled-sections--sync-visibility-style section))

(defun isled-sections--navigation-positions (&optional issues-only)
  "Return ordered navigation positions, omitting targets when ISSUES-ONLY."
  (let ((positions
         (mapcar
          (lambda (section) (isled-row-start section))
          (seq-filter
           (lambda (section)
             (isled-row-p section))
           (append isled-rows nil))))
        (position (point-min)))
    (while (and (not issues-only) (< position (point-max)))
      (when (and (get-text-property position 'isled-target)
                 (not (invisible-p position)))
        (push position positions))
      (setq position
            (next-single-property-change
             position 'isled-target nil (point-max))))
    (sort (delete-dups positions) #'<)))

(provide 'isled-sections)
;;; isled-sections.el ends here
