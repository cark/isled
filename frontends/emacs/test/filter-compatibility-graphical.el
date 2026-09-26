;;; filter-compatibility-graphical.el --- Foreign completion coexistence -*- lexical-binding: t; -*-

;;; Commentary:
;; Private smoke tests, with each framework enabled in a separate Emacs process.
;;; Code:
(setq load-prefer-newer t native-comp-jit-compilation nil)
(require 'isled-file-visit-test)
(setq isled-test-program (getenv "PI_PROGRAM"))
(defvar pi-compat-ui (intern (getenv "PI_UI")))
(pcase pi-compat-ui
  ('ivy (require 'ivy) (ivy-mode 1))
  ('helm (require 'helm-mode) (helm-mode 1))
  ('ido (require 'ido-completing-read+) (ido-mode 1) (ido-ubiquitous-mode 1))
  ('icomplete (icomplete-mode 1))
  ('fido (fido-vertical-mode 1))
  ('company (require 'company) (global-company-mode 1)))

(defun pi-compat-wait ()
  "Wait for asynchronous filter choices in the private test."
  (interactive)
  (let ((deadline (+ (float-time) 0.4)))
    (while (< (float-time) deadline) (accept-process-output nil 0.01))))

(defun pi-compat-setup ()
  "Add private checks without changing framework navigation bindings."
  (when (eq pi-compat-ui 'company) (company-mode 1))
  (local-set-key (kbd "<f8>") #'pi-compat-wait))

(ert-deftest isled-filter-foreign-ui-interaction ()
  (isled-file-visit-test--with-ledger
    (isled root)
    (pi-compat-wait)
    (let ((reader completing-read-function)
          (region completion-in-region-function)
          (hooks (copy-sequence post-command-hook))
          (setup (copy-sequence minibuffer-setup-hook))
          (minibuffer-setup-hook (cons #'pi-compat-setup minibuffer-setup-hook)))
      (dolist (interface '(inline-suggestions separate-filter-picker minibuffer-suggestions))
        (setq isled-filter-interface interface)
        (execute-kbd-macro (kbd "f C-a C-k s : c l o s e d <f8> RET"))
        (pi-compat-wait)
        (should (equal isled--filter "s:closed"))
        (should-not isled-filter-active)
        (execute-kbd-macro (kbd "f C-a C-k s : o p e n <f8> C-g"))
        (pi-compat-wait)
        (should (equal isled--filter "s:closed"))
        (should-not isled-filter-active)
        (should (eq isled-filter-interface interface)))
      (should (eq reader completing-read-function))
      (should (eq region completion-in-region-function))
      (should (equal hooks post-command-hook))
      (should (equal setup (cdr minibuffer-setup-hook)))
      (should-not (seq-some (lambda (timer)
                             (eq (timer--function timer) 'isled-filter-preview-observe))
                           timer-list))
      ;; Ordinary completion still uses the same framework after filter prompts.
      (let (answer)
        (global-set-key (kbd "<f11>")
                        (lambda () (interactive)
                          (setq answer (completing-read "Normal completion: " '("alpha" "beta")))))
        (execute-kbd-macro (kbd "<f11> b e t a RET"))
        (should (equal answer "beta")))
      ;; A CAPF in an unrelated buffer retains its function and query boundaries.
      (with-current-buffer (get-buffer-create " *pi-compat-capf*")
        (switch-to-buffer (current-buffer))
        (setq-local completion-at-point-functions
                    (list (lambda () (list (point-min) (point-max) '("alpha" "beta")))))
        (insert "bet")
        (let ((function completion-in-region-function))
          (call-interactively #'completion-at-point)
          (should (equal (buffer-string) "beta"))
          (should (eq function completion-in-region-function)))
        (when (eq pi-compat-ui 'company)
          (require 'company-capf)
          (company-mode 1)
          (setq-local company-minimum-prefix-length 0
                      completion-at-point-functions
                      (list (lambda () (list (point-min) (point-max) '("beta" "bravo")))))
          (erase-buffer) (insert "b")
          (company-begin-backend 'company-capf)
          (should (= (length company-candidates) 2))
          (company-select-next)
          (let ((expected (nth company-selection company-candidates)))
            (company-complete-selection)
            (should (equal (buffer-string) expected)))
          (erase-buffer) (insert "b")
          (company-begin-backend 'company-capf)
          (company-abort)
          (should (equal (buffer-string) "b"))
          (should-not company-candidates))))
    (when (get-buffer " *pi-compat-capf*") (kill-buffer " *pi-compat-capf*"))))

(ert-deftest isled-filter-native-picker ()
  (isled-file-visit-test--with-ledger
    (isled root)
    (pi-compat-wait)
    (let ((minibuffer-setup-hook (cons #'pi-compat-setup minibuffer-setup-hook)))
      (setq isled-filter-interface
            (if (getenv "PI_FALLBACK") 'minibuffer-suggestions 'separate-filter-picker))
      (execute-kbd-macro (kbd "f C-a C-k s : <f8> TAB c l o s e d RET RET"))
      (pi-compat-wait)
      (should (equal isled--filter "s:closed"))
      (execute-kbd-macro (kbd "f C-a C-k s : <f8> TAB C-g C-g"))
      (pi-compat-wait)
      (should (equal isled--filter "s:closed"))
      (should-not isled-filter-active)
      (when (getenv "PI_FALLBACK")
        (should (eq isled-filter-interface 'minibuffer-suggestions))))))

(run-at-time
 12 nil
 (lambda ()
   (with-temp-file (getenv "PI_RESULT")
     (prin1 (list :timeout t :selected (buffer-name (window-buffer (selected-window)))
                  :messages (with-current-buffer "*Messages*" (buffer-string))
                  :minibuffer (with-current-buffer (window-buffer (minibuffer-window))
                                (buffer-string))
                  :debug (when (get-buffer "*Backtrace*")
                           (with-current-buffer "*Backtrace*" (buffer-string))))
            (current-buffer)))
   (kill-emacs 2)))

(run-at-time
 0.1 nil
 (lambda ()
   (let ((stats (ert-run-tests-batch (if (getenv "PI_PICKER")
                                          'isled-filter-native-picker
                                        'isled-filter-foreign-ui-interaction))))
     (with-temp-file (getenv "PI_RESULT")
       (prin1 (list :passed (zerop (ert-stats-completed-unexpected stats))
                    :ui pi-compat-ui
                    :messages (unless (zerop (ert-stats-completed-unexpected stats))
                                (with-current-buffer "*Messages*" (buffer-string))))
              (current-buffer)))
     (kill-emacs (if (zerop (ert-stats-completed-unexpected stats)) 0 1)))))
