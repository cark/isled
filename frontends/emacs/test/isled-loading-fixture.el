;;; isled-loading-fixture.el --- Typed controller fixtures  -*- lexical-binding: t; -*-

;;; Commentary:

;; Existing controller tests provide complete typed snapshots.  Adapt those
;; fixtures at the process seam; dedicated loading tests use actual wire data
;; and delayed callbacks.  This adapter is never loaded by the package.

;;; Code:

(require 'isled-browser)

(defun isled-test-graph (snapshot direction)
  "Make independent fixture rows for SNAPSHOT and requested DIRECTION."
  (when direction
    (let* ((rows (vconcat (mapcar
                          (lambda (issue) (make-isled-graph-row :id (isled-issue-id issue) :lane 0))
                          (isled-snapshot-issues snapshot))))
           (plan (isled-graph--index-rows rows (if (> (length rows) 0) 1 0))))
      (make-isled-graph-response :direction direction :hash "0000000000000001" :plan plan))))

(defun isled-test-process (directory request callback)
  "Supply typed controller fixtures for DIRECTORY, REQUEST and CALLBACK."
  (let* ((input (json-parse-string request :object-type 'alist :array-type 'list))
         (snapshot
          (cond
           ((fboundp 'isled--load-snapshot)
            (funcall #'isled--load-snapshot directory))
           ((not (eq isled-snapshot-runner-function
                     #'isled-snapshot--run-process))
            (isled-snapshot-load directory))
           (isled--snapshot isled--snapshot)
           (t (error "Missing typed test fixture"))))
         (response
          (isled-response-create
           :root (isled-snapshot-root snapshot)
           :graph (when-let ((graph (alist-get 'graph input)))
                    (isled-test-graph snapshot (intern (alist-get 'direction graph))))
           :view (unless (equal (alist-get 'mode input) "details") snapshot)
           :view-hash (unless (equal (alist-get 'mode input) "details") "0000000000000001")
           :changes
           (mapcar (lambda (entry)
                     (let* ((id (alist-get 'id entry))
                            (issue (isled-view-find-issue
                                    (isled-snapshot-issues snapshot) id)))
                       (isled-detail-create
                        :id id :hash "0000000000000002"
                        :type (if issue 'issue 'deleted) :issue issue
                        :targets (isled-snapshot-issues snapshot))))
                   (alist-get 'details input)))))
    (cl-letf (((symbol-function 'isled-frontend-decode)
               (lambda (_json) response)))
      (funcall callback (isled-command-result-create :status 0 :stdout "" :stderr "")))))

(provide 'isled-loading-fixture)
;;; isled-loading-fixture.el ends here
