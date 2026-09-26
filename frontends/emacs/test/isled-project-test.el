;;; isled-project-test.el --- Project shortcut tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Verify default registration, user ownership, and interactive prefix forwarding.

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'isled-browser)

(ert-deftest isled-project-default-and-user-binding ()
  (let ((isled--setup-complete nil)
        (project-prefix-map (make-sparse-keymap)))
    (isled-setup)
    (should (eq (keymap-lookup project-prefix-map "i") #'isled-open-project))
    (keymap-set project-prefix-map "i" #'ignore)
    (isled-setup)
    (should (eq (keymap-lookup project-prefix-map "i") #'ignore))))

(ert-deftest isled-project-overrides-survive-browser-loading ()
  (let ((isled--setup-complete nil)
        (project-prefix-map (make-sparse-keymap)))
    (isled-setup)
    ;; The documented overrides run after the small registration module loads.
    (keymap-unset project-prefix-map "i" t)
    (keymap-set project-prefix-map "j" #'isled)
    (load "isled-browser" nil t)
    (should-not (keymap-lookup project-prefix-map "i"))
    (should (eq (keymap-lookup project-prefix-map "j") #'isled))))

(ert-deftest isled-project-shortcut-forwards-prefix ()
  (let ((isled--setup-complete nil)
        (project-prefix-map (make-sparse-keymap)) calls)
    (isled-setup)
    (cl-letf (((symbol-function 'isled-open-project)
               (lambda (fresh) (interactive "P") (push fresh calls))))
      (dolist (prefix '(nil (4)))
        (let ((current-prefix-arg prefix))
          (call-interactively (keymap-lookup project-prefix-map "i")))))
    (should (equal (nreverse calls) '(nil (4))))))

(ert-deftest isled-project-generated-autoloads ()
  (require 'loaddefs-gen)
  (let* ((directory (file-name-directory (locate-library "isled")))
         (temporary (make-temp-file "isled-autoloads-" t))
         (autoload-file (expand-file-name "isled-autoloads.el" temporary)))
    (unwind-protect
        (progn
          (dolist (file (directory-files directory t "\\.el\\'"))
            (copy-file file (expand-file-name (file-name-nondirectory file) temporary)))
          (loaddefs-generate temporary autoload-file)
          (dolist (scenario '((nil autoloads) (t autoloads) (nil setup) (t setup)))
            (with-temp-buffer
              (let ((status
                     (call-process
                      (expand-file-name invocation-name invocation-directory)
                      nil t nil "-Q" "--batch" "--eval"
                      (prin1-to-string
                       `(progn
                          (setq load-path ',(cons temporary load-path) load-prefer-newer t)
                          ,(when (car scenario) '(require 'project))
                          ,(if (eq (cadr scenario) 'autoloads)
                               `(load ,autoload-file nil t)
                             `(progn
                                (require 'use-package)
                                (use-package isled
                                  :ensure nil
                                  :commands (isled isled-setup)
                                  :init (isled-setup))))
                          (unless (and (eq (key-binding (kbd "C-x p i"))
                                           'isled-open-project)
                                       (autoloadp (symbol-function 'isled))
                                       (not (featurep 'isled-browser)))
                            (error "Shortcut not ready before browser load"))
                          (require 'use-package)
                          (use-package isled
                            :ensure nil
                            :bind (:map project-prefix-map ("j" . isled)
                                   :map isled-mode-map
                                   ("r" . isled-refresh))
                            :config
                            (keymap-unset project-prefix-map "i" t)
                            (keymap-unset isled-mode-map "g")
                            (keymap-set isled-mode-map
                                        "<remap> <isled-next>"
                                        #'next-line))
                          (unless (and (not (featurep 'isled-browser))
                                       (eq (keymap-lookup isled-mode-map "r")
                                           'isled-refresh)
                                       (not (keymap-lookup isled-mode-map "g")))
                            (error "Mode bindings not ready before browser load"))
                          (with-eval-after-load 'isled-browser
                            (keymap-set isled-mode-map "x"
                                        #'isled-collapse-all))
                          (require 'isled-browser)
                          (isled-setup)
                          (unless (and (not (keymap-lookup project-prefix-map "i"))
                                       (eq (key-binding (kbd "C-x p j"))
                                           'isled)
                                       (eq (keymap-lookup isled-mode-map "r")
                                           'isled-refresh)
                                       (not (keymap-lookup isled-mode-map "g"))
                                       (eq (keymap-lookup isled-mode-map "x")
                                           'isled-collapse-all)
                                       (eq (lookup-key isled-mode-map
                                                       [remap isled-next])
                                           'next-line))
                            (error "Overrides changed after browser load")))))))
                (ert-info ((buffer-string)) (should (equal status 0)))))))
      (delete-directory temporary t))))

(provide 'isled-project-test)
;;; isled-project-test.el ends here
