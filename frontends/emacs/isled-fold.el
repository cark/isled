;;; isled-fold.el --- Searchable issue folds  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Assisted-by: Codex:GPT-6
;; Keywords: tools

;;; Commentary:

;; Standard search hooks distinguish a temporary reveal from explicit expansion.
;; Preview changes visibility only; accepting the match invokes normal opening.

;;; Code:

(require 'isled-rows)
(declare-function isled-sections-format "isled-sections" (row))
(declare-function isled-sections-show "isled-sections" (row))

(defun isled-fold-update (row)
  "Match ROW's folding overlay to its current body and expansion state."
  (when (< (isled-row-content row) (isled-row-end row))
    (let ((overlay (or (isled-row-fold row)
                       (setf (isled-row-fold row)
                             (make-overlay (isled-row-content row)
                                           (isled-row-end row) nil t nil)))))
      (move-overlay overlay (isled-row-content row) (isled-row-end row))
      (overlay-put overlay 'isled-row row)
      (overlay-put overlay 'invisible (and (isled-row-hidden row)
                                           (not (overlay-get overlay 'isled-preview)) t))
      (overlay-put overlay 'isearch-open-invisible #'isled-fold-open)
      (overlay-put overlay 'isearch-open-invisible-temporary #'isled-fold-preview))))

(defun isled-fold-open (overlay)
  "Open the issue containing OVERLAY after search accepts a match."
  (when (overlay-buffer overlay)
    (with-current-buffer (overlay-buffer overlay)
      (isled-sections-show (overlay-get overlay 'isled-row)))))

(defun isled-fold-preview (overlay hide)
  "Temporarily reveal OVERLAY, or restore its logical fold when HIDE is non-nil."
  (when (overlay-buffer overlay)
    (unless hide
      (with-current-buffer (overlay-buffer overlay)
        (isled-sections-format (overlay-get overlay 'isled-row))))
    (overlay-put overlay 'isled-preview (not hide))
    (overlay-put overlay 'invisible
                 (and hide (isled-row-hidden
                            (overlay-get overlay 'isled-row)) t))))

(provide 'isled-fold)
;;; isled-fold.el ends here
