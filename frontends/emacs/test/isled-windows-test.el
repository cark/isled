;;; isled-windows-test.el --- Multiwindow demand tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Real isolated windows exercise independent points, range unions and observer
;; lifetime.  No working Emacs session is involved.

;;; Code:

(require 'isled-view-test)
(require 'isled-loading-test)

(defmacro isled-windows-test--with-view (&rest body)
  "Run BODY with one displayed view containing 250 issue headings."
  (declare (indent 0) (debug t))
  `(save-window-excursion
     (delete-other-windows)
     (let ((isled-windows-chunk-size 8)
           (isled-windows-screen-margin 1))
      (isled-loading-test--with-buffer
       (set-window-buffer (selected-window) (current-buffer))
       (isled-mode)
       (setq isled--snapshot
             (apply #'isled-view-test--open-snapshot
                    (mapcar (lambda (n) (format "%04d" n))
                            (number-sequence 1 250)))
             isled--expanded-ids
             '("0001" "0029" "0030" "0031" "0199" "0200" "0201" "0250")
             isled--selected-id "0030")
       (isled--render)
       ,@body))))

(defun isled-windows-test--point (window id)
  "Position WINDOW at issue ID without selecting it."
  (with-current-buffer (window-buffer window)
    (let ((position (save-excursion
                      (isled-sections-goto-id id)
                      (point))))
      (set-window-point window position)
      (set-window-start window position))))

(ert-deftest isled-windows-union-uses-each-window-point ()
  (isled-windows-test--with-view
   (let ((other (split-window-below)))
     (isled-windows-test--point other "0200")
     (should (equal (isled-windows-nearby)
                    '("0029" "0030" "0031" "0199" "0200" "0201")))
     (should (equal (isled-sections-id-at-point) "0030"))
     (isled-windows-test--point other "0030")
     (should (equal (isled-windows-nearby) '("0029" "0030" "0031"))))))

(ert-deftest isled-windows-hidden-view-has-no-demand ()
  (isled-windows-test--with-view
   (set-window-buffer (selected-window) (get-buffer-create " *window-test-other*"))
   (unwind-protect
       (should-not (isled-windows-nearby))
     (kill-buffer " *window-test-other*"))))

(ert-deftest isled-windows-union-produces-one-deduplicated-batch ()
  (isled-windows-test--with-view
   (let* ((other (split-window-below)) calls
          (isled-process-function
           (lambda (_dir request _callback) (push request calls))))
     (isled-windows-test--point other "0200")
     (isled-loading-request 'details)
     (should (= (length calls) 1))
     (should (equal (mapcar (lambda (entry) (alist-get 'id entry))
                            (append (alist-get 'details
                                               (json-parse-string (car calls) :object-type 'alist)) nil))
                    '("0029" "0030" "0031" "0199" "0200" "0201")))
     ;; Movement while Rust is running stays coalesced into the existing queue.
     (isled-windows-test--point other "0030")
      (isled-loading-test--idle (current-buffer))
      (should (= (length calls) 1))
      (should-not isled-loading-pending)
      (setq isled-data-view isled--snapshot)
      (isled-session-attach)
      (isled-loading-schedule)
      (isled-windows-test--point other "0200")
      (funcall pre-redisplay-function t)
      ;; All available bodies are already rich; no formatting wakeup is useful.
      (should-not isled-loading-timer))))

(ert-deftest isled-windows-chunks-follow-visible-area-and-resize ()
  (isled-windows-test--with-view
   (let* ((first (selected-window))
          (other (split-window-below 8))
          (isled-windows-chunk-size 1)
          (isled-windows-screen-margin 0))
     (isled-collapse-all)
     (isled-windows-test--point first "0030")
     (isled-windows-test--point other "0200")
     (let ((range (isled-windows--chunk-range first)))
       (window-resize first 2)
       (should (> (cdr (isled-windows--chunk-range first)) (cdr range)))))))

(ert-deftest isled-windows-chunks-stay-stable-within-boundaries ()
  (isled-windows-test--with-view
   (let ((window (selected-window))
         (isled-windows-chunk-size 64))
     (isled-windows-test--point window "0100")
     (let ((range (isled-windows--chunk-range window)))
       (isled-windows-test--point window "0101")
       (should (equal range (isled-windows--chunk-range window)))))))

(ert-deftest isled-windows-chunks-rebuild-membership-and-ignore-collapsed ()
  (isled-windows-test--with-view
   (let ((window (selected-window))
         (isled-windows-chunk-size 32)
         (isled-windows-screen-margin 2))
     (isled-windows-test--point window "0030")
     (should (member "0001" (isled-windows-nearby)))
     (should-not (member "0002" (isled-windows-nearby)))
     (setq isled--snapshot (isled-view-test--open-snapshot "0199" "0200"))
     (isled--render)
     (isled-windows-test--point window "0200")
     (should (equal (isled-windows-nearby) '("0199" "0200")))
     (should (equal (isled-windows--chunk-range window) '(0 . 2)))
     (setq isled--snapshot (isled-view-test--open-snapshot))
     (isled--render)
     (should-not (isled-windows-nearby)))))

(ert-deftest isled-windows-observe-other-window-and-display-changes ()
  (isled-windows-test--with-view
   (let ((buffer (current-buffer)) (notifications 0)
         (other (split-window-below)))
     (isled-windows-track (lambda () (cl-incf notifications)))
     (funcall pre-redisplay-function t)
     (should (= notifications 1))
     (funcall pre-redisplay-function t)
     (should (= notifications 1))
     (isled-windows-test--point other "0200")
     ;; A command can scroll the view while another buffer is current.
     (with-temp-buffer (funcall pre-redisplay-function t))
     (should (= notifications 2))
     (window-resize other -1)
     (funcall pre-redisplay-function t)
     (should (= notifications 3))
     (delete-window other)
     (funcall pre-redisplay-function t)
     (should (= notifications 4))
     (with-temp-buffer
       (set-window-buffer (selected-window) (current-buffer))
       (funcall pre-redisplay-function t)
       (should (= notifications 5))
       (set-window-buffer (selected-window) buffer)
       (funcall pre-redisplay-function t)
       (should (= notifications 6))))))

(ert-deftest isled-windows-observers-end-with-last-registration ()
  (let ((first (generate-new-buffer " *first-view*"))
        (second (generate-new-buffer " *second-view*"))
        (original isled-windows--buffers))
    (unwind-protect
        (progn
          (with-current-buffer first (isled-windows-track #'ignore))
          (with-current-buffer second (isled-windows-track #'ignore))
          (kill-buffer first)
          (should (memq second isled-windows--buffers))
          (should (advice-function-member-p
                   #'isled-windows--changed pre-redisplay-function))
          (with-current-buffer second (fundamental-mode))
          (should (equal original isled-windows--buffers))
          (unless original
            (should-not (advice-function-member-p
                         #'isled-windows--changed pre-redisplay-function))))
      (when (buffer-live-p first) (kill-buffer first))
      (when (buffer-live-p second) (kill-buffer second)))))

(ert-deftest isled-windows-preserves-other-redisplay-functions ()
  (let* ((buffer (generate-new-buffer " *redisplay-owner*"))
         (isled-windows--buffers nil)
         (original-calls 0) (notifications 0)
         (original (lambda (_windows) (cl-incf original-calls)))
         (pre-redisplay-function original))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (isled-windows-track (lambda () (cl-incf notifications)))
            (isled-windows-track (lambda () (cl-incf notifications))))
          (dotimes (_ 5) (funcall pre-redisplay-function t))
          (should (= original-calls 5))
          (should (= notifications 1))
          (kill-buffer buffer)
          (should (eq pre-redisplay-function original))
          (funcall pre-redisplay-function nil)
          (should (= original-calls 6)))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest isled-windows-hidden-pending-batch-does-not-launch ()
  (save-window-excursion
    (isled-loading-test--with-displayed-buffer
     (isled-mode)
     (let* (calls
            (isled-process-function
             (lambda (_dir request callback)
               (setq calls (append calls (list (list request callback)))))))
       (isled-loading-request 'refresh)
       (isled-loading-test--reply (pop calls) 'refresh)
       (isled--toggle-issue)
       (isled-loading-request 'details)
       (isled-loading-request 'details)
       (should (= (length calls) 1))
       (let ((buffer (current-buffer)))
         (with-temp-buffer
           (set-window-buffer (selected-window) (current-buffer))
           (funcall pre-redisplay-function t)
           (with-current-buffer buffer
             (should-not isled-loading-timer)
             (isled-loading-test--reply (pop calls) 'details '("0001"))
             (should-not calls)
             (should-not isled-loading-running)
             (should-not isled-loading-range)
             (should-not isled-loading-timer))
           (set-window-buffer (selected-window) buffer)
           (funcall pre-redisplay-function t))
         (isled-loading-test--idle buffer)
         (should (= (length calls) 1))
         (let ((entry (aref (alist-get 'details (json-parse-string
                                                 (caar calls) :object-type 'alist)) 0)))
           (should (equal (alist-get 'hash entry) "0000000000000002"))))))))

(ert-deftest isled-windows-late-reply-does-not-restore-observers ()
  (let ((buffer (generate-new-buffer " *late-view*")) call
        (original isled-windows--buffers))
    (unwind-protect
        (let ((isled-process-function
               (lambda (_dir request callback) (setq call (list request callback)))))
          (with-current-buffer buffer
            (isled-mode)
            (isled-loading-request 'refresh))
          (kill-buffer buffer)
          (isled-loading-test--reply call 'refresh)
          (should (equal original isled-windows--buffers)))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest isled-windows-response-preserves-both-points ()
  (isled-windows-test--with-view
   (let* ((first (selected-window))
          (other (split-window-below)) call
          (snapshot isled--snapshot)
          (isled-process-function
           (lambda (_dir request callback) (setq call (list request callback)))))
     (isled-windows-test--point other "0200")
     (isled-loading-request 'refresh)
     ;; Selection changes while the asynchronous request is outstanding.
     (select-window other)
     (isled--track-point)
     (cl-letf (((symbol-function 'isled-frontend-decode)
                (lambda (_wire)
                  (isled-response-create
                   :root (isled-snapshot-root snapshot)
                   :graph (isled-test-graph snapshot 'prerequisites)
                   :view-hash "0000000000000001" :view snapshot))))
       (funcall (cadr call) (isled-command-result-create :status 0 :stdout "fixture")))
     (should-not isled--auto-revert-error)
     (should (equal (isled-sections-id-at-point (window-point first)) "0030"))
     (should (equal (isled-sections-id-at-point (window-point other)) "0200")))))

(ert-deftest isled-windows-repeated-view-cleanup-leaves-no-timers ()
  (cl-letf (((symbol-function 'isled-viewport-work-p) (lambda () t)))
  (let ((original-buffers isled-windows--buffers)
        (original-timers (copy-sequence timer-list)))
    (dotimes (_ 5)
      (isled-loading-test--with-displayed-buffer
       (isled-mode)
       (let* (call
              (isled-process-function
               (lambda (_dir request callback) (setq call (list request callback)))))
         (isled-loading-request 'refresh)
         (isled-loading-test--reply call 'refresh)
         (should (timerp isled-loading-timer)))))
    (should (equal original-buffers isled-windows--buffers))
    (should (equal original-timers timer-list)))))

(ert-deftest isled-windows-chunks-cover-two-text-screens-on-each-side ()
  (isled-windows-test--with-view
   (isled-collapse-all)
   (let ((window (selected-window))
         (isled-windows-chunk-size 32)
         (isled-windows-screen-margin 2))
     (isled-windows-test--point window "0100")
     (let* ((height (window-body-height window))
            (first (save-excursion
                     (goto-char (window-start window))
                     (vertical-motion (* -2 height) window)
                     (isled-row-index (isled-row-at))))
            (last (save-excursion
                    (goto-char (window-start window))
                    (vertical-motion (* 3 height) window)
                    (isled-row-index (isled-row-at))))
            (range (isled-windows--chunk-range window)))
       (should (<= (car range) first))
       (should (> (cdr range) last))
       (should (< (- first (car range)) 32))
       (should (<= (- (cdr range) last) 32))))))

(provide 'isled-windows-test)
;;; isled-windows-test.el ends here
