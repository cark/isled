;;; isled-sections-test.el --- Section presentation tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused ERT coverage for expandable issue rendering.

;;; Code:

(require 'ert)

(let ((test-directory
       (file-name-directory (or load-file-name buffer-file-name))))
  (add-to-list 'load-path test-directory)
  (add-to-list 'load-path
               (file-name-directory (directory-file-name test-directory))))

(require 'isled-sections)
(require 'isled-view-test)

(ert-deftest isled-sections-expanded-body-face-borrows-background-only ()
  (let ((spec (get 'isled-expanded-body-face 'face-defface-spec)))
    (should (equal spec
                   '((t :extend t))))))

(ert-deftest isled-sections-ledger-warning-area-is-conditional ()
  (let ((snapshot (isled-view-test--snapshot)))
    (setf (isled-snapshot-unavailable snapshot)
          (list (isled-unavailable-create
                 :id "0009" :path "/tmp/unreadable.md" :error "Invalid Status.")))
    (with-temp-buffer
      (special-mode)
      (let ((inhibit-read-only t))
        (isled-sections-insert snapshot 'open nil))
      (goto-char (point-min))
      (should (looking-at-p "\n\nLedger warnings\n"))
      (should-not (get-text-property (point) 'face))
      (should (isled-sections-test--face-includes-p
               (get-text-property (1+ (point)) 'face)
               'isled-ledger-warning-face))
      (search-forward "Invalid Status.")
      (should (equal (substring-no-properties
                      (get-text-property (1- (point)) 'line-prefix))
                     "      "))
      (should (isled-sections-test--face-includes-p
               (get-text-property (1- (point)) 'face)
               'isled-ledger-warning-face))
      (should (equal (get-text-property (1- (point)) 'line-prefix)
                     (get-text-property (1- (point)) 'wrap-prefix)))
      (search-forward "[Open file]")
      (should (equal (get-text-property (1- (point)) 'isled-warning-action)
                     '(open-file "/tmp/unreadable.md")))
      (search-forward "[Move to trash]")
      (should (equal (get-text-property (1- (point)) 'isled-warning-action)
                     '(trash-file "/tmp/unreadable.md")))
      (search-forward "#0001")
      (should-not (isled-sections-test--face-includes-p
                   (get-text-property (1- (point)) 'face)
                   'isled-ledger-warning-face))
      (setf (isled-snapshot-unavailable snapshot) nil)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (isled-sections-insert snapshot 'open nil))
      (goto-char (point-min))
      (should (looking-at-p "#0001")))))

(ert-deftest isled-sections-display-generated-warnings-with-targets ()
  (let* ((snapshot (isled-view-test--snapshot))
         (issue (car (isled-snapshot-issues snapshot))))
    (setf (isled-issue-warnings issue)
          (list (isled-warning-create
                 :code "RELATION_RECIPROCAL" :message "Missing mirror."
                 :source-id "0001" :target-id "0002" :needs-reason nil
                 :related-ids '("0002" "0099"))))
    (with-temp-buffer
      (special-mode)
      (let ((inhibit-read-only t))
        (isled-sections-insert snapshot 'open '("0001")))
      (goto-char (point-min))
      (search-forward "Warnings")
      (should (equal (substring-no-properties
                      (get-text-property (1- (point)) 'line-prefix))
                     "│  "))
      (let* ((section (isled-row-at))
             (boundary (isled-row-content section)))
        (dotimes (_ 2)
          (let ((prefix (get-text-property boundary 'line-prefix)))
            (should prefix)
            (dotimes (index (length prefix))
              (should-not (isled-sections-test--face-includes-p
                           (get-text-property index 'face prefix)
                           'isled-expanded-body-face))))
          (save-excursion
            (isled-sections-hide section)
            (isled-sections-show section))))
      (should-not (isled-sections-test--face-includes-p
                   (get-text-property (1- (point)) 'face)
                   'isled-expanded-body-face))
      (let ((prefix (get-text-property (1- (point)) 'line-prefix)))
        (dotimes (index (length prefix))
          (should-not (isled-sections-test--face-includes-p
                       (get-text-property index 'face prefix)
                       'isled-expanded-body-face))))
      (search-forward "#0002")
      (should (equal (get-text-property (1- (point)) 'isled-target-id)
                     "0002"))
      (search-forward "#0099")
      (should-not (get-text-property (1- (point)) 'isled-target-id))
      (search-forward "[Complete relation]")
      (should (eq (get-text-property (1- (point)) 'isled-target)
                  'warning-action))
      (should (equal (get-text-property (1- (point)) 'isled-warning-action)
                     '(complete "0001" "0002" nil)))
      (search-forward "[Remove relation]")
      (should (equal (get-text-property (1- (point)) 'isled-warning-action)
                     '(remove "0001" "0002")))
      (search-forward "Body.")
      (should (equal (isled-issue-content issue)
                     (isled-issue-content
                      (car (isled-snapshot-issues
                            (isled-view-test--snapshot)))))))))

(ert-deftest isled-sections-render-expandable-markdown-content ()
  (with-temp-buffer
    (special-mode)
    (let ((inhibit-read-only t))
      (isled-sections-insert
       (isled-view-test--snapshot) 'open '("0001")))
    (let ((text (buffer-string)))
      (should-not (string-match-p "Open issues (1)" text))
      (goto-char (point-min))
      (should (equal "0001" (isled-sections-id-at-point)))
      (should (string-match-p (regexp-quote "#0001  [feature] First issue") text))
      (should (string-match-p "Body\\." text))
      (should (isled-sections-test--face-includes-p (get-text-property
                   (string-match "#0001" text) 'face text)
                  'isled-ready-issue-id-face))
      (should (isled-sections-test--face-includes-p (get-text-property
                   (string-match "First issue" text) 'face text)
                  'isled-issue-title-face))
      (should (isled-sections-test--face-includes-p
               (get-text-property
                (string-match "Body\\." text) 'face text)
               'isled-expanded-body-face))
      (should (isled-sections-test--face-includes-p
               (get-text-property
                (string-match "# 0001" text) 'face text)
               'isled-expanded-body-face))
      (let* ((relation (string-match "#0002" text))
             (existing (string-match "#2" text))
             (missing (string-match "#9999" text))
             (markdown (string-match "documentation" text))
             (reference (get-text-property
                         existing 'isled-reference text)))
        (should (isled-sections-test--face-includes-p
                 (get-text-property relation 'face text)
                 'isled-closed-reference-face))
        (should (eq
                 (isled-inline-reference-field
                  (get-text-property relation 'isled-reference text))
                 'waiting_on))
        (should (isled-sections-test--face-includes-p
                 (get-text-property existing 'face text)
                 'isled-closed-reference-face))
        (should (equal
                 (isled-inline-reference-target-id reference)
                 "0002"))
        (should (eq (get-text-property existing 'isled-target text)
                    'issue-reference))
        (should (eq (get-text-property markdown 'isled-target text)
                    'markdown-link))
        (should-not (get-text-property missing 'isled-target text))
        (should (isled-sections-test--face-includes-p
                 (get-text-property missing 'face text)
                 'isled-missing-target-reference-face))
        (should (eq
                 (isled-inline-reference-resolution
                  (get-text-property missing 'isled-reference text))
                 'missing)))
      (should (equal (get-text-property
                      (string-match "# 0001" text) 'display text)
                     ""))
      (should (eq (get-text-property
                   (string-match "\\*Emphasis" text) 'invisible text)
                  'markdown-markup))
      (should (invisible-p (1+ (string-match "\\*Emphasis" text))))
      (should (equal (get-text-property
                      (string-match "- \\*Emphasis" text) 'display text)
                     "●"))
      (should (isled-sections-test--face-includes-p
               (get-text-property
                (string-match "documentation" text) 'face text)
               'isled-markdown-link-face))
      (should (eq (get-text-property
                   (string-match "guide\\.md" text) 'invisible text)
                  'markdown-markup))
      (should (invisible-p (1+ (string-match "guide\\.md" text)))))
    (goto-char (point-min))
    (search-forward "0001")
    (should (equal (isled-sections-id-at-point) "0001"))
    (should-not (get-text-property (point-min) 'line-prefix))
    (let ((prefix (overlay-get (isled-row-heading-background (car (append isled-rows nil))) 'before-string)))
      (should (equal "┌──  " prefix))
      (should (eq (get-text-property 3 'face prefix) 'default))
      (should (eq (get-text-property 4 'face prefix)
                  'isled-panel-title-face)))
    (forward-line 1)
    (should (looking-at-p "\n"))
    (should (invisible-p (point)))
    (should (equal "│  " (get-text-property (point) 'line-prefix)))
    (search-forward "Body.")
    (let ((prefix (get-text-property (1- (point)) 'line-prefix)))
      (should (equal prefix "│    "))
      (should (eq (get-text-property 1 'face prefix) 'default))
      (should (eq (get-text-property 2 'face prefix)
                  'isled-expanded-body-face))
      (should (equal prefix (get-text-property (1- (point)) 'wrap-prefix))))))

(ert-deftest isled-sections-indent-content-not-headings-or-background ()
  (with-temp-buffer
    (special-mode)
    (let* ((snapshot (isled-view-test--snapshot))
           (issue (car (isled-snapshot-issues snapshot)))
           (content "# Title\n\n## Metadata\n\n- Item\n\n## Text\n\nParagraph.\n\n```text\n## Not a heading\n```\n")
           (inhibit-read-only t))
      (setf (isled-issue-content issue) content
            (isled-issue-references issue) nil)
      (isled-sections-insert snapshot 'open '("0001"))
      (dolist (entry '(("## Metadata" . 3) ("- Item" . 5)
                       ("## Text" . 3) ("Paragraph." . 5)
                       ("## Not a heading" . 5)))
        (goto-char (point-min))
        (search-forward (car entry))
        (let ((prefix (get-text-property (line-beginning-position) 'line-prefix)))
          (should (= (length prefix) (cdr entry)))
          (should (eq (get-text-property 0 'face prefix)
                      'isled-body-bracket-face))
          (should (eq (get-text-property 2 'face prefix)
                      'isled-expanded-body-face))
          (should (equal prefix (get-text-property
                                (line-beginning-position) 'wrap-prefix)))))
      (should (string-match-p (regexp-quote content)
                              (buffer-substring-no-properties
                               (point-min) (point-max)))))))

(ert-deftest isled-sections-collapse-keeps-next-heading-unindented ()
  (with-temp-buffer
    (special-mode)
    (let ((inhibit-read-only t))
      (isled-sections-insert
       (isled-view-test--snapshot) 'all nil))
    (let ((first (car (append isled-rows nil)))
          (next (cadr (append isled-rows nil))))
      (dotimes (_ 3)
        (isled-sections-show first)
        (let ((prefix (get-text-property (isled-row-content first) 'line-prefix)))
          (should (equal "│  " prefix))
          (should (eq (get-text-property 0 'face prefix)
                      'isled-body-bracket-face)))
        (should (overlayp (isled-row-heading-background first)))
        (should (eq (overlay-get (isled-row-heading-background first) 'face)
                    'isled-panel-title-face))
        (should (= (overlay-end (isled-row-heading-background first))
                   (1- (isled-row-content first))))
        (let ((tail (overlay-get (isled-row-heading-background first) 'after-string)))
          (should (eq (get-text-property 0 'face tail)
                      'isled-panel-title-face))
          (should (eq (get-text-property 1 'face tail) 'default))
          (should (equal (get-text-property 2 'display tail)
                         '(space :align-to right))))
        (should (equal "│    " (get-text-property (isled-row-start first) 'wrap-prefix)))
        (isled-sections-hide first)
        (should-not (isled-row-heading-background first))
        ;; A prefix on the first invisible body line leaks into the next
        ;; visible heading during redisplay.  Keep that separator unstyled.
        (should-not (get-text-property (isled-row-content first) 'line-prefix))
        (should (invisible-p (isled-row-content first)))
        (should-not (get-text-property (isled-row-start next) 'line-prefix))
        (should-not (isled-row-heading-background next))))))

(ert-deftest isled-sections-background-stays-with-later-heading ()
  (with-temp-buffer
    (special-mode)
    (let ((inhibit-read-only t))
      (isled-sections-insert
       (isled-view-test--snapshot) 'all nil))
    (let ((first (car (append isled-rows nil)))
          (next (cadr (append isled-rows nil))))
      ;; Expanding the earlier issue inserts its lazy body exactly where the
      ;; later issue's heading and background used to start.
      (isled-sections-show next)
      (isled-sections-show first)
      (let ((background (isled-row-heading-background next)))
        (should (= (overlay-start background) (isled-row-start next)))
        (should-not (memq background (overlays-at (1- (isled-row-start next))))))
      (dotimes (_ 3)
        (isled-sections-hide first)
        (let ((background (isled-row-heading-background next)))
          (should (equal "┌──  " (overlay-get background 'before-string)))
          (should (= (overlay-start background) (isled-row-start next)))
          (should-not (get-text-property (isled-row-start next) 'line-prefix)))
        (isled-sections-show first)))))

(ert-deftest isled-sections-title-background-is-optional ()
  (dolist (enabled '(nil t))
    (with-temp-buffer
      (special-mode)
      (let ((isled-title-background enabled)
            (inhibit-read-only t))
        (isled-sections-insert
         (isled-view-test--snapshot) 'open '("0001"))
        (let* ((section (car (append isled-rows nil)))
               (overlay (isled-row-heading-background section))
               (expected (if enabled 'isled-panel-title-background-face
                           'isled-panel-title-face)))
          (should (eq expected (overlay-get overlay 'face)))
          (should (eq expected (get-text-property
                                0 'face (overlay-get overlay 'after-string)))))))))

(ert-deftest isled-sections-title-hidden-and-inner-padding ()
  (with-temp-buffer
    (special-mode)
    (let ((inhibit-read-only t))
      (isled-sections-insert
       (isled-view-test--snapshot) 'open '("0001")))
    (goto-char (point-min))
    (search-forward "# 0001")
    (let ((title-start (line-beginning-position)))
      (should (invisible-p title-start))
      (should (equal "" (get-text-property title-start 'display)))
      (forward-line)
      (should (looking-at-p "\n"))
      (should-not (invisible-p (point)))
      (should (isled-sections-test--face-includes-p
               (get-text-property (point) 'face)
               'isled-expanded-body-face)))
    (goto-char (- (point-max) 2))
    (should (looking-at-p "\n\n"))
    (should (isled-sections-test--face-includes-p
             (get-text-property (point) 'face)
             'isled-expanded-body-face))
    (forward-char)
    (should (equal "└────" (get-text-property (point) 'line-prefix)))
    (should-not (get-text-property (point) 'isled-target))))

(ert-deftest isled-sections-move-through-headings-and-targets ()
  (with-temp-buffer
    (special-mode)
    (let ((inhibit-read-only t))
      (isled-sections-insert
       (isled-view-test--snapshot) 'open '("0001")))
    (isled-sections-goto-id "0001")
    (should (equal (isled-sections-move 1) "0001"))
    (should (equal (get-text-property (point) 'isled-target)
                   'issue-reference))
    (should (looking-at-p "#0002"))
    (should (equal (isled-sections-move 1) "0001"))
    (should (looking-at-p "#2"))
    (should (equal (isled-sections-move 1) "0001"))
    (should (looking-at-p "documentation"))
    (should-not (isled-sections-move 1))
    (should (equal (isled-sections-move -1) "0001"))
    (should (looking-at-p "#2"))))

(ert-deftest isled-sections-preserve-canonical-content-bytes ()
  (let* ((snapshot (isled-view-test--snapshot))
         (issue (car (isled-snapshot-issues snapshot)))
         (presented (isled-sections--present-issue
                     issue (isled-view-index-issues
                            (isled-snapshot-issues snapshot)))))
    (should (equal (substring-no-properties presented)
                   (isled-issue-content issue)))))

(ert-deftest isled-sections-align-work-tables-without-changing-source-or-labels ()
  (let* ((content (concat "# 0117 — Work\n\n## Work log\n\n"
                          "| Started (UTC)       | Stopped (UTC)       | Activity       |\n"
                          "|---------------------|---------------------|----------------|\n"
                          "| 2026-10-06 07:11:02 | 2026-10-06 07:36:15 | Implementation |\n"
                          "| 2026-10-06 07:59:03 | 2026-10-06 08:16:14 | Emacs interaction fixes |\n"
                          "| 2026-10-06 09:00:00 | 2026-10-06 09:10:00 | *Review* |\n"
                          "| 2026-10-06 10:00:00 |||\n\n## Evidence\n\n- Checked.\n"))
         (presented (isled-sections--markdown-view content)))
    (should (equal (substring-no-properties presented) content))
    (with-temp-buffer
      (insert presented)
      (goto-char (point-min))
      (search-forward "## Work log\n\n")
      (let (columns)
        (while (looking-at-p "|")
          (let ((end (line-end-position)) (visible ""))
            (while (< (point) end)
              (let* ((next (next-single-property-change (point) 'display nil end))
                     (display (get-text-property (point) 'display)))
                (should (or (null display) (stringp display)))
                (should-not (get-text-property (point) 'invisible))
                (setq visible (concat visible (or display (buffer-substring (point) next))))
                (goto-char next)))
            (let ((positions (cl-loop for i from 0 below (length visible)
                                      when (eq (aref visible i) ?|)
                                      collect (string-width (substring visible 0 i)))))
              (if columns (should (equal positions columns)) (setq columns positions)))
            (when (string-match-p "Review" visible)
              (should (string-match-p (regexp-quote "*Review*") visible))))
          (forward-line))
        (should (equal columns '(0 22 44 70)))))))

(ert-deftest isled-sections-select-semantic-reference-faces ()
  (let ((ready (isled-issue-create
                :id "0001" :status "open" :ready t))
        (waiting (isled-issue-create
                  :id "0002" :status "open" :ready nil))
        (closed (isled-issue-create
                   :id "0003" :status "closed" :ready nil)))
    (should (eq (isled-sections--reference-face ready)
                'isled-ready-reference-face))
    (should (eq (isled-sections--reference-face waiting)
                'isled-waiting-reference-face))
    (should (eq (isled-sections--reference-face closed)
                'isled-closed-reference-face))
    (should (eq (isled-sections--reference-face nil)
                'isled-missing-target-reference-face))))

(ert-deftest isled-sections-select-semantic-heading-id-faces ()
  (let ((ready (isled-issue-create
                :id "0001" :status "open" :ready t))
        (waiting (isled-issue-create
                  :id "0002" :status "open" :ready nil))
        (closed (isled-issue-create
                   :id "0003" :status "closed" :ready nil)))
    (should (eq (isled-sections--issue-id-face ready)
                'isled-ready-issue-id-face))
    (should (eq (isled-sections--issue-id-face waiting)
                'isled-waiting-issue-id-face))
    (should (eq (isled-sections--issue-id-face closed)
                'isled-closed-issue-id-face))))

(ert-deftest isled-sections-render-canonical-closed-heading-id ()
  (with-temp-buffer
    (special-mode)
    (let ((inhibit-read-only t))
      (isled-sections-insert
       (isled-view-test--snapshot) 'closed nil))
    (let* ((text (buffer-string))
           (id-position (string-match (regexp-quote "#0002  [feature] Second issue") text)))
      (should id-position)
      (should (isled-sections-test--face-includes-p (get-text-property id-position 'face text)
                  'isled-closed-issue-id-face))
      (should (isled-sections-test--face-includes-p (get-text-property (string-match "Second issue" text) 'face text)
                  'isled-issue-title-face)))))

(ert-deftest isled-sections-kind-stays-subdued-through-folding ()
  (with-temp-buffer
    (special-mode)
    (let* ((snapshot (isled-view-test--snapshot))
           (issue (car (isled-snapshot-issues snapshot)))
           (inhibit-read-only t))
      (setf (isled-issue-kind issue) "maintenance")
      (isled-sections-insert snapshot 'open nil)
      (let ((section (car (append isled-rows nil))))
        (dolist (visibility '(hidden shown hidden))
          (if (eq visibility 'shown)
              (isled-sections-show section)
            (isled-sections-hide section))
          (goto-char (isled-row-start section))
          (should (looking-at-p (regexp-quote "#0001  [maintenance] First issue")))
          (search-forward "[")
          (let ((bracket (1- (point)))
                (kind (point)))
            (should (isled-sections-test--face-includes-p (get-text-property bracket 'face)
                  'isled-issue-kind-bracket-face))
            (should (isled-sections-test--face-includes-p (get-text-property kind 'face)
                  'isled-issue-kind-face))
            (should-not (get-text-property kind 'isled-target))
            (should (equal (isled-sections-id-at-point kind) "0001")))
          (search-forward "]")
          (should (isled-sections-test--face-includes-p (get-text-property (1- (point)) 'face)
                  'isled-issue-kind-bracket-face)))))))

(ert-deftest isled-sections-keep-collapsed-content-lazy ()
  (with-temp-buffer
    (special-mode)
    (let ((inhibit-read-only t))
      (isled-sections-insert
       (isled-view-test--snapshot) 'open nil))
    (should-not (string-match-p "Body\\." (buffer-string)))
    (should-not (text-property-not-all
                 (point-min) (point-max) 'isled-target nil))
    (isled-sections-goto-id "0001")
    (isled-sections-show (isled-row-at))
    (should (string-match-p "Body\\." (buffer-string)))
    (should (equal (isled-sections-expanded-ids) '("0001")))))

(defun isled-sections-test--face-includes-p (value face)
  "Return non-nil when face property VALUE includes FACE."
  (if (listp value)
      (seq-some
       (lambda (item)
         (isled-sections-test--face-includes-p item face))
       value)
    (eq value face)))

(provide 'isled-sections-test)
;;; isled-sections-test.el ends here
