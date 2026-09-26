;;; filter-preview-graphical.el --- Real completion preview interaction -*- lexical-binding: t; -*-

;;; Commentary:
;; Private graphical runner; PI_UI selects stock, vertico or corfu.
;;; Code:
(setq load-prefer-newer t native-comp-jit-compilation nil)
(require 'isled-file-visit-test)
(setq isled-test-program (getenv "PI_PROGRAM"))
(defvar isled-preview-ui (intern (or (getenv "PI_UI") "stock")))
(defvar isled-preview-view nil)
(defvar isled-preview-checks 0)
(when (getenv "PI_MANUAL") (setq isled-filter-inline-auto nil))

(pcase isled-preview-ui
  ('vertico (require 'vertico) (vertico-mode 1))
  ('corfu (require 'corfu) (global-corfu-mode 1)
          (setq global-corfu-minibuffer t corfu-auto (and (getenv "PI_MANUAL") t) corfu-auto-prefix 0)))

(defun isled-preview-wait ()
  "Let command-loop display and asynchronous requests settle."
  (interactive)
  (let ((deadline (+ (float-time) 0.5)))
    (while (< (float-time) deadline) (accept-process-output nil 0.01))))

(defun isled-preview-check ()
  "Assert that the highlighted candidate previews without inserting text."
  (interactive)
  (isled-preview-wait)
  (let* ((prompt (window-buffer (minibuffer-window)))
         (outer (or (buffer-local-value 'isled-filter-preview--picker-origin prompt) prompt))
         (before (with-current-buffer outer (minibuffer-contents-no-properties)))
         (candidate (isled-filter-preview--candidate outer)))
    (unless candidate
      (message "Candidate diagnostic: %S"
               (list :checks isled-preview-checks
                     :prompt (buffer-name prompt)
                     :owner (with-current-buffer prompt
                              (isled-filter-display-owner
                               (eq isled-filter-preview--interface 'inline-suggestions)))
                     :completions (when (get-buffer "*Completions*")
                                    (with-current-buffer "*Completions*"
                                      (list :point (point) :text (buffer-string)
                                            :reference completion-reference-buffer))))))
    (should (member candidate '("s:open" "s:closed")))
    (with-current-buffer outer
      (should (equal isled-filter-preview--query candidate)))
    (should (equal (buffer-local-value 'isled--filter isled-preview-view) candidate))
    (should (equal before "s:"))
    (should (= (buffer-local-value 'isled--header-count isled-preview-view)
               (if (equal candidate "s:open") 2 1)))
    (cl-incf isled-preview-checks)))

(defun isled-preview-restore ()
  "Assert that dismissal restores the last valid typed result."
  (interactive)
  (isled-preview-wait)
  (should (equal (minibuffer-contents-no-properties) "s:"))
  (should-not isled-filter-preview--query)
  (should (eq (buffer-local-value 'isled--filter isled-preview-view) 'open)))

(defun isled-preview-closed ()
  "Assert that manual inline completion has not opened or reopened itself."
  (interactive)
  (isled-preview-wait)
  (should-not (isled-filter-inline--visible-p))
  (should-not isled-filter-inline--timer)
  (should-not isled-filter-preview--query))

(defun isled-preview-setup ()
  "Install private test commands without replacing completion navigation."
  (local-set-key (kbd "<f7>") #'isled-preview-closed)
  (local-set-key (kbd "<f8>") #'isled-preview-wait)
  (local-set-key (kbd "<f9>") #'isled-preview-check)
  (local-set-key (kbd "<f10>") #'isled-preview-restore))

(add-hook 'completion-list-mode-hook #'isled-preview-setup)
(when (boundp 'corfu-continue-commands)
  (setq corfu-continue-commands
        (append '(isled-preview-wait isled-preview-check) corfu-continue-commands)))

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
   (condition-case failure
       (progn
         (ert-deftest isled-preview-graphical ()
          (isled-file-visit-test--with-ledger
           (isled root)
           (isled-preview-wait)
           (setq isled-preview-view (current-buffer))
           (let ((minibuffer-setup-hook (cons #'isled-preview-setup minibuffer-setup-hook)))
             (dolist (interface (if (eq isled-preview-ui 'stock)
                                    '(inline-suggestions minibuffer-suggestions)
                                  (list (if (eq isled-preview-ui 'corfu)
                                            'inline-suggestions 'minibuffer-suggestions))))
              (setq isled-filter-interface interface)

             (execute-kbd-macro
              (kbd (pcase isled-preview-ui
                     ('vertico "f C-a C-k s : <f8> <f9> <down> <f9> TAB RET")
                     ('corfu (if (getenv "PI_MANUAL")
                                 "f C-a C-k s : <f8> <f7> TAB <down> <f9> <down> <f9> C-g <f7> TAB <down> <f9> RET RET"
                               "f C-a C-k s : <f8> <down> <f9> <down> <f9> RET RET"))
                     (_ (if (and (getenv "PI_MANUAL") (eq interface 'inline-suggestions))
                            "f C-a C-k s : <f8> <f7> TAB M-v <right> <f9> <right> <f9> q <f7> TAB M-v <right> <f9> RET RET"
                          "f C-a C-k s : <f8> M-v <f9> <right> <f9> RET RET")))))
             (isled-preview-wait)
             (should (member isled--filter '("s:open" "s:closed" "s:open " "s:closed ")))
             (should-not isled-filter-active))
             ;; Picker cancellation restores the outer typed query, including an
             ;; incomplete token whose last valid view must be retained.
             (setq isled-filter-interface 'separate-filter-picker
                   isled--filter 'open)
             (execute-kbd-macro
              (kbd (if (eq isled-preview-ui 'vertico)
                       "f C-a C-k s : <f8> TAB <f8> <f9> <down> <f9> C-g <f10> C-g"
                     "f C-a C-k s : <f8> TAB <f8> M-v <f9> <right> <f9> q C-g <f10> C-g")))
             (isled-preview-wait)
             (should-not isled-filter-active))))
         (let ((stats (ert-run-tests-batch 'isled-preview-graphical)))
           (should (zerop (ert-stats-completed-unexpected stats))))
         (with-temp-file (getenv "PI_RESULT")
           (prin1 (list :passed t :ui isled-preview-ui :checks isled-preview-checks) (current-buffer)))
         (kill-emacs 0))
     ((error quit)
      (with-temp-file (getenv "PI_RESULT") (prin1 (list failure (with-current-buffer "*Messages*" (buffer-string))) (current-buffer)))
      (kill-emacs 1)))))
