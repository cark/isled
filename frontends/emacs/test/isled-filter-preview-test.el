;;; isled-filter-preview-test.el --- Candidate preview boundaries -*- lexical-binding: t; -*-

;;; Commentary:
;; Candidate substitution, restoration, ownership and observer cleanup.
;;; Code:
(require 'ert)
(require 'isled-filter)
(require 'isled-loading-test)

(ert-deftest isled-filter-preview-substitutes-exact-token ()
  (dolist (case '(("t:ru \"two words\" t:rust" 4 "t:runtime"
                   "t:runtime \"two words\" t:rust")
                  ("s:open t:ru k:bug" 11 "t:rust" "s:open t:rust k:bug")
                  ("s:open  s:cl t:rust s:open" 12 "s:closed"
                   "  s:closed t:rust ")
                  ("s:open  t:rust" 7 "s:closed" " s:closed t:rust")))
    (should (equal (isled-filter-preview-query
                    (isled-filter-completion-context (nth 0 case) (nth 1 case))
                    (nth 2 case))
                   (nth 3 case)))))

(ert-deftest isled-filter-preview-requires-ui-ownership ()
  (with-temp-buffer
    (let ((completing-read-function 'completing-read-default)
          (completion-in-region-function 'completion--in-region))
      (should (eq (isled-filter-display-owner) 'stock))
      (should (eq (isled-filter-display-owner t) 'stock))
      (dolist (reader '(ivy-completing-read helm-completing-read-default
                       ido-completing-read+ unknown-reader))
        (let ((completing-read-function reader))
          (should-not (isled-filter-display-owner))))
      (dolist (function '(consult-completion-in-region unknown-capf-ui))
        (let ((completion-in-region-function function))
          (should-not (isled-filter-display-owner t))))
      (dolist (mode '(icomplete-mode mct-mode ivy-mode helm-mode ido-ubiquitous-mode))
        (set (make-local-variable mode) t)
        (should-not (isled-filter-display-owner))
        (set mode nil))
      (dolist (mode '(company-mode auto-complete-mode completion-preview-mode))
        (set (make-local-variable mode) t)
        (should-not (isled-filter-display-owner t))
        (isled-filter-inline-changed)
        (should-not isled-filter-inline--timer)
        (set mode nil))
      ;; A minibuffer UI does not own an independently configured CAPF UI.
      (setq-local ivy-mode t corfu-mode t
                  completion-in-region-function 'corfu--in-region)
      (should (eq (isled-filter-display-owner t) 'corfu)))))

(ert-deftest isled-filter-preview-corfu-belongs-to-buffer ()
  (with-temp-buffer
    (setq-local corfu-mode t completion-in-region-function 'corfu--in-region
                corfu--index 0 corfu--candidates '("t:rust"))
    (let ((completion-in-region-mode t)
          (completion-in-region--data (list (copy-marker (point)))))
      (should (equal (isled-filter-display-candidate t) "t:rust"))
      (with-temp-buffer
        (setq-local corfu-mode t completion-in-region-function 'corfu--in-region)
        (should-not (isled-filter-display-candidate t))))))

(ert-deftest isled-filter-preview-restores-input-without-insertion ()
  (isled-loading-test--with-displayed-buffer
    (isled-mode)
    (setq isled-filter-active '(session))
    (let ((view (current-buffer)) (window (selected-window)) calls)
      (with-temp-buffer
        (insert "t:ru word") (goto-char 5)
        (setq-local isled-filter--origin window isled-filter--view view
                    isled-filter--last "t:ru word"
                    isled-filter--criteria (isled-filter-query-criteria "t:ru word")
                    isled-filter-completion-context
                    (isled-filter-completion-context "t:ru word" 4)
                    isled-filter-completion-values '("t:rust" "t:runtime"))
        (cl-letf (((symbol-function 'isled-filter--request)
                   (lambda (query &rest _) (push query calls))))
          (isled-filter-preview--apply "t:rust")
          (isled-filter-preview--apply "t:rust")
          (isled-filter-preview--apply "t:runtime")
          (isled-filter-preview--apply nil)
          (should (equal (reverse calls) '("t:rust word" "t:runtime word" "t:ru word")))
          (should (equal (buffer-string) "t:ru word"))
          (should (= (point) 5))
          (should (equal isled-filter-completion-values '("t:rust" "t:runtime")))
          ;; An obsolete selection cannot be applied to another token occurrence.
          (goto-char (point-max))
          (isled-filter-preview--apply "t:rust")
          (should (= (length calls) 3)))))))

(ert-deftest isled-filter-preview-observer-is-owned-and-stopped ()
  (with-temp-buffer
    (unwind-protect
        (progn
          (isled-filter-preview-setup 'inline-suggestions)
          (let ((timer isled-filter-preview--timer))
            (should (memq timer timer-list))
            (isled-filter-preview-stop)
            (should-not (memq timer timer-list))
            (should-not isled-filter-preview--timer)))
      (isled-filter-preview-stop))))

(ert-deftest isled-filter-explicit-acceptance-overrides-reader-return ()
  (isled-loading-test--with-displayed-buffer
    (let* ((isled-filter--accepted-query
            (cons "s:closed" (isled-filter-query-criteria "s:closed")))
           requested)
      (cl-letf (((symbol-function 'isled-filter--request)
                 (lambda (query &rest _) (setq requested query))))
        (isled-filter--finish "" (selected-window) (current-buffer))
        (should (equal requested "s:closed"))))))

(ert-deftest isled-filter-invalid-edit-restores-candidate-baseline ()
  (isled-loading-test--with-displayed-buffer
    (isled-mode)
    (let* ((view (current-buffer)) (window (selected-window)) calls
           (isled-process-function
            (lambda (_root request callback) (push (list request callback) calls))))
      (isled-loading-request 'refresh)
      (isled-loading-test--reply (pop calls) 'refresh)
      (setq isled-filter-active '(session))
      (with-temp-buffer
        (insert "s:")
        (setq-local isled-filter--origin window isled-filter--view view
                    isled-filter--last "s:" isled-filter--position 2
                    isled-filter-completion-context
                    (isled-filter-completion-context "s:" 2)
                    isled-filter-completion-values '("s:closed" "s:open"))
        (isled-filter-preview--apply "s:closed")
        (isled-loading-test--reply (pop calls) 'view)
        (should (equal (buffer-local-value 'isled--filter view) "s:closed"))
        (insert "x")
        (isled-filter--changed)
        ;; The typed query is invalid; restoration must survive that input's
        ;; obsolete-response fence, and its following choices-only request.
        (while calls
          (let* ((call (pop calls))
                 (mode (intern (alist-get 'mode (json-parse-string (car call) :object-type 'alist)))))
            (isled-loading-test--reply call mode)))
        (should (eq (buffer-local-value 'isled--filter view) 'open))
        (should-not isled-filter-preview--query)))))

(provide 'isled-filter-preview-test)
;;; isled-filter-preview-test.el ends here
