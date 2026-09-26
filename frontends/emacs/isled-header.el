;;; isled-header.el --- Issue view identity header  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Keywords: tools

;;; Commentary:

;; Pure directory disambiguation and width-aware header presentation.  Unlike
;; Uniquify, this does not rename buffers or manage file-visiting identities.

;;; Code:

(require 'seq)
(require 'subr-x)
(require 'isled-filter-query)
(require 'isled-presentation)

(defun isled-header-mode-line (text)
  "Convert styled TEXT to mode-line data, preserving faces and literal percent."
  (let ((position 0) (segments (list "")))
    (while (< position (length text))
      (let ((end (next-property-change position text (length text))))
        (push (list :propertize
                    (string-replace "%" "%%" (substring-no-properties text position end))
                    'face (get-text-property position 'face text)
                    'help-echo (get-text-property position 'help-echo text)
                    'keymap (get-text-property position 'keymap text)
                    'mouse-face (get-text-property position 'mouse-face text))
              segments)
        (setq position end)))
    (nreverse segments)))

(defun isled-header-directory (root roots)
  "Return the shortest suffix distinguishing ROOT from other ROOTS."
  (let* ((path (directory-file-name root))
         (parts (split-string path "/" t))
         (others (delete path (mapcar #'directory-file-name roots)))
         (depth 1)
         (label (or (car (last parts)) "/")))
    (while (and (< depth (length parts))
                (seq-some (lambda (other)
                            (or (equal label other)
                                (string-suffix-p (concat "/" label) other)))
                          others))
      (setq depth (1+ depth)
            label (string-join (last parts depth) "/")))
    (if (seq-some (lambda (other)
                    (string-suffix-p (concat "/" label) other)) others)
        path
      label)))

(defun isled-header--truncate (text width)
  "Truncate TEXT to positive WIDTH, or return an empty string."
  (if (<= width 0) "" (truncate-string-to-width text width nil nil "…")))

(defun isled-header-format (directory filter count width help diagnostic &optional ledger)
  "Fit DIRECTORY, FILTER and COUNT to WIDTH, retaining HELP and DIAGNOSTIC.
Shorten the path before search text, keeping some search visible when possible.
When LEDGER differs from the selected directory, show its shared destination."
  (let* ((width (max 0 width))
         (room (max 0 (- width (string-width help) 1)))
         (path (or (get-text-property 0 'help-echo directory) directory))
         (base (if (equal (directory-file-name path) "/") "/"
                 (file-name-nondirectory (directory-file-name path))))
         (title (if ledger (format "Isled → %s · " (abbreviate-file-name ledger))
                  "Isled · "))
         (count (format " · %d " count))
         (query (string-trim (isled-filter-query-text filter)))
         (search (concat "[" query "]"))
         (label (directory-file-name path)))
    (when (> (+ (string-width title) (string-width label)
                (string-width count) (string-width search)) room)
      (setq label base))
    (let ((minimum (min 6 (string-width search))))
      (when (> (+ (string-width title) (string-width label)
                  (string-width count) minimum) room)
        (setq title ""))
      (when (> (+ (string-width label) (string-width count) minimum) room)
        (setq count " "))
      (setq label (isled-header--truncate
                   label (- room (string-width title) (string-width count) minimum))))
    (let* ((budget (max 0 (- room (string-width title) (string-width label)
                              (string-width count))))
           (search (if (<= (string-width search) budget) search
                     (if (< budget 3) (truncate-string-to-width search budget)
                       (concat "[" (isled-header--truncate query (- budget 2)) "]"))))
           (left (if diagnostic
                     (propertize (isled-header--truncate diagnostic room)
                                 'face (get-text-property 0 'face diagnostic)
                                 'help-echo (substring-no-properties diagnostic))
                   (concat (propertize title 'face 'isled-header-title-face)
                           (propertize label 'face 'isled-header-directory-face
                                       'help-echo (if ledger (format "Context: %s\nLedger: %s/.issues" path ledger) path))
                           (propertize count 'face 'isled-header-count-face)
                           (propertize search 'face 'isled-header-filter-face
                                       'help-echo query)))))
      (if (<= width (string-width help)) (truncate-string-to-width help width)
        (concat left (make-string (max 1 (- width (string-width left) (string-width help))) ?\s)
                help)))))

(provide 'isled-header)
;;; isled-header.el ends here
