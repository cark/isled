;;; isled-graph-fixtures.el --- Shared Rust drawing fixtures -*- lexical-binding: t; -*-

;;; Commentary:
;; Rust verifies these payloads against the independent input graph library.

;;; Code:
(require 'json)
(require 'isled-graph-drawing)
(require 'isled-frontend)

(defconst isled-graph-fixtures--path
  (expand-file-name "../../../tests/fixtures/dependency-drawings.json"
                    (file-name-directory (or load-file-name buffer-file-name))))

(defun isled-graph-fixtures-cases ()
  "Read the complete Rust drawing case library."
  (with-temp-buffer
    (insert-file-contents isled-graph-fixtures--path)
    (json-parse-buffer :object-type 'alist :array-type 'list :null-object :json-null)))

(defun isled-graph-fixtures-decode (wire)
  "Decode semantic and drawing WIRE through the production boundary."
  (let ((plan (isled-graph--decode-plan wire)))
    (setf (isled-graph-plan-drawing plan)
          (isled-graph-drawing-decode (alist-get 'drawing wire) plan))
    plan))

(defun isled-graph-fixtures-wire (name &optional direction)
  "Return the drawing case NAME in DIRECTION, defaulting to prerequisites."
  (alist-get 'plan
             (seq-find (lambda (case) (and (equal (alist-get 'case case) name)
                                          (equal (alist-get 'direction case) (or direction "prerequisites"))))
                       (isled-graph-fixtures-cases))))

(defun isled-graph-fixtures-plan (name &optional direction)
  "Decode drawing case NAME in DIRECTION."
  (isled-graph-fixtures-decode (isled-graph-fixtures-wire name direction)))

(provide 'isled-graph-fixtures)
;;; isled-graph-fixtures.el ends here
