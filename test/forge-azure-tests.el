;;; forge-azure-tests.el --- Tests for forge-azure  -*- lexical-binding:t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Offline tests; no API requests are made.

;;; Code:

(require 'ert)
(require 'forge-azure)

(ert-deftest forge-azure-split-url ()
  (dolist (url '("https://enbw@dev.azure.com/enbw/AOP/_git/somerepo"
                 "https://dev.azure.com/enbw/AOP/_git/somerepo"
                 "git@ssh.dev.azure.com:v3/enbw/AOP/somerepo"
                 "ssh://git@ssh.dev.azure.com/v3/enbw/AOP/somerepo"))
    (should (equal (forge--split-forge-url url)
                   '("dev.azure.com" "enbw/AOP" "somerepo"))))
  ;; Other forges must be unaffected.
  (should (equal (forge--split-forge-url "git@github.com:magit/forge.git")
                 '("github.com" "magit" "forge"))))

(ert-deftest forge-azure-url-formats ()
  (let ((repo (forge-azure-repository
               :owner "org/proj" :name "repo"
               :githost "dev.azure.com" :apihost "dev.azure.com"
               :forge "dev.azure.com"))
        (spec '((?i . "42") (?r . "rev") (?f . "dir/file.py"))))
    (should (equal (forge--format repo 'remote-url-format spec)
                   "https://dev.azure.com/org/proj/_git/repo"))
    (should (equal (forge--format repo 'pullreq-url-format spec)
                   "https://dev.azure.com/org/proj/_git/repo/pullrequest/42"))
    (should (equal (forge--format repo 'blob-url-format spec)
                   "https://dev.azure.com/org/proj/_git/repo?path=/dir/file.py&version=GBrev"))
    (should (equal (forge--format-resource
                    repo "/:owner/_apis/git/repositories/:name/pullrequests")
                   "/org/proj/_apis/git/repositories/repo/pullrequests"))))

(ert-deftest forge-azure-repository-ids-stub ()
  (pcase-let ((`(,id . ,their-id)
               (forge--repository-ids 'forge-azure-repository
                                      "dev.azure.com" "org/proj" "repo" t)))
    (should (equal their-id "org/proj/repo"))
    (should (equal (base64-decode-string id) "dev.azure.com:org/proj/repo"))))

(defmacro forge-azure-tests--with-db (&rest body)
  "Run BODY with `forge-database-file' bound to a fresh temporary db."
  `(let ((forge-database-file (make-temp-file "forge-azure-test" nil ".sqlite")))
     (unwind-protect
         (progn ,@body)
       (when-let* ((db (closql-db 'forge-database t)))
         (emacsql-close db))
       (delete-file forge-database-file))))

(defconst forge-azure-tests--pullreq
  '((pullRequestId . 303411)
    (status . "active")
    (isDraft . nil)
    (title . "Test PR")
    (description . "A body\nwith lines")
    (creationDate . "2026-07-07T12:35:22.1359614Z")
    (createdBy . ((uniqueName . "author@example.com")
                  (displayName . "Author")
                  (id . "39216cd6-0000-0000-0000-000000000001")))
    (sourceRefName . "refs/heads/feature/x")
    (targetRefName . "refs/heads/main")
    (lastMergeSourceCommit . ((commitId . "a856468d43ed")))
    (lastMergeTargetCommit . ((commitId . "c959d870f569")))
    (reviewers . (((uniqueName . "rev@example.com")
                   (displayName . "Reviewer")
                   (id . "5354a36e-0000-0000-0000-000000000002")
                   (vote . 10))))
    (details . t)
    (threads . (((id . 1963476)
                 (isDeleted . nil)
                 (lastUpdatedDate . "2026-07-08T10:43:47.74Z")
                 (comments . (((id . 1)
                               (parentCommentId . 0)
                               (commentType . "system")
                               (content . "Policy status has been updated")
                               (author . ((uniqueName . "svc@x")))
                               (publishedDate . "2026-07-08T10:43:47.74Z")
                               (lastUpdatedDate . "2026-07-08T10:43:47.74Z")))))
                ((id . 1963720)
                 (isDeleted . nil)
                 (lastUpdatedDate . "2026-07-09T11:52:15.153Z")
                 (comments . (((id . 1)
                               (parentCommentId . 0)
                               (commentType . "text")
                               (content . "Looks good")
                               (author . ((uniqueName . "rev@example.com")))
                               (publishedDate . "2026-07-09T11:52:15.153Z")
                               (lastUpdatedDate . "2026-07-09T11:52:15.153Z"))
                              ((id . 2)
                               (parentCommentId . 1)
                               (commentType . "text")
                               (content . "Thanks")
                               (author . ((uniqueName . "author@example.com")))
                               (publishedDate . "2026-07-09T12:00:00Z")
                               (lastUpdatedDate . "2026-07-09T12:00:00Z"))))))))
  "A pull-request as returned by the API, with threads stitched in.")

(ert-deftest forge-azure-update-pullreq ()
  (forge-azure-tests--with-db
   (pcase-let*
       ((`(,id . ,their-id)
         (forge--repository-ids 'forge-azure-repository
                                "dev.azure.com" "org/proj" "repo" t))
        (repo (forge-azure-repository
               :id id :forge-id their-id :forge "dev.azure.com"
               :owner "org/proj" :name "repo"
               :apihost "dev.azure.com" :githost "dev.azure.com"
               :remote "origin")))
     (closql-insert (forge-db) repo t)
     (forge--update-pullreqs repo (list forge-azure-tests--pullreq))
     (let ((pullreq (forge-get-pullreq repo 303411)))
       (should pullreq)
       (should (eq (oref pullreq state) 'open))
       (should (equal (oref pullreq slug) "!303411"))
       (should (equal (oref pullreq author) "author@example.com"))
       (should (equal (oref pullreq base-ref) "main"))
       (should (equal (oref pullreq head-ref) "feature/x"))
       (should (equal (oref pullreq base-rev) "c959d870f569"))
       (should (equal (oref pullreq head-rev) "a856468d43ed"))
       (should-not (oref pullreq cross-repo-p))
       (should-not (oref pullreq draft-p))
       ;; Updated approximated from the most recent thread activity.
       (should (equal (oref pullreq updated) "2026-07-09T11:52:15.153Z"))
       ;; System comments are skipped; text comments are flattened
       ;; with number = thread-id * 1000 + comment-id.
       (let ((posts (oref pullreq posts)))
         (should (= (length posts) 2))
         (should (equal (mapcar (lambda (p) (oref p number)) posts)
                        '(1963720001 1963720002)))
         (should (equal (oref (car posts) body) "Looks good")))
       ;; Reviewers become review-requests backed by assignee rows.
       (should (equal (mapcar #'cadr (oref pullreq review-requests))
                      '("rev@example.com")))
       (should (= (length (oref repo assignees)) 2)))
     ;; Completing the pull-request updates state and the watermark.
     (let ((data (copy-alist forge-azure-tests--pullreq)))
       (setf (alist-get 'status data) "completed")
       (setf (alist-get 'closedDate data) "2026-07-10T00:00:00Z")
       (forge--update-pullreqs repo (list data))
       (let ((pullreq (forge-get-pullreq repo 303411)))
         (should (eq (oref pullreq state) 'merged))
         (should (equal (oref pullreq merged) "2026-07-10T00:00:00Z")))
       (should (equal (oref repo pullreqs-until) "2026-07-10T00:00:00Z"))))))

(ert-deftest forge-azure-merge-method-mapping ()
  ;; All symbols offered by the advised `forge-select-merge-method'
  ;; must be handled by `forge--merge-pullreq'.
  (dolist (method '(merge squash rebase rebase-merge))
    (should (member (pcase-exhaustive method
                      ('merge        "noFastForward")
                      ('squash       "squash")
                      ('rebase       "rebase")
                      ('rebase-merge "rebaseMerge"))
                    '("noFastForward" "squash" "rebase" "rebaseMerge")))))

(ert-deftest forge-azure-entra-expiry ()
  ;; A numeric `expires_on' takes precedence over `expiresOn'.
  (should (= (forge-azure--entra-expiry '((expires_on . 1700003600)
                                          (expiresOn . "1970-01-01 00:00:00")))
             1700003600))
  ;; The `expiresOn' string is a local time with a fraction.
  (let* ((time 1700000000)
         (str (format-time-string "%Y-%m-%d %H:%M:%S.123456" time)))
    (should (= (forge-azure--entra-expiry `((expiresOn . ,str))) time)))
  ;; Garbage or missing expiry falls back to now plus the margin.
  (dolist (data '(nil
                  ((expires_on . "not-a-number"))
                  ((expiresOn . "garbage"))))
    (let ((now (float-time))
          (expiry (forge-azure--entra-expiry data)))
      (should (<= now expiry (+ (float-time)
                                forge-azure--entra-refresh-margin))))))

(ert-deftest forge-azure-entra-token-cache ()
  (let ((forge-azure--entra-tokens (make-hash-table :test #'equal))
        (calls 0))
    (cl-letf (((symbol-function 'forge-azure--entra-acquire-token)
               (lambda ()
                 (cl-incf calls)
                 (cons (format "TOK%d" calls) (+ (float-time) 3600)))))
      (should (equal (forge-azure--entra-token "dev.azure.com") "TOK1"))
      ;; The second request for the same host hits the cache.
      (should (equal (forge-azure--entra-token "dev.azure.com") "TOK1"))
      (should (= calls 1))
      ;; A different host acquires its own token.
      (should (equal (forge-azure--entra-token "other.example.com") "TOK2"))
      (should (= calls 2))
      ;; A token expiring within the refresh margin is re-acquired.
      (puthash "dev.azure.com" (cons "STALE" (+ (float-time) 100))
               forge-azure--entra-tokens)
      (should (equal (forge-azure--entra-token "dev.azure.com") "TOK3"))
      (should (= calls 3)))))

(ert-deftest forge-azure-headers-dispatch ()
  (let ((forge-azure-auth 'entra))
    (cl-letf (((symbol-function 'forge-azure--entra-token)
               (lambda (_host) "TOK")))
      (should (equal (forge-azure--headers "dev.azure.com")
                     '(("Authorization" . "Bearer TOK"))))))
  (let ((forge-azure-auth 'pat))
    (cl-letf (((symbol-function 'ghub--username)
               (lambda (&rest _) "tester"))
              ((symbol-function 'ghub--token)
               (lambda (&rest _) "SECRET")))
      (should (equal (forge-azure--headers "dev.azure.com")
                     `(("Authorization"
                        . ,(concat "Basic "
                                   (base64-encode-string "tester:SECRET"
                                                         t))))))))
  (let ((forge-azure-auth 'bogus))
    (should-error (forge-azure--headers "dev.azure.com"))))

(ert-deftest forge-azure-entra-errors ()
  ;; Missing az executable.
  (cl-letf (((symbol-function 'executable-find) (lambda (_) nil)))
    (should-error (forge-azure--entra-acquire-token) :type 'user-error))
  ;; Nonzero exit propagates az's stderr, including its login hint.
  (let ((forge-azure-az-login nil))
    (cl-letf (((symbol-function 'executable-find) (lambda (_) "/usr/bin/az"))
              ((symbol-function 'call-process)
               (lambda (_program _infile dest _display &rest _args)
                 (with-temp-file (cadr dest)
                   (insert "ERROR: Please run 'az login' to setup account."))
                 1)))
      (let ((err (should-error (forge-azure--entra-acquire-token)
                               :type 'user-error)))
        (should (string-match-p "az login" (cadr err))))))
  ;; Output that is not JSON.
  (cl-letf (((symbol-function 'executable-find) (lambda (_) "/usr/bin/az"))
            ((symbol-function 'call-process)
             (lambda (_program _infile dest _display &rest _args)
               (with-current-buffer (car dest)
                 (insert "not json"))
               0)))
    (should-error (forge-azure--entra-acquire-token) :type 'user-error)))

(ert-deftest forge-azure-az-login-retry ()
  ;; A confirmed prompt runs "az login" once and retries.
  (let ((forge-azure-az-login 'ask)
        (noninteractive nil)
        (logins 0)
        (logged-in nil))
    (cl-letf (((symbol-function 'executable-find) (lambda (_) "/usr/bin/az"))
              ((symbol-function 'y-or-n-p) (lambda (_) t))
              ((symbol-function 'call-process)
               (lambda (_program _infile dest _display &rest args)
                 (cond ((equal (car args) "login")
                        (cl-incf logins)
                        (setq logged-in t)
                        0)
                       (logged-in
                        (with-current-buffer (car dest)
                          (insert "{\"accessToken\": \"TOK\", \
\"expires_on\": 1700003600}"))
                        0)
                       (t
                        (with-temp-file (cadr dest)
                          (insert "ERROR: Please run 'az login' \
to setup account."))
                        1)))))
      (should (equal (forge-azure--entra-acquire-token)
                     '("TOK" . 1700003600)))
      (should (= logins 1)))))

(ert-deftest forge-azure-az-login-declined ()
  (cl-letf (((symbol-function 'executable-find) (lambda (_) "/usr/bin/az"))
            ((symbol-function 'call-process)
             (lambda (_program _infile dest _display &rest args)
               (when (equal (car args) "login")
                 (error "Unexpected az login"))
               (with-temp-file (cadr dest)
                 (insert "ERROR: Please run 'az login' to setup account."))
               1)))
    ;; Declining the prompt signals the original error.
    (let ((forge-azure-az-login 'ask)
          (noninteractive nil))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) nil)))
        (should-error (forge-azure--entra-acquire-token) :type 'user-error)))
    ;; nil neither prompts nor logs in.
    (let ((forge-azure-az-login nil))
      (cl-letf (((symbol-function 'y-or-n-p)
                 (lambda (_) (error "Unexpected prompt"))))
        (should-error (forge-azure--entra-acquire-token)
                      :type 'user-error)))
    ;; In noninteractive sessions `ask' neither prompts nor logs in.
    (let ((forge-azure-az-login 'ask)
          (noninteractive t))
      (cl-letf (((symbol-function 'y-or-n-p)
                 (lambda (_) (error "Unexpected prompt"))))
        (should-error (forge-azure--entra-acquire-token)
                      :type 'user-error)))))

(ert-deftest forge-azure-az-login-no-second-retry ()
  ;; A successful login whose retry still fails logs in only once.
  (let ((forge-azure-az-login t)
        (logins 0))
    (cl-letf (((symbol-function 'executable-find) (lambda (_) "/usr/bin/az"))
              ((symbol-function 'call-process)
               (lambda (_program _infile dest _display &rest args)
                 (if (equal (car args) "login")
                     (progn (cl-incf logins) 0)
                   (with-temp-file (cadr dest)
                     (insert "ERROR: Please run 'az login' \
to setup account."))
                   1))))
      (should-error (forge-azure--entra-acquire-token) :type 'user-error)
      (should (= logins 1)))))

(ert-deftest forge-azure-az-login-unrelated-error ()
  ;; Failures whose stderr lacks the login hint never trigger a login.
  (let ((forge-azure-az-login t))
    (cl-letf (((symbol-function 'executable-find) (lambda (_) "/usr/bin/az"))
              ((symbol-function 'call-process)
               (lambda (_program _infile dest _display &rest args)
                 (when (equal (car args) "login")
                   (error "Unexpected az login"))
                 (with-temp-file (cadr dest)
                   (insert "ERROR: The subscription is disabled."))
                 1)))
      (should-error (forge-azure--entra-acquire-token) :type 'user-error))))

(ert-deftest forge-azure-az-login-failure ()
  ;; A failing "az login" propagates its stderr.
  (let ((forge-azure-az-login t))
    (cl-letf (((symbol-function 'executable-find) (lambda (_) "/usr/bin/az"))
              ((symbol-function 'call-process)
               (lambda (_program _infile dest _display &rest args)
                 (with-temp-file (cadr dest)
                   (insert (if (equal (car args) "login")
                               "ERROR: authentication canceled"
                             "ERROR: Please run 'az login' to setup account.")))
                 1)))
      (let ((err (should-error (forge-azure--entra-acquire-token)
                               :type 'user-error)))
        (should (string-match-p "az login failed" (cadr err)))))))

(provide 'forge-azure-tests)
;;; forge-azure-tests.el ends here
