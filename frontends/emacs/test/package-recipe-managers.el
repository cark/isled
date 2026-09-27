;;; package-recipe-managers.el --- Native packaging adapters -*- lexical-binding: t; -*-

;;; Commentary:

;; Used only by package-recipes.el in disposable Emacs environments.
;; Recipes retain their file selection; only the source and local test ref vary.

;;; Code:

(require 'cl-lib)
(require 'package)

(defun isled-recipe-read (name)
  "Read the canonical recipe named NAME."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name (concat "frontends/emacs/recipes/" name)
                       (getenv "ISLED_RECIPE_ROOT")))
    (read (current-buffer))))

(defun isled-recipe-ref ()
  "Return the selected fixture ref."
  (pcase (getenv "ISLED_RECIPE_SELECTOR")
    ("branch" "release")
    ("development" "development")
    ("tag" (concat "v" (getenv "ISLED_RECIPE_CLI_PIN")))
    ("commit" (getenv "ISLED_RECIPE_REVISION"))))

(defun isled-recipe-package-setup ()
  "Activate isolated archive dependencies."
  (setq package-directory-list (list (getenv "ISLED_CHECK_PACKAGE_DIR"))
        package-install-upgrade-built-in t
        package-check-signature nil
        package-native-compile nil
        package-archives nil)
  (package-initialize))

(defun isled-recipe-melpa ()
  "Build the MELPA recipe and install its archive; return its source checkout."
  (isled-recipe-package-setup)
  (add-to-list 'load-path (expand-file-name "package-build" (getenv "ISLED_RECIPE_MELPA")))
  (require 'package-build)
  (setq package-build-working-dir (expand-file-name "working" user-emacs-directory)
        package-build-archive-dir (expand-file-name "archive" user-emacs-directory)
        package-build-recipes-dir (expand-file-name "recipes" user-emacs-directory))
  (make-directory package-build-working-dir t)
  (make-directory package-build-recipes-dir t)
  (let ((recipe (isled-recipe-read "melpa/isled")))
    (setcdr recipe (plist-put (cdr recipe) :fetcher 'git))
    (setcdr recipe (cl-loop for (key value) on (cdr recipe) by #'cddr
                           unless (eq key :repo) append (list key value)))
    (setcdr recipe (plist-put (cdr recipe) :url (getenv "ISLED_RECIPE_SOURCE")))
    (setcdr recipe (plist-put (cdr recipe) :branch (isled-recipe-ref)))
    (with-temp-file (expand-file-name "isled" package-build-recipes-dir)
      (prin1 recipe (current-buffer))))
  (package-build-archive "isled" t)
  (let ((archives (directory-files package-build-archive-dir t "\\.tar\\'")))
    (unless (= (length archives) 1) (error "Expected exactly one MELPA tar"))
    (package-install-file (car archives)))
  (expand-file-name "isled" package-build-working-dir))

(defun isled-recipe-package-vc ()
  "Install with package-vc through use-package; return its source checkout."
  (isled-recipe-package-setup)
  (require 'package-vc)
  (require 'use-package)
  (let ((recipe (isled-recipe-read "package-vc.el")))
    (setcdr recipe (plist-put (cdr recipe) :url (getenv "ISLED_RECIPE_SOURCE")))
    ;; :rev :newest is essential: use-package otherwise selects the last release.
    (if (member (getenv "ISLED_RECIPE_SELECTOR") '("branch" "development"))
        (progn
          (setcdr recipe (plist-put (cdr recipe) :branch (isled-recipe-ref)))
          (setcdr recipe (plist-put (cdr recipe) :rev :newest)))
      (setcdr recipe (plist-put (cdr recipe) :rev (isled-recipe-ref))))
    (eval `(use-package isled :vc ,(cdr recipe) :defer t) t))
  (package-desc-dir (cadr (assq 'isled package-alist))))

(defun isled-recipe-elpaca ()
  "Install with Elpaca through use-package; return its source checkout."
  (let ((tool (expand-file-name "elpaca/sources/elpaca" user-emacs-directory)))
    (copy-directory (getenv "ISLED_RECIPE_ELPACA") tool nil t t)
    (add-to-list 'load-path tool)
    (add-to-list 'load-path (expand-file-name "extensions" tool))
    (require 'elpaca)
    (load (elpaca-generate-autoloads "elpaca" tool) nil t))
  (require 'elpaca-use-package)
  (elpaca-use-package-mode)
  ;; Explicit installation upgrades Emacs's bundled Transient.
  (eval '(elpaca transient) t)
  (let ((recipe (isled-recipe-read "elpaca.el")))
    (setcdr recipe (plist-put (cdr recipe) :host nil))
    ;; A plain local path means reuse that checkout; a file URL exercises cloning.
    (setcdr recipe (plist-put (cdr recipe) :repo (getenv "ISLED_RECIPE_SOURCE_URL")))
    (setcdr recipe (plist-put (cdr recipe) :depth nil))
    (if (member (getenv "ISLED_RECIPE_SELECTOR") '("branch" "development"))
        (setcdr recipe (plist-put (cdr recipe) :branch (isled-recipe-ref)))
      (setcdr recipe (cl-loop for (key value) on (cdr recipe) by #'cddr
                             unless (eq key :branch) append (list key value)))
      (setcdr recipe (plist-put (cdr recipe)
                               (if (equal (getenv "ISLED_RECIPE_SELECTOR") "tag") :tag :ref)
                               (isled-recipe-ref))))
    (eval `(use-package isled :ensure ,(cdr recipe) :defer t) t))
  (elpaca-wait)
  (with-temp-file (expand-file-name "elpaca-events.log" user-emacs-directory)
    (dolist (event (reverse elpaca--event-log))
      (prin1 event (current-buffer))
      (insert "\n")))
  (dolist (entry (elpaca--queued))
    (unless (eq (elpaca<-status (cdr entry)) 'finished)
      (error "Elpaca %s failed: %S" (car entry)
             (seq-take (cl-remove-if-not
                        (lambda (event) (eq (elpaca-event<-id event) (car entry)))
                        elpaca--event-log) 5))))
  (elpaca<-source-dir (elpaca-get 'isled)))

(defun isled-recipe-straight ()
  "Install with straight.el through use-package; return its source checkout."
  (setq straight-base-dir user-emacs-directory
        straight-vc-git-default-clone-depth 1
        straight-check-for-modifications nil
        straight-enable-native-compilation nil
        straight-use-package-by-default nil)
  (add-to-list 'load-path (getenv "ISLED_RECIPE_STRAIGHT"))
  (require 'straight)
  (mapc #'straight-use-recipes straight-initial-recipe-repositories)
  (require 'use-package)
  (straight-use-package-mode)
  (straight-use-package '(transient :type git :host github :repo "magit/transient"
                                   :files ("lisp/*.el")))
  (let ((recipe (isled-recipe-read "straight.el")))
    (setcdr recipe (plist-put (cdr recipe) :host nil))
    (setcdr recipe (plist-put (cdr recipe) :repo (getenv "ISLED_RECIPE_SOURCE")))
    (setcdr recipe (plist-put (cdr recipe) :local-repo "isled"))
    (setcdr recipe (plist-put (cdr recipe) :depth 'full))
    (if (member (getenv "ISLED_RECIPE_SELECTOR") '("branch" "development"))
        (setcdr recipe (plist-put (cdr recipe) :branch (isled-recipe-ref)))
      (let ((versions (expand-file-name "straight/versions/default.el" straight-base-dir)))
        (make-directory (file-name-directory versions) t)
        (with-temp-file versions
          (prin1 `(("isled" . ,(getenv "ISLED_RECIPE_REVISION"))) (current-buffer))
          (insert "\n:gamma\n"))))
    (eval `(use-package isled :straight ,recipe :defer t) t))
  (expand-file-name "straight/repos/isled" straight-base-dir))

(provide 'package-recipe-managers)
;;; package-recipe-managers.el ends here
