;;; graph-graphical.el --- Private graph rendering and measurements -*- lexical-binding: t; -*-

;;; Commentary:
;; Driven by the ignored emacs_graph_frontend Rust test on disposable ledgers.
;; Measure real compact payloads with compiled frontend code and a private frame.

;;; Code:
(require 'cl-lib)
(require 'json)
(setq load-prefer-newer t)
(defvar isled-graph-check-results nil)
(defvar isled-graph-check-root (getenv "ISLED_GRAPH_FIXTURE"))
(defvar isled-graph-check-output (getenv "ISLED_GRAPH_RESULTS"))

(defun isled-graph-check-read (path)
  "Read PATH without text properties."
  (with-temp-buffer (insert-file-contents path) (buffer-string)))

(defun isled-graph-check-compile ()
  "Compile candidate modules into private fixture storage and load their bytecode."
  (let* ((source (file-name-directory (locate-library "isled")))
         (destination (expand-file-name "compiled" isled-graph-check-root))
         (files (cl-remove-if
                 (lambda (file) (equal (file-name-nondirectory file) "isled-pkg.el"))
                 (directory-files source t "\\`isled.*\\.el\\'")))
         (byte-compile-error-on-warn t)
         (byte-compile-dest-file-function
          (lambda (file) (expand-file-name (concat (file-name-base file) ".elc") destination))))
    (make-directory destination t)
    (dolist (file files)
      (unless (byte-compile-file file)
        (error "Compilation failed: %s: %s" file
               (if-let ((log (get-buffer "*Compile-Log*")))
                   (with-current-buffer log (buffer-substring-no-properties (point-min) (point-max)))
                 "no compiler log"))))
    (add-to-list 'load-path destination)
    (dolist (file files)
      (load (expand-file-name (concat (file-name-base file) ".elc") destination) nil t))))

(isled-graph-check-compile)
(require 'isled-browser)
(setq isled-auto-revert nil)
(set-frame-size (selected-frame) 100 42)

(defun isled-graph-check-time (name function)
  "Measure FUNCTION as NAME, including GC and allocation counts."
  (let ((start (float-time)) (gc gcs-done) (elapsed gc-elapsed)
        (counts (memory-use-counts)))
    (write-region (concat "start " name "\n") nil
                  (expand-file-name "progress.log" isled-graph-check-output) t 'silent)
    (funcall function)
    (write-region (format "done %s %.1fms\n" name (* 1000 (- (float-time) start))) nil
                  (expand-file-name "progress.log" isled-graph-check-output) t 'silent)
    `((stage . ,name) (ms . ,(* 1000 (- (float-time) start)))
      (gc_count . ,(- gcs-done gc)) (gc_ms . ,(* 1000 (- gc-elapsed elapsed)))
      (allocation_counts . ,(vconcat (cl-mapcar #'- (memory-use-counts) counts))))))

(defun isled-graph-check-display (response)
  "Display a decoded production RESPONSE without requesting unbounded bodies."
  (let ((graph (isled-response-graph response)))
    (setq isled--root (isled-response-root response) isled--filter 'all
          isled-graph-direction (and graph (isled-graph-response-direction graph))
          isled-graph-layout (and graph (isled-graph-response-plan graph))
          isled-graph-hash (and graph (isled-graph-response-hash graph))
          isled--snapshot (isled-data-accept response))
    (isled--render)
    (isled-viewport-update)
    (redisplay t)))

(defun isled-graph-check-scroll ()
  "Scroll through separated ranges and validate bounded retained gutter painting."
  (dolist (index '(1000 2500 4500 0))
    (goto-char (isled-row-start (aref isled-rows index)))
    (set-window-start (selected-window) (point))
    (isled-viewport-update)
    (redisplay t)
    (when (and isled-graph-direction
               (> (hash-table-count isled-graph-gutter--painted)
                  (* 6 (window-body-height))))
      (error "Gutter painting exceeded its visible heading bound"))))

(defun isled-graph-check-screenshot (name)
  "Save this frame as NAME in the benchmark output directory."
  (let ((coding-system-for-write 'no-conversion))
    (write-region (x-export-frames nil 'png) nil
                  (expand-file-name (concat name ".png") isled-graph-check-output) nil 'silent)))

(defun isled-graph-check-case (case)
  "Measure one production payload CASE repeatedly with normal GC settings."
  (let* ((name (alist-get 'name case))
         (text (isled-graph-check-read (alist-get 'file case))) samples)
    (write-region (concat "case " name "\n") nil
                  (expand-file-name "progress.log" isled-graph-check-output) t 'silent)
    (dotimes (_ 5)
      (let ((buffer (generate-new-buffer " *graph benchmark*")) response stages)
        (unwind-protect
            (progn
              (switch-to-buffer buffer)
              (isled-mode)
              (garbage-collect)
              (push (isled-graph-check-time "decode" (lambda () (setq response (isled-frontend-decode text)))) stages)
              (push (isled-graph-check-time "insert_and_redisplay" (lambda () (isled-graph-check-display response))) stages)
              (push (isled-graph-check-time "four_scrolls" #'isled-graph-check-scroll) stages)
              (push (isled-graph-check-time "unchanged_view_refresh"
                                            (lambda () (isled-graph-check-display response))) stages)
              (when (equal name "baseline-prerequisites")
                (let* ((plan isled-graph-layout)
                       (details (isled-frontend-decode
                                 (isled-graph-check-read (expand-file-name "details.json" isled-graph-check-root)))))
                  (setq isled--snapshot (isled-data-accept details))
                  (isled--render)
                  (push (isled-graph-check-time
                         "expand_and_redisplay"
                         (lambda () (isled-sections-show (aref isled-rows 0))
                           (isled-viewport-update) (redisplay t))) stages)
                  (unless (eq plan isled-graph-layout) (error "Expansion recomputed layout"))
                  (unless (= 1 (hash-table-count isled-data-details)) (error "Unbounded body loading"))
                  (set-frame-size (selected-frame) 65 42)
                  (isled-viewport-update) (redisplay t)
                  (unless (string-prefix-p "  │" (get-text-property
                                                   (1+ (isled-row-content (aref isled-rows 0))) 'wrap-prefix))
                    (error "Wrapped body lost its dependency continuation"))
                  (isled-graph-check-screenshot "expanded-wrapped")
                  (set-frame-size (selected-frame) 100 42)))
              (when (equal name "diamonds-prerequisites") (isled-graph-check-screenshot "diamonds"))
              (when (equal name "wide-prerequisites") (isled-graph-check-screenshot "wide"))
              (push (vconcat (nreverse stages)) samples))
          (kill-buffer buffer))))
    (push `((case . ,name) (samples . ,(vconcat (nreverse samples)))) isled-graph-check-results)))

(let ((manifest (json-parse-string
                 (isled-graph-check-read (expand-file-name "manifest.json" isled-graph-check-root))
                 :object-type 'alist :array-type 'list)))
  (dolist (case manifest)
    (when (or (not (getenv "ISLED_GRAPH_CASE"))
              (equal (getenv "ISLED_GRAPH_CASE") (alist-get 'name case)))
      (isled-graph-check-case case)))
  ;; Check help after all timings so transient window changes cannot alter the
  ;; benchmark's window height or the bounded nearby painting workload.
  (let ((buffer (generate-new-buffer " *graph help check*")))
    (unwind-protect
        (progn
          (switch-to-buffer buffer)
          (isled-mode)
          (isled-graph-check-display
           (isled-frontend-decode
            (isled-graph-check-read (expand-file-name "diamonds-prerequisites.json"
                                                     isled-graph-check-root))))
          (call-interactively #'isled-help)
          (redisplay t)
          (unless (with-current-buffer (get-buffer " *transient*")
                    (and (string-match-p "Filter issues" (buffer-string))
                         (string-match-p "Reverse graph direction" (buffer-string))))
            (error "Graph help did not expose current commands"))
          (isled-graph-check-screenshot "help")
          (transient-quit-one))
      (kill-buffer buffer))))
(with-temp-file (expand-file-name "emacs.json" isled-graph-check-output)
  (insert (json-serialize `((emacs . ,emacs-version) (gc_threshold . ,gc-cons-threshold)
                            (cases . ,(vconcat (nreverse isled-graph-check-results)))))))
(with-temp-file (getenv "PI_RESULT") (prin1 '(:passed t) (current-buffer)))
(kill-emacs 0)

;;; graph-graphical.el ends here
