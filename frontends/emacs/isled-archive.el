;;; isled-archive.el --- Extract verified release executables -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sacha De Vos
;; SPDX-License-Identifier: MIT
;; Author: Sacha De Vos
;; Assisted-by: Codex:GPT-6
;; Keywords: tools

;;; Commentary:
;; Read only the two regular members produced by release staging; never extract paths.

;;; Code:

(require 'cl-lib)
(require 'isled-release)

(declare-function zlib-decompress-region "decompress.c" (start end &optional allow-partial))
(declare-function zlib-available-p "decompress.c" ())

(cl-defstruct (isled-archive (:constructor isled-archive--create))
  "Verified executable and accompanying license from a release archive."
  executable license)

(defun isled-archive--inflate (bytes)
  "Decompress gzip BYTES using Emacs, without an external program."
  (unless (and (fboundp 'zlib-available-p) (zlib-available-p))
    (error "This Emacs needs built-in zlib support for Isled downloads"))
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert bytes)
    (unless (zlib-decompress-region (point-min) (point-max))
      (error "Invalid compressed Isled archive"))
    (buffer-string)))

(defun isled-archive--number (bytes start count)
  "Read COUNT little-endian bytes at START in BYTES."
  (let ((value 0))
    (dotimes (index count)
      (setq value (logior value (ash (aref bytes (+ start index)) (* 8 index)))))
    value))

(defun isled-archive--tar (bytes)
  "Return the two regular member names and contents of USTAR BYTES."
  (let ((position 0) entries)
    (dotimes (_ 2)
      (let* ((header (substring bytes position (+ position 512)))
             (name (car (split-string (substring header 0 100) "\0")))
             (size-text (string-trim (substring header 124 136) "[ \0]+" "[ \0]+"))
             (checksum (string-to-number (substring header 148 156) 8))
             (sum (+ (cl-loop for index from 0 below 148 sum (aref header index))
                     (* 8 32) (cl-loop for index from 156 below 512 sum (aref header index)))))
        (unless (and (equal (substring header 257 263) "ustar\0")
                     (memq (aref header 156) '(0 48))
                     (string-match-p "\\`[0-7]+\\'" size-text)
                     (= checksum sum)
                     (string-match-p "\\`\0*\\'" (substring header 157 257))
                     (string-match-p "\\`\0*\\'" (substring header 345 500)))
          (error "Unexpected Isled tar header or special file"))
        (let* ((size (string-to-number size-text 8)) (start (+ position 512))
               (end (+ start size)))
          (push (cons name (substring bytes start end)) entries)
          (setq position (+ start (* 512 (/ (+ size 511) 512)))))))
    (unless (and (<= (+ position 1024) (length bytes))
                 (zerop (% (length bytes) 512))
                 (string-match-p "\\`\0+\\'" (substring bytes position)))
      (error "Unexpected trailing Isled tar members"))
    entries))

(defun isled-archive--zip-member (bytes offset)
  "Read a regular central-directory entry at OFFSET in ZIP BYTES.
Return its name, content, next directory offset and local member end."
  (let* ((flags (isled-archive--number bytes (+ offset 8) 2))
         (method (isled-archive--number bytes (+ offset 10) 2))
         (size (isled-archive--number bytes (+ offset 24) 4))
         (compressed (isled-archive--number bytes (+ offset 20) 4))
         (length (isled-archive--number bytes (+ offset 28) 2))
         (name (substring bytes (+ offset 46) (+ offset 46 length)))
         (local (isled-archive--number bytes (+ offset 42) 4))
         (start (+ local 30 length))
         (end (+ start compressed)))
    (unless (and (equal (substring bytes offset (+ offset 4)) "PK\1\2")
                 (= (aref bytes (+ offset 5)) 3) (= flags 0) (= method 8)
                 (< size (* 128 1024 1024))
                 (= (logand (isled-archive--number bytes (+ offset 38) 4) #xf0000000) #x80000000)
                 (zerop (isled-archive--number bytes (+ offset 30) 6))
                 (equal (substring bytes local (+ local 4)) "PK\3\4")
                 (equal (substring bytes (+ local 6) (+ local 26))
                        (substring bytes (+ offset 8) (+ offset 28)))
                 (= (isled-archive--number bytes (+ local 26) 2) length)
                 (zerop (isled-archive--number bytes (+ local 28) 2))
                 (equal (substring bytes (+ local 30) start) name))
      (error "Unexpected Isled ZIP entry or special file"))
    ;; ZIP deflate and gzip share the compressed stream.  Supply a gzip envelope
    ;; with ZIP's CRC and size so built-in zlib validates both without unzip.
    (let ((content (isled-archive--inflate
                    (concat (unibyte-string 31 139 8 0 0 0 0 0 0 255)
                            (substring bytes start end)
                            (substring bytes (+ offset 16) (+ offset 20))
                            (substring bytes (+ offset 24) (+ offset 28))))))
      (unless (= (length content) size) (error "Isled ZIP size mismatch"))
      (list name content (+ offset 46 length) local end))))

(defun isled-archive--zip (bytes)
  "Return exactly two regular members from the staging format in ZIP BYTES."
  (let* ((end (- (length bytes) 22))
         (offset (isled-archive--number bytes (+ end 16) 4))
         (directory offset) (local 0) entries)
    (unless (and (equal (substring bytes end (+ end 4)) "PK\5\6")
                 (zerop (isled-archive--number bytes (+ end 4) 4))
                 (= (isled-archive--number bytes (+ end 8) 2) 2)
                 (= (isled-archive--number bytes (+ end 10) 2) 2)
                 (zerop (isled-archive--number bytes (+ end 20) 2))
                 (= (+ offset (isled-archive--number bytes (+ end 12) 4)) end))
      (error "Unexpected Isled ZIP directory"))
    (dotimes (_ 2)
      (pcase-let ((`(,name ,content ,next ,start ,finish) (isled-archive--zip-member bytes offset)))
        (unless (= start local) (error "Overlapping or hidden Isled ZIP members"))
        (push (cons name content) entries)
        (setq offset next local finish)))
    (unless (and (= offset end) (= local directory)) (error "Unexpected Isled ZIP contents"))
    entries))

(defun isled-archive-read (bytes release)
  "Verify archive BYTES against RELEASE, returning the executable and license."
  (isled-release-verify bytes (isled-release-archive-hash release) (isled-release-archive-size release))
  (let* ((entries (condition-case nil
                     (if (string-suffix-p ".zip" (isled-release-archive release))
                      (isled-archive--zip bytes)
                    (when (> (isled-archive--number bytes (- (length bytes) 4) 4)
                             (+ (isled-release-size release) (* 128 1024)))
                      (error "Isled tar exceeds the expected unpacked size"))
                    (isled-archive--tar (isled-archive--inflate bytes)))
                   (args-out-of-range (error "Truncated Isled archive"))
                   (wrong-type-argument (error "Malformed Isled archive"))))
         (member (isled-release-member release))
         (license (concat (file-name-directory member) "LICENSE")))
    (unless (equal (sort (mapcar #'car entries) #'string<) (sort (list member license) #'string<))
      (error "Unexpected names or duplicate members in Isled archive"))
    (let ((content (cdr (assoc member entries))))
      (isled-release-verify content (isled-release-hash release) (isled-release-size release))
      (isled-archive--create :executable content :license (cdr (assoc license entries))))))

(provide 'isled-archive)
;;; isled-archive.el ends here
