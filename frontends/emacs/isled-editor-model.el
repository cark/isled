;;; isled-editor-model.el --- Issue draft state and wire boundary -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Assisted-by: Codex:GPT-6
;; Keywords: tools

;;; Commentary:
;; Draft identity and validated editor responses, independent of form rendering.

;;; Code:
(require 'isled-process)
(require 'isled-work-data)

(cl-defstruct (isled-editor-record (:constructor isled-editor-record-create))
  "Saved identity, concurrency baseline and editable fields."
  id path status version source draft work)

(defvar-local isled-editor-closing nil "Non-nil while preparing explicit issue closure.")
(defvar-local isled-editor-closing-overlay nil "Pending status transition display.")

(defvar-local isled-editor-session nil "Shared directory-watch subscription.")
(defvar-local isled-editor-disk-checking nil "Non-nil while checking the saved version.")
(defvar-local isled-editor-disk-again nil "A disk check deferred until the current operation ends.")
(defvar-local isled-editor-disk-error nil "Failure checking the saved version, if any.")
(defvar-local isled-editor-save-failed nil "Non-nil after an unsuccessful explicit save.")
(defvar-local isled-editor-record nil "Last saved record for this draft.")
(defvar-local isled-editor-root nil "Canonical ledger root for this draft.")
(defvar-local isled-editor-origin nil "Ledger buffer from which editing began.")
(defvar-local isled-editor-window nil "Window created to display this editor.")
(defvar-local isled-editor-generation 0 "Generation of authored draft changes.")
(defvar-local isled-editor-busy nil "Non-nil while a save or reload is pending.")
(defvar-local isled-editor-timer nil "Pending background validation timer.")
(defvar-local isled-editor-validating nil "Non-nil during background validation.")
(defvar-local isled-editor-uncertain nil "Non-nil after an uncertain save result.")
(defvar-local isled-editor-conflict nil "Current saved record from a conflict.")
(defvar-local isled-editor-fields nil "Alist of field locators and widgets.")
(defvar-local isled-editor-add-buttons nil "Add-button anchors keyed by list field.")
(defvar-local isled-editor-errors nil "Overlays showing Rust validation errors.")
(defvar-local isled-editor-candidates nil "Issue metadata for draft completion.")
(defvar-local isled-editor-documents nil "Lazy completion documentation buffers.")
(defvar-local isled-editor-active-overlay nil "Current editable field highlight.")

(defun isled-editor-empty-draft ()
  "Return initial values for a new issue draft."
  (copy-tree '((title . "") (kind . "task") (tags . []) (statement . "")
    (evidence . []) (outcome . "Pending.") (waiting_on . []) (blocking . []))))

(defun isled-editor-request (root mode record draft callback &optional close)
  "Send MODE with RECORD baseline and DRAFT to ROOT, then invoke CALLBACK.
CLOSE requests closure with validation/save.
The callback receives a decoded response or an operational-error response."
  (isled-process-command
   root (list "--root" root "editor" "--stdin")
   (json-encode `((schema_version . 3) (mode . ,mode)
                  (id . ,(and record (isled-editor-record-id record)))
                  (expected . ,(and record (isled-editor-record-version record)))
                  (draft . ,draft) (close . ,(if close t :json-false))))
   (lambda (result)
     (funcall callback
              (condition-case failure
                  (progn
                    (unless (zerop (isled-command-result-status result))
                      (error "%s" (isled-command-result-stderr result)))
                    (let ((response (json-parse-string
                                     (isled-command-result-stdout result)
                                     :object-type 'alist :array-type 'array
                                     :null-object nil :false-object :false)))
                      (unless (and (= (or (alist-get 'schema_version response) 0) 3)
                                   (memq (alist-get 'ok response) '(t :false)))
                        (error "Invalid editor response"))
                      (when (alist-get 'record response)
                        (setf (alist-get 'record response)
                              (isled-editor-decode-record (alist-get 'record response)
                                                          (alist-get 'path response))))
                      (when (alist-get 'current response)
                        (setf (alist-get 'current response)
                              (isled-editor-decode-record (alist-get 'current response) nil)))
                      (when-let ((errors (alist-get 'errors response)))
                        (unless (and (vectorp errors)
                                     (seq-every-p (lambda (entry)
                                                    (and (stringp (alist-get 'field entry))
                                                         (stringp (alist-get 'message entry)))) errors))
                          (error "Invalid editor diagnostics")))
                      response))
                (error `((ok . :false) (code . "transport")
                         (errors . [((field . "record")
                                     (message . ,(error-message-string failure)))]))))))))

(defun isled-editor-decode-record (object path)
  "Decode saved record OBJECT with PATH into a draft record."
  (dolist (key '(id status version source))
    (unless (stringp (alist-get key object))
      (error "Missing editor record field: %s" key)))
  (unless (string-match-p "\\`[0-9]\\{4\\}\\'" (alist-get 'id object))
    (error "Invalid editor issue ID"))
  (when (and path (not (and (stringp path) (file-name-absolute-p path))))
    (error "Invalid editor record path"))
  (let ((draft (alist-get 'draft object)))
    (dolist (key '(title kind statement outcome))
      (unless (stringp (alist-get key draft)) (error "Invalid draft field: %s" key)))
    (dolist (key '(tags evidence waiting_on blocking))
      (unless (vectorp (alist-get key draft)) (error "Invalid draft list: %s" key)))
    (dolist (key '(tags evidence))
      (unless (seq-every-p #'stringp (alist-get key draft)) (error "Invalid draft text list")))
    (dolist (key '(waiting_on blocking))
      (unless (seq-every-p (lambda (edge) (and (stringp (alist-get 'id edge))
                                             (stringp (alist-get 'reason edge))))
                          (alist-get key draft)) (error "Invalid draft relations")))
    (isled-editor-record-create
     :id (alist-get 'id object)
     :path (and path (isled-snapshot--file-name path))
     :status (alist-get 'status object)
     :version (alist-get 'version object) :source (alist-get 'source object)
     :draft draft
     :work (isled-work-data-decode (alist-get 'work object) t))))

(provide 'isled-editor-model)
;;; isled-editor-model.el ends here
