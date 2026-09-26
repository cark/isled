;;; graph-fold-graphical.el --- Check displayed graph nodes across folds -*- lexical-binding: t; -*-

;;; Commentary:
;; Run with scripts/private-graphical-emacs.py, never through a working server.
;; Inspect the actual redisplay matrix: text properties alone missed lost nodes.

;;; Code:
(setq load-prefer-newer t)
;; Load the chosen candidate before fixture helpers add the checkout to load-path.
(require 'isled-browser)
(require 'isled-view-test)
(require 'isled-graph-test)
(require 'isled-graph-drawing-test)
(setq isled-auto-revert nil)
(set-frame-size nil 65 45)
(switch-to-buffer (get-buffer-create " *graph folds*"))
(isled-mode)
(setq isled--snapshot (isled-view-test--open-snapshot "0001" "0002" "0004" "0008" "0005")
      isled-graph-direction 'prerequisites isled-graph-hash "0000000000000001"
      isled-graph-layout (isled-graph-drawing-test--plan))
(setf (isled-issue-content (car (isled-snapshot-issues isled--snapshot)))
      (concat "## Statement\n\n" (apply #'concat (make-list 12 "Wrapped issue text. ")) "\n"))
(isled--render)
(sit-for 0.1)

(defun isled-graph-fold-check-display ()
  "Check actual node and connector glyphs after redisplaying every issue."
  (goto-char (point-min))
  (set-window-start nil (point-min))
  (isled-viewport-update)
  (redisplay t)
  (cl-loop for row across isled-rows for index from 0 do
           (unless (posn-at-point (isled-row-start row))
             (goto-char (isled-row-start row))
             (set-window-start nil (point))
             (isled-viewport-update)
             (redisplay t))
           (let* ((glyphs (isled-graph-glyphs-render isled-graph-layout index))
                  (position (posn-at-point (isled-row-start row)))
                  (y (+ (cdr (posn-x-y position)) (window-header-line-height)))
                  (width (frame-char-width))
                  (height (frame-char-height)))
             (cl-loop for text in (cons (isled-graph-glyphs-heading glyphs)
                                        (when (isled-graph-glyphs-connector glyphs)
                                          (split-string (isled-graph-glyphs-connector glyphs) "\n")))
                      for line from 0 do
                      (dotimes (cell (length text))
                        (unless (= (aref text cell) ?\s)
                          (let ((shown (posn-string
                                        (posn-at-x-y (+ (* cell width) (/ width 2))
                                                     (+ y (* line height) 1)))))
                            (unless (and shown (= (aref (car shown) (cdr shown))
                                                  (aref text cell)))
                              (error "Wrong visible graph glyph: issue %s line %s cell %s: %S"
                                     (isled-row-value row) line cell shown)))))))))

(isled-graph-fold-check-display)
(defun isled-graph-fold-check-spacing ()
  "Check collapsed headings add a line only for horizontal routing."
  (goto-char (point-min))
  (set-window-start nil (point-min))
  (isled-viewport-update)
  (redisplay t)
  (cl-loop for index from 0 below (1- (length isled-rows))
           for row = (aref isled-rows index)
           for next = (aref isled-rows (1+ index))
           for height = (- (cdr (posn-x-y (posn-at-point (isled-row-start next))))
                           (cdr (posn-x-y (posn-at-point (isled-row-start row)))))
           for lines = (1+ (isled-graph-glyphs-line-count isled-graph-layout index))
           unless (= height (* (frame-char-height) lines))
           do (error "Wrong collapsed spacing for issue %s: %s" (isled-row-value row) height)))

(isled-graph-fold-check-spacing)

(defun isled-graph-fold-check-panels ()
  "Check that expanded panel borders continue beside every routing line."
  (cl-loop for row across isled-rows do
           (goto-char (isled-row-start row))
           (set-window-start nil (point))
           (isled-viewport-update)
           (redisplay t)
           (let ((column (length (isled-graph-glyphs-heading
                                  (isled-graph-glyphs-render
                                   isled-graph-layout (isled-row-index row))))))
             (cl-loop for position from (isled-row-heading-end row)
                      below (isled-row-content row) by 2 do
                      (let* ((y (+ (cdr (posn-x-y (posn-at-point position)))
                                   (window-header-line-height)))
                             (shown (posn-string
                                     (posn-at-x-y
                                      (+ (* column (frame-char-width))
                                         (/ (frame-char-width) 2)) (1+ y)))))
                        (unless (and shown (= (aref (car shown) (cdr shown)) ?│))
                          (error "Gap in expanded panel: issue %s routing position %s: %S"
                                 (isled-row-value row) position shown)))))))

;; Materialize several neighboring bodies, then refold them repeatedly.
(dotimes (_ 2)
  (cl-loop for row across isled-rows do (isled-sections-show row))
  (isled-graph-fold-check-display)
  (isled-graph-fold-check-panels)
  (cl-loop for row across isled-rows do (isled-sections-hide row))
  (isled-graph-fold-check-display)
  (isled-graph-fold-check-spacing))
;; Leave enough trailing space to move every fixture line through the window top.
;; The preceding fold cycles deliberately leave materialized, invisible bodies.
(let ((inhibit-read-only t))
  (save-excursion (goto-char (point-max)) (insert (make-string 50 ?\n))))
(defvar isled-graph-fold-scroll-lines
  (cl-loop for row across isled-rows for index from 0
           for glyphs = (isled-graph-glyphs-render isled-graph-layout index)
           append (cons (cons (isled-row-start row) (isled-graph-glyphs-heading glyphs))
                        (cl-loop for line in (and (isled-graph-glyphs-connector glyphs)
                                                 (split-string (isled-graph-glyphs-connector glyphs) "\n"))
                                 for position from (isled-row-heading-end row) by 2
                                 collect (cons position line)))))
(setq isled-graph-fold-scroll-lines
      (append isled-graph-fold-scroll-lines (cdr (reverse isled-graph-fold-scroll-lines))))
(goto-char (point-min))
(set-window-start nil (point-min))
(keymap-local-set "<f8>" #'scroll-up-line)
(keymap-local-set "<f9>" #'scroll-down-line)

(defun isled-graph-fold-check-scroll ()
  "Move each heading and connector through the top using real scroll commands."
  (condition-case failure
      (let* ((expected (pop isled-graph-fold-scroll-lines))
             (text (cdr expected))
             (start (window-start)))
        (isled-viewport-update)
        (redisplay t)
        ;; Emacs may anchor at the preceding invisible body.  Compare the
        ;; first visible position as well as the actual displayed glyphs.
        (while (and (< start (point-max)) (invisible-p start))
          (setq start (next-char-property-change start)))
        (unless (= start (car expected))
          (error "Scroll stopped at %s instead of %s" start (car expected)))
        (dotimes (cell (length text))
          (unless (= (aref text cell) ?\s)
            (let ((shown (posn-string
                          (posn-at-x-y (+ (* cell (frame-char-width)) (/ (frame-char-width) 2))
                                       (1+ (window-header-line-height))))))
              (unless (and shown (= (aref (car shown) (cdr shown)) (aref text cell)))
                (error "Wrong top-row glyph at %s cell %s: %S" (window-start) cell shown)))))
        (if isled-graph-fold-scroll-lines
            (progn
              (execute-kbd-macro (kbd (if (> (caar isled-graph-fold-scroll-lines) (car expected))
                                         "<f8>" "<f9>")))
              (run-at-time 0.02 nil #'isled-graph-fold-check-scroll))
          (with-temp-file (getenv "PI_RESULT")
            (prin1 '(:passed t :fold-cycles 2 :scroll-lines 14) (current-buffer)))
          (kill-emacs 0)))
    (error
     (with-temp-file (getenv "PI_RESULT") (prin1 failure (current-buffer)))
     (kill-emacs 1))))
(run-at-time 0.02 nil #'isled-graph-fold-check-scroll)
;;; graph-fold-graphical.el ends here
