;;; test-emacs-preview-graphical.el --- Private preview lifecycle -*- lexical-binding: t; -*-

(require 'json)

(let* ((repo (getenv "ISLED_PREVIEW_REPO"))
       (candidate (getenv "ISLED_PREVIEW_CANDIDATE"))
       (profile (or (getenv "ISLED_PREVIEW_TEST_PROFILE") "vanilla"))
       (state-root (expand-file-name "managed-previews" (getenv "TMPDIR")))
       (helper (expand-file-name "scripts/emacs-preview.py" repo))
       (output (generate-new-buffer " *preview-helper-output*"))
       (preview-open nil))
  (unwind-protect
      (condition-case failure
          (progn
            (unless (zerop
                     (apply #'call-process helper nil (list output t) nil
                            (append
                             (list "--state-root" state-root "start"
                                   "--candidate" candidate "--profile" profile
                                   "--repo" repo)
                             (when (getenv "ISLED_PREVIEW_TEST_CONFIG")
                               (list "--config-dir" (getenv "ISLED_PREVIEW_TEST_CONFIG")))
                             (when (getenv "ISLED_PREVIEW_TEST_EMACS")
                               (list "--emacs" (getenv "ISLED_PREVIEW_TEST_EMACS")))
                             (when (getenv "ISLED_PREVIEW_TEST_PROGRAM")
                               (list "--isled"
                                     (getenv "ISLED_PREVIEW_TEST_PROGRAM"))))))
              (error "start failed: %s" (with-current-buffer output (buffer-string))))
            (let* ((started (with-current-buffer output
                              (json-parse-string (buffer-string)
                                                 :object-type 'alist)))
                   (id (alist-get 'id started))
                   (manifest (expand-file-name
                              (format "%s/manifest.json" id) state-root)))
              (setq preview-open t)
              (with-current-buffer output (erase-buffer))
              (unless (zerop
                       (call-process helper nil (list output t) nil
                                     "--state-root" state-root "list"))
                (error "list failed"))
              (unless (string-match-p (regexp-quote id)
                                      (with-current-buffer output (buffer-string)))
                (error "started preview absent from list"))
              (with-current-buffer output (erase-buffer))
              (unless (zerop
                       (call-process helper nil (list output t) nil
                                     "--state-root" state-root "close" id))
                (error "close failed: %s" (with-current-buffer output (buffer-string))))
              (setq preview-open nil)
              (let ((record (json-parse-string
                             (with-temp-buffer
                               (insert-file-contents manifest) (buffer-string))
                             :object-type 'alist)))
                (unless (equal (alist-get 'status record) "closed")
                  (error "manifest was not closed"))
                (let* ((readiness (alist-get 'readiness record))
                       (loaded (alist-get 'loaded_files readiness))
                       (dependencies (alist-get 'dependencies readiness))
                       (view (alist-get 'initial_view readiness))
                       (init-file (alist-get 'user_init_file readiness)))
                  (unless (and (equal (alist-get 'candidate readiness) candidate)
                               (seq-every-p
                                (lambda (file)
                                  (string-prefix-p
                                   (expand-file-name
                                    (format "%s/source/frontends/emacs/" id)
                                    state-root)
                                   file))
                                loaded))
                    (error "candidate files were not verified: %S" readiness))
                  (unless (and (alist-get 'markdown-mode dependencies)
                               (alist-get 'transient dependencies))
                    (error "dependencies were not resolved: %S" dependencies))
                  (unless (and (equal (alist-get 'issue_count view) 2)
                               (alist-get 'refresh_completed view))
                    (error "asynchronous view was not verified: %S" view))
                  (if (equal profile "personal")
                      (unless (and (stringp init-file)
                                   (string-prefix-p
                                    (expand-file-name
                                     (format "%s/home/.emacs.d/" id) state-root)
                                    init-file))
                        (error "personal init was not verified: %S" init-file))
                    (unless (eq init-file :false)
                      (error "vanilla preview loaded an init: %S" init-file)))
                  (dolist (log '("emacs.stdout.log" "emacs.stderr.log"))
                    (let ((attributes
                           (file-attributes
                            (expand-file-name (format "%s/%s" id log) state-root))))
                      (unless (and attributes
                                   (<= (file-attribute-size attributes)
                                       (alist-get 'log_limit_bytes record)))
                        (error "log was absent or unbounded: %s" log))))))
              (when (file-exists-p (expand-file-name (format "%s/ledger" id) state-root))
                (error "disposable ledger survived close"))
              (with-temp-file (getenv "PI_RESULT")
                (prin1 '(:passed t :managed-preview-closed t) (current-buffer)))
              (kill-emacs 0)))
        (error
         (with-temp-file (getenv "PI_RESULT")
           (prin1 (list :passed nil :error failure
                        :output (with-current-buffer output (buffer-string)))
                  (current-buffer)))
         (kill-emacs 1)))
    (when preview-open
      (call-process helper nil nil nil "--state-root" state-root
                    "close" "--all"))
    (when (buffer-live-p output) (kill-buffer output))))

;;; test-emacs-preview-graphical.el ends here
