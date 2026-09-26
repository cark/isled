;;; isled-appearance-test.el --- Appearance customization tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Verify the named-face surface and its theme-derived body background.

;;; Code:

(require 'ert)
(require 'isled-browser)

(ert-deftest isled-appearance-exposes-every-rendering-role-as-a-face ()
  (dolist (face '(isled-header-filter-face
                  isled-header-title-face
                  isled-header-directory-face
                  isled-header-count-face
                  isled-warning-face
                  isled-error-face
                  isled-action-face
                  isled-subdued-face
                  isled-target-highlight-face
                  isled-issue-id-face
                  isled-ready-issue-id-face
                  isled-waiting-issue-id-face
                  isled-closed-issue-id-face
                  isled-issue-title-face
                  isled-issue-kind-face
                  isled-issue-kind-bracket-face
                  isled-expanded-body-face
                  isled-ledger-warning-face
                  isled-body-bracket-face
                  isled-panel-rule-face
                  isled-panel-title-face
                  isled-panel-title-background-face
                  isled-waiting-reference-face
                  isled-ready-reference-face
                  isled-closed-reference-face
                  isled-missing-target-reference-face
                  isled-markdown-link-face
                  isled-help-key-face
                  isled-help-delimiter-face
                  isled-help-text-face))
    (should (facep face))))

(ert-deftest isled-appearance-refreshes-body-background-after-theme-changes ()
  (should (memq #'isled--expanded-body-theme-background
                enable-theme-functions))
  (should (memq #'isled--expanded-body-theme-background
                disable-theme-functions)))

(ert-deftest isled-appearance-preserves-direct-body-customization ()
  (let ((old-background
         (face-attribute 'isled-expanded-body-face :background nil nil))
        (old-derived isled--expanded-body-theme-background))
    (unwind-protect
        (progn
          (set-face-attribute 'isled-expanded-body-face nil
                              :background "#123456")
          (setq isled--expanded-body-theme-background nil)
          (isled--expanded-body-theme-background)
          (should (equal
                   (face-attribute 'isled-expanded-body-face
                                   :background nil nil)
                   "#123456")))
      (set-face-attribute 'isled-expanded-body-face nil
                          :background old-background)
      (setq isled--expanded-body-theme-background old-derived))))

(ert-deftest isled-appearance-body-face-precedes-markdown-faces ()
  (let ((text (propertize "body" 'face 'markdown-bold-face)))
    (add-face-text-property 0 (length text)
                            'isled-expanded-body-face nil text)
    (should (equal (get-text-property 0 'face text)
                   '(isled-expanded-body-face markdown-bold-face)))))

(provide 'isled-appearance-test)
;;; isled-appearance-test.el ends here
