;;; forge-azure.el --- Azure DevOps support for Forge  -*- lexical-binding:t -*-

;; Copyright (C) 2026 Daniel Kraus

;; Author: Daniel Kraus <daniel@kraus.my>
;; Maintainer: Daniel Kraus <daniel@kraus.my>
;; URL: https://github.com/dakra/forge-azure
;; Keywords: git tools vc
;; Version: 0.2.0
;; Package-Requires: ((emacs "29.1") (forge "0.6.7"))

;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published
;; by the Free Software Foundation, either version 3 of the License,
;; or (at your option) any later version.
;;
;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this file.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Azure DevOps backend for Forge, using the Azure DevOps REST API
;; (api-version 7.1).  Supported: pulling pull-requests with their
;; comments, creating pull-requests, commenting, editing and deleting
;; comments, approving (vote 10) and requesting changes (vote -5),
;; adding and removing reviewers, completing (merging), abandoning
;; and reactivating, and checking out pull-requests locally.
;;
;; The `owner' of a repository is the "{organization}/{project}" pair,
;; whose parts appear separately in remote urls, surrounded by
;; additional path segments, which are not part of the owner.
;;
;; Not supported: work items (Azure's equivalent of issues; they
;; belong to a project, not to a repository), notifications, forking,
;; and checking out pull-requests from forks.
;;
;; Setup:
;;
;;   (with-eval-after-load 'forge (require 'forge-azure))
;;
;;   git config --global azure.user USERNAME
;;
;; By default (`forge-azure-auth' is `entra') requests authenticate
;; with a Microsoft Entra ID access token acquired through the Azure
;; CLI.  When the CLI reports that logging in is required, forge-azure
;; offers to run "az login" for you; `forge-azure-az-login' controls
;; whether that happens after a confirmation prompt (the default),
;; without asking, or never.  In this mode `azure.user' is optional,
;; but recommended so Forge can recognize you in topic lists.
;;
;; Alternatively, with (setq forge-azure-auth 'pat), authenticate
;; with a personal access token (at least "Code Read & Write") from
;; an auth-source entry:
;;
;;   machine dev.azure.com login USERNAME^forge password TOKEN
;;
;; This package necessarily builds on Forge's internal backend
;; interface, which is not a stable API, and additionally advises
;; `forge--split-forge-url', `forge-approve-pullreq',
;; `forge-request-changes' and `forge-select-merge-method'.
;; A Forge update may therefore break it.

;;; Code:

(require 'forge)
(require 'forge-client)
(require 'forge-issue)
(require 'forge-pullreq)

;;; Options

(defgroup forge-azure nil
  "Azure DevOps support for Forge."
  :group 'forge)

(defcustom forge-azure-auth 'entra
  "How to authenticate against Azure DevOps.
`entra' acquires a Microsoft Entra ID access token through the
Azure CLI, running \"az login\" first when needed, as controlled
by `forge-azure-az-login'.
`pat' sends a personal access token from auth-source using basic
authentication."
  :type '(choice (const :tag "Entra ID via Azure CLI" entra)
                 (const :tag "Personal access token" pat)))

(defcustom forge-azure-az-executable "az"
  "Name or path of the Azure CLI executable."
  :type 'string)

(defcustom forge-azure-az-login 'ask
  "Whether to run \"az login\" when no valid Azure CLI login exists.
`ask' prompts for confirmation first, t runs it without asking,
and nil never runs it, leaving logging in to the user.  In
noninteractive sessions `ask' behaves like nil."
  :type '(choice (const :tag "Ask first" ask)
                 (const :tag "Without asking" t)
                 (const :tag "Never" nil)))

;;; Class

(defclass forge-azure-repository (forge-repository)
  ((issues-url-format         :initform "https://%h/%o/_workitems")
   (issue-url-format          :initform "https://%h/%o/_workitems/edit/%i")
   (pullreqs-url-format       :initform "https://%h/%o/_git/%n/pullrequests")
   (pullreq-url-format        :initform "https://%h/%o/_git/%n/pullrequest/%i")
   (pullreq-post-url-format   :initform "https://%h/%o/_git/%n/pullrequest/%i")
   (commit-url-format         :initform "https://%h/%o/_git/%n/commit/%r")
   (branch-url-format         :initform "https://%h/%o/_git/%n?version=GB%r")
   (remote-url-format         :initform "https://%h/%o/_git/%n")
   (blob-url-format           :initform "https://%h/%o/_git/%n?path=/%f&version=GB%r")
   (create-pullreq-url-format :initform "https://%h/%o/_git/%n/pullrequestcreate")
   ;; Azure only advertises `refs/pull/{id}/merge' refs (no "/head").
   ;; Such a ref holds the merge-preview commit and does not exist
   ;; while the pull-request has conflicts.  This is only used as a
   ;; fallback; the source branch is used when possible.
   (pullreq-refspec           :initform "+refs/pull/*/merge:refs/pullreqs/*")))

;;; Registration

(dolist (elt '(("dev.azure.com" "dev.azure.com"
                "dev.azure.com" forge-azure-repository)
               ("ssh.dev.azure.com" "dev.azure.com"
                "dev.azure.com" forge-azure-repository)))
  (add-to-list 'forge-alist elt))

;; `ghub--username' consults this alist to determine whether the
;; `azure.user' Git variable applies to a host.
(unless (alist-get 'azure ghub-default-host-alist)
  (push '(azure . "dev.azure.com") ghub-default-host-alist))

(defun forge-azure--normalize-split-url (ret)
  "Normalize the owner in RET for Azure DevOps remote urls.
Advice for `forge--split-forge-url', whose generic parsing yields
\"{org}/{project}/_git\" or \"v3/{org}/{project}\" as the owner."
  (pcase-let ((`(,host ,owner ,name) ret))
    (if (and owner
             (eq (nth 3 (car (cl-member host forge-alist
                                        :test #'equal :key #'caddr)))
                 'forge-azure-repository))
        (list host
              (string-remove-suffix "/_git" (string-remove-prefix "v3/" owner))
              name)
      ret)))

(advice-add 'forge--split-forge-url :filter-return
            #'forge-azure--normalize-split-url)

;;; Identity

(cl-defmethod ghub--host ((repo forge-azure-repository))
  (forge--host-id (oref repo apihost)))

(cl-defmethod ghub--username ((repo forge-azure-repository))
  ;; Do not use `cl-call-next-method'; the `forge-repository' method
  ;; maps the class to a symbol `ghub' does not know about.
  (let ((default-directory default-directory))
    (unless (forge-repository-equal (forge-get-repository :stub?) repo)
      (when-let* ((worktree (forge-get-worktree repo)))
        (setq default-directory worktree)))
    (ghub--username (forge--host-id (oref repo apihost)) 'azure)))

(cl-defmethod forge--repository-ids ((_class (subclass forge-azure-repository))
                                     host owner name &optional stub noerror)
  (pcase-let* ((`(,_githost ,apihost ,id ,_class)
                (forge--get-forge-host host t))
               (path (format "%s/%s" owner name))
               (their-id (and (not stub)
                              (alist-get 'id
                                         (forge-azure--get nil
                                           (format "/%s/_apis/git/repositories/%s"
                                                   owner name)
                                           nil :host apihost :noerror noerror)))))
    (and (or stub their-id (not noerror))
         (cons (base64-encode-string
                (format "%s:%s" id (if stub path their-id)) t)
               (or their-id path)))))

(defvar forge-azure--user-ids (make-hash-table :test #'equal)
  "Hash table mapping \"APIHOST/ORGANIZATION\" to identity GUIDs.")

(defun forge-azure--user-id (repo)
  "Return the authenticated user's GUID for REPO's organization."
  (let* ((apihost (oref repo apihost))
         (org (car (split-string (oref repo owner) "/")))
         (key (concat apihost "/" org)))
    (or (gethash key forge-azure--user-ids)
        (puthash key
                 (let-alist (forge-azure--get nil
                              (format "/%s/_apis/connectionData" org)
                              nil :host apihost)
                   .authenticatedUser.id)
                 forge-azure--user-ids))))

;;; Pull
;;;; Repository

(cl-defmethod forge--pull ((repo forge-azure-repository)
                           &optional callback since)
  (cl-assert (not (and since (forge-get-repository repo nil :tracked?))))
  (setq forge--mode-line-buffer (current-buffer))
  (forge--msg repo t nil "Pulling REPO")
  (let ((buffer (current-buffer))
        (value nil)
        (step nil)
        (skip (and (oref repo selective-p) '(pullreqs))))
    (named-let step (data)
      (cond ((not value) (when data (setq value data)))
            ((push (cons step data) value)))
      (cl-flet ((fetchp (sym)
                  (unless (or (memq sym skip)
                              (assq sym value))
                    (setq step sym)
                    t)))
        (cond ((not value)         (forge--fetch-repository repo #'step))
              ((fetchp 'pullreqs)  (forge--fetch-pullreqs   repo #'step since))
              (t
               (forge--msg repo t t   "Pulling REPO")
               (forge--msg repo t nil "Storing REPO")
               (let-alist value
                 (closql-with-transaction (forge-db)
                   (forge--update-repository repo value)
                   (forge--update-pullreqs   repo .pullreqs)
                   (oset repo condition :tracked)))
               (forge--msg repo t t "Storing REPO")
               (cond ((oref repo selective-p))
                     (callback (funcall callback))
                     ((forge--maybe-git-fetch repo buffer)))))))))

(cl-defmethod forge--fetch-repository ((repo forge-azure-repository) callback)
  (forge-azure--get repo "/:owner/_apis/git/repositories/:name" nil
    :callback callback))

(cl-defmethod forge--update-repository ((repo forge-azure-repository) data)
  (let-alist data
    (oset repo created        nil)
    (oset repo updated        .project.lastUpdateTime)
    (oset repo pushed         nil)
    (oset repo parent         nil)
    (oset repo description    nil)
    (oset repo homepage       nil)
    (oset repo default-branch (and .defaultBranch
                                   (string-remove-prefix "refs/heads/"
                                                         .defaultBranch)))
    (oset repo archived-p     .isDisabled)
    (oset repo fork-p         (and .isFork t))
    (oset repo locked-p       nil)
    (oset repo mirror-p       nil)
    (oset repo private-p      (equal .project.visibility "private"))
    (oset repo issues-p       nil)
    (oset repo wiki-p         nil)
    (oset repo stars          nil)
    (oset repo watchers       nil)))

;;;; Topics

(cl-defmethod forge--pull-topic ((repo forge-azure-repository) _topic
                                 &key callback _errorback)
  ;; The API cannot return topics that were updated since a certain
  ;; time (only created or closed since), so pull everything.
  (forge--pull repo (or callback #'forge-refresh-buffer)))

;;;; Pullreqs

(cl-defmethod forge--fetch-pullreqs ((repo forge-azure-repository)
                                     callback since)
  (letrec
      (( cb (let (val cur cnt pos)
              (lambda (&optional v)
                (cond
                  ((and (not pos) v)
                   (setq val v)
                   (setq cur v)
                   (setq pos 1)
                   (setq cnt (length val))
                   (forge--msg nil nil nil "Pulling pullreq %s/%s" pos cnt)
                   (funcall cb))
                  ((not pos)
                   (forge--msg repo t t "Pulling REPO pullreqs")
                   (funcall callback val))
                  ((not (assq 'details (car cur)))
                   (forge--fetch-pullreq-details repo cur cb))
                  ((not (assq 'threads (car cur)))
                   (forge--fetch-pullreq-threads repo cur cb))
                  ((setq cur (cdr cur))
                   (cl-incf pos)
                   (forge--msg nil nil nil "Pulling pullreq %s/%s" pos cnt)
                   (funcall cb))
                  (t
                   (forge--msg repo t t "Pulling REPO pullreqs")
                   (funcall callback val)))))))
    (forge--msg repo t nil "Pulling REPO pullreqs")
    (let ((resource "/:owner/_apis/git/repositories/:name/pullrequests")
          (until (or since (oref repo pullreqs-until))))
      (if until
          ;; The API cannot filter by update time.  Get all active
          ;; pull-requests, plus those closed since the last pull.
          (forge-azure--get repo resource
            '((searchCriteria.status . "active"))
            :paginate t
            :callback
            (lambda (active)
              (forge-azure--get repo resource
                `((searchCriteria.status . "all")
                  (searchCriteria.queryTimeRangeType . "closed")
                  (searchCriteria.minTime . ,until))
                :paginate t
                :callback (lambda (closed)
                            (funcall cb (nconc active closed))))))
        (forge-azure--get repo resource
          '((searchCriteria.status . "all"))
          :paginate t
          :callback cb)))))

(cl-defmethod forge--fetch-pullreq-details ((repo forge-azure-repository)
                                            cur cb)
  ;; The list endpoint truncates `description', so each pull-request
  ;; has to be fetched individually.
  (forge-azure--get repo
    (format "/:owner/_apis/git/repositories/:name/pullrequests/%s"
            (alist-get 'pullRequestId (car cur)))
    nil
    :callback (lambda (value)
                (setcar cur (nconc value (list (cons 'details t))))
                (funcall cb))))

(cl-defmethod forge--fetch-pullreq-threads ((repo forge-azure-repository)
                                            cur cb)
  (forge-azure--get repo
    (format "/:owner/_apis/git/repositories/:name/pullRequests/%s/threads"
            (alist-get 'pullRequestId (car cur)))
    nil
    :callback (lambda (value)
                (setf (alist-get 'threads (car cur)) value)
                (funcall cb))))

(cl-defmethod forge--update-pullreqs ((repo forge-azure-repository) data)
  (forge-azure--update-assignees repo data)
  (dolist (v data)
    (forge--update-pullreq repo v)))

(cl-defmethod forge--update-pullreq ((repo forge-azure-repository) data)
  (closql-with-transaction (forge-db)
    (let-alist data
      (let* ((number .pullRequestId)
             (pullreq-id (forge--object-id 'forge-pullreq repo number))
             (base-repo (concat (oref repo owner) "/" (oref repo name)))
             (updated .creationDate)
             (pullreq
              (forge-pullreq
               :id           pullreq-id
               :their-id     number
               :number       number
               :slug         (format "!%s" number)
               :repository   (oref repo id)
               :state        (pcase-exhaustive .status
                               ("active"    'open)
                               ("completed" 'merged)
                               ("abandoned" 'rejected))
               :author       .createdBy.uniqueName
               :title        .title
               :created      .creationDate
               ;; Pull-requests have no update timestamp; approximate
               ;; using the most recent thread activity.
               :updated      (progn
                               (dolist (thread .threads)
                                 (let ((u (alist-get 'lastUpdatedDate thread)))
                                   (when (and u (string> u updated))
                                     (setq updated u))))
                               (when (and .closedDate
                                          (string> .closedDate updated))
                                 (setq updated .closedDate))
                               updated)
               ;; `.closedDate' may be missing even though the
               ;; pull-request is closed.  In such cases use 1, so
               ;; that these slots at least can serve as booleans.
               :closed       (and (member .status '("completed" "abandoned"))
                                  (or .closedDate 1))
               :merged       (and (equal .status "completed")
                                  (or .closedDate 1))
               :draft-p      .isDraft
               :locked-p     nil
               :editable-p   nil
               :cross-repo-p (and .forkSource t)
               :base-ref     (string-remove-prefix "refs/heads/"
                                                   .targetRefName)
               :base-rev     .lastMergeTargetCommit.commitId
               :base-repo    base-repo
               :head-ref     (string-remove-prefix "refs/heads/"
                                                   .sourceRefName)
               :head-rev     .lastMergeSourceCommit.commitId
               :head-user    .forkSource.repository.project.name
               :head-repo    (if .forkSource
                                 (concat (car (split-string (oref repo owner)
                                                            "/"))
                                         "/"
                                         .forkSource.repository.project.name
                                         "/"
                                         .forkSource.repository.name)
                               base-repo)
               :milestone    nil
               :body         (forge--sanitize-string .description))))
        (closql-insert (forge-db) pullreq t)
        (forge--set-connections repo pullreq 'review-requests .reviewers)
        (dolist (thread .threads)
          (let ((thread-id (alist-get 'id thread)))
            (unless (alist-get 'isDeleted thread)
              (dolist (c (alist-get 'comments thread))
                (let-alist c
                  ;; Threads also contain "system" comments, which
                  ;; describe events; those are not stored.  Comment
                  ;; ids are only unique within their thread; encode
                  ;; the thread id into the stored number.
                  (when (and (equal .commentType "text")
                             (not .isDeleted)
                             .content)
                    (let* ((num (+ (* thread-id 1000) .id))
                           (post
                            (forge-pullreq-post
                             :id      (forge--object-id pullreq-id num)
                             :pullreq pullreq-id
                             :number  num
                             :author  .author.uniqueName
                             :created .publishedDate
                             :updated .lastUpdatedDate
                             :body    (forge--sanitize-string .content))))
                      (closql-insert (forge-db) post t))))))))
        (when .closedDate
          (let ((until (oref repo pullreqs-until)))
            (when (or (not until) (string> .closedDate until))
              (oset repo pullreqs-until .closedDate))))
        pullreq))))

;;;; Other

(defun forge-azure--update-assignees (repo data)
  "Add the participants of the pull-requests in DATA to REPO's assignees.
There is no suitable endpoint to get all users of a project, so
collect the users encountered in pull-requests instead."
  (let ((rows (oref repo assignees)))
    (dolist (pr data)
      (dolist (user (cons (alist-get 'createdBy pr)
                          (alist-get 'reviewers pr)))
        (let-alist user
          (when (and .id (not (assoc (forge--object-id (oref repo id) .id)
                                     rows)))
            (push (list (forge--object-id (oref repo id) .id)
                        .uniqueName
                        .displayName
                        ;; The identity GUID is used when adding
                        ;; reviewers and casting votes.
                        .id)
                  rows)))))
    (oset repo assignees rows)))

;;; Mutations

(cl-defmethod forge--submit-create-pullreq ((_ forge-azure-repository)
                                            base-repo)
  (pcase-let* ((`(,title . ,body) (forge--post-buffer-text))
               (`(,_base-remote . ,base-branch)
                (magit-split-branch-name forge--buffer-base-branch))
               (`(,_head-remote . ,head-branch)
                (magit-split-branch-name forge--buffer-head-branch)))
    (forge-azure--post base-repo
      "/:owner/_apis/git/repositories/:name/pullrequests"
      `((sourceRefName . ,(concat "refs/heads/" head-branch))
        (targetRefName . ,(concat "refs/heads/" base-branch))
        (title . ,title)
        (description . ,body)
        ,@(and forge--buffer-draft-p '((isDraft . t))))
      :callback  (forge--post-submit-callback)
      :errorback (forge--post-submit-errorback))))

(cl-defmethod forge--submit-create-post
  ((_     forge-azure-repository)
   (topic forge-pullreq))
  (forge-azure--post topic
    "/:owner/_apis/git/repositories/:repo/pullRequests/:number/threads"
    `((comments . [((parentCommentId . 0)
                    (content . ,(string-trim
                                 (forge--buffer-substring-no-properties)))
                    (commentType . 1))])
      (status . 1))
    :callback  (forge--post-submit-callback)
    :errorback (forge--post-submit-errorback)))

(cl-defmethod forge--submit-edit-post
  ((_    forge-azure-repository)
   (post forge-post))
  (cl-etypecase post
    (forge-pullreq
     (pcase-let ((`(,title . ,body) (forge--post-buffer-text)))
       (forge-azure--patch post
         "/:owner/_apis/git/repositories/:repo/pullrequests/:number"
         `((title . ,title)
           (description . ,body))
         :callback  (forge--post-submit-callback)
         :errorback (forge--post-submit-errorback))))
    (forge-pullreq-post
     (let ((number (oref post number)))
       (forge-azure--patch post
         (format
          "/:owner/_apis/git/repositories/:repo/pullRequests/:topic/threads/%s/comments/%s"
          (/ number 1000) (mod number 1000))
         `((content . ,(string-trim
                        (forge--buffer-substring-no-properties))))
         :callback  (forge--post-submit-callback)
         :errorback (forge--post-submit-errorback))))))

(cl-defmethod forge--delete-comment
  ((_    forge-azure-repository)
   (post forge-pullreq-post))
  (let ((number (oref post number)))
    (forge-azure--delete post
      (format
       "/:owner/_apis/git/repositories/:repo/pullRequests/:topic/threads/%s/comments/%s"
       (/ number 1000) (mod number 1000))))
  (closql-delete post)
  (forge-refresh-buffer))

(cl-defmethod forge--set-topic-field
  ((_repo forge-azure-repository)
   (topic forge-pullreq)
   field value)
  (forge-azure--patch topic
    "/:owner/_apis/git/repositories/:repo/pullrequests/:number"
    `((,field . ,value))
    :callback (forge--set-field-callback topic)))

(cl-defmethod forge--set-topic-title
  ((repo  forge-azure-repository)
   (topic forge-topic)
   title)
  (forge--set-topic-field repo topic 'title title))

(cl-defmethod forge--set-topic-state
  ((repo  forge-azure-repository)
   (topic forge-topic)
   state)
  (forge--set-topic-field repo topic 'status
                          (pcase-exhaustive state
                            ;; Merging isn't done through here.
                            ('completed "abandoned")
                            ('unplanned "abandoned")
                            ('rejected  "abandoned")
                            ('open      "active"))))

(cl-defmethod forge--set-topic-draft
  ((repo  forge-azure-repository)
   (topic forge-topic)
   value)
  (forge--set-topic-field repo topic 'isDraft (and value t)))

(cl-defmethod forge--set-topic-review-requests
  ((repo  forge-azure-repository)
   (topic forge-pullreq)
   reviewers)
  (let* ((users (mapcar #'cdr (oref repo assignees)))
         (old (mapcar #'cadr (oref topic review-requests)))
         (resource "/:owner/_apis/git/repositories/:repo/pullRequests/:number/reviewers/%s"))
    (dolist (login (cl-set-difference reviewers old :test #'equal))
      (when-let* ((guid (caddr (assoc login users))))
        (forge-azure--put topic (format resource guid)
          `((id . ,guid)
            (vote . 0)))))
    (dolist (login (cl-set-difference old reviewers :test #'equal))
      (when-let* ((guid (caddr (assoc login users))))
        (forge-azure--delete topic (format resource guid)))))
  (forge--pull repo #'forge-refresh-buffer))

(cl-defmethod forge--submit-approve-pullreq ((repo forge-azure-repository)
                                             topic)
  (forge-azure--vote-pullreq repo topic 10))

(cl-defmethod forge--submit-request-changes ((repo forge-azure-repository)
                                             topic)
  ;; Cast a "waiting for author" vote; unlike "rejected" (-10), it
  ;; does not block completion under common branch policies.
  (forge-azure--vote-pullreq repo topic -5))

(defun forge-azure--vote-pullreq (repo topic vote)
  "Cast VOTE on TOPIC as the authenticated user.
If the current post buffer contains any text, additionally post it
as a comment.  REPO must be TOPIC's repository."
  (let ((user-id (forge-azure--user-id repo))
        (body (string-trim (forge--buffer-substring-no-properties)))
        (callback (forge--post-submit-callback))
        (errorback (forge--post-submit-errorback)))
    (forge-azure--put topic
      (format "/:owner/_apis/git/repositories/:repo/pullRequests/:number/reviewers/%s"
              user-id)
      `((id . ,user-id)
        (vote . ,vote))
      :callback (if (equal body "")
                    callback
                  (lambda (&rest _)
                    (forge-azure--post topic
                      "/:owner/_apis/git/repositories/:repo/pullRequests/:number/threads"
                      `((comments . [((parentCommentId . 0)
                                      (content . ,body)
                                      (commentType . 1))])
                        (status . 1))
                      :callback  callback
                      :errorback errorback)))
      :errorback errorback)))

(cl-defmethod forge--topic-template-files ((repo forge-azure-repository)
                                           (_ (subclass forge-issue)))
  (ignore repo))

(cl-defmethod forge--topic-template-files ((repo forge-azure-repository)
                                           (_ (subclass forge-pullreq)))
  (forge--topic-template-files-1 repo "md" ".azuredevops"))

(cl-defmethod forge--merge-pullreq
  ((_repo forge-azure-repository)
   (topic forge-topic)
   hash method)
  (forge-azure--patch topic
    "/:owner/_apis/git/repositories/:repo/pullrequests/:number"
    `((status . "completed")
      (lastMergeSourceCommit . ((commitId . ,(or hash (oref topic head-rev)))))
      (completionOptions
       . ((mergeStrategy . ,(pcase-exhaustive method
                              ('merge        "noFastForward")
                              ('squash       "squash")
                              ('rebase       "rebase")
                              ('rebase-merge "rebaseMerge")))
          (deleteSourceBranch . nil))))))

;;; Checkout

(cl-defmethod forge--branch-pullreq ((_repo forge-azure-repository) pullreq)
  ;; `forge--setup-pullreq-remote' cannot construct valid urls for
  ;; Azure DevOps forks.
  (if (oref pullreq cross-repo-p)
      (user-error
       "Checking out pull-requests from forks is not supported for Azure DevOps")
    (cl-call-next-method)))

;;; Command advices

;; `forge-approve-pullreq' and `forge-request-changes' hard-code a
;; Github-only check, and `forge-select-merge-method' does not know
;; which merge methods Azure offers.

(defun forge-azure--approve-pullreq (orig &rest args)
  "Allow `forge-approve-pullreq' (ORIG, called with ARGS) on Azure DevOps."
  (let ((pullreq (forge-current-pullreq)))
    (if (and pullreq
             (cl-typep (forge-get-repository pullreq) 'forge-azure-repository))
        (forge--setup-post-buffer pullreq #'forge--submit-approve-pullreq
          "%i;new-approval" "Approve pull-request #%i of %p")
      (apply orig args))))

(defun forge-azure--request-changes (orig &rest args)
  "Allow `forge-request-changes' (ORIG, called with ARGS) on Azure DevOps."
  (let ((pullreq (forge-current-pullreq)))
    (if (and pullreq
             (cl-typep (forge-get-repository pullreq) 'forge-azure-repository))
        (forge--setup-post-buffer pullreq #'forge--submit-request-changes
          "%i;new-request" "Request changes for pull-request #%i of %p")
      (apply orig args))))

(defun forge-azure--select-merge-method (orig)
  "Offer Azure DevOps merge strategies instead of calling ORIG."
  (if (cl-typep (forge-get-repository :tracked) 'forge-azure-repository)
      (magit-read-char-case "Merge method " t
        (?m "[m]erge"  'merge)
        (?s "[s]quash" 'squash)
        (?r "[r]ebase" 'rebase)
        (?b "rebase+merge [b]" 'rebase-merge))
    (funcall orig)))

(advice-add 'forge-approve-pullreq :around #'forge-azure--approve-pullreq)
(advice-add 'forge-request-changes :around #'forge-azure--request-changes)
(advice-add 'forge-select-merge-method :around
            #'forge-azure--select-merge-method)

;;; Wrappers

;; The wrappers use `:auth 'none' and supply the Authorization header
;; themselves, because `ghub--auth' would reject the unknown forge
;; type.  Azure accepts either a Microsoft Entra ID access token as a
;; bearer token, or basic authentication with any username and a
;; personal access token as the password; `forge-azure-auth' selects
;; the scheme.

(defconst forge-azure--entra-resource "499b84ac-1321-427f-aa17-267ca6975798"
  "Application ID of the Azure DevOps resource in Microsoft Entra ID.")

(defconst forge-azure--entra-refresh-margin 300
  "Seconds before expiry at which a cached token is refreshed.")

(defvar forge-azure--entra-tokens (make-hash-table :test #'equal)
  "Hash table mapping APIHOST to (TOKEN . EXPIRY).")

(defun forge-azure--entra-token (host)
  "Return a valid Entra ID access token for HOST."
  (pcase (gethash host forge-azure--entra-tokens)
    ((and `(,token . ,expiry)
          (guard (< (+ (float-time) forge-azure--entra-refresh-margin)
                    expiry)))
     token)
    (_ (car (puthash host (forge-azure--entra-acquire-token)
                     forge-azure--entra-tokens)))))

(defun forge-azure--entra-acquire-token (&optional retried)
  "Acquire an Entra ID access token using the Azure CLI.
Return a cons (TOKEN . EXPIRY), where EXPIRY is a unix timestamp.
If the CLI reports that a login is required, then, depending on
`forge-azure-az-login', run \"az login\" and try once more; a
non-nil RETRIED means a login already happened."
  (unless (executable-find forge-azure-az-executable)
    (user-error "Cannot find `%s'; install the Azure CLI or set \
`forge-azure-auth' to `pat'" forge-azure-az-executable))
  (let ((default-directory temporary-file-directory)
        (stderr-file (make-temp-file "forge-azure-az-stderr")))
    (unwind-protect
        (with-temp-buffer
          (if (eq (call-process forge-azure-az-executable nil
                                (list (current-buffer) stderr-file) nil
                                "account" "get-access-token"
                                "--resource" forge-azure--entra-resource
                                "--output" "json")
                  0)
              (progn
                (goto-char (point-min))
                (let* ((data (condition-case nil
                                 (json-parse-buffer :object-type 'alist)
                               (error (user-error "\
Cannot parse output of az account get-access-token"))))
                       (token (alist-get 'accessToken data)))
                  (unless (stringp token)
                    (user-error "\
No accessToken in output of az account get-access-token"))
                  (cons token (forge-azure--entra-expiry data))))
            (let ((stderr (string-trim
                           (with-temp-buffer
                             (insert-file-contents stderr-file)
                             (buffer-string)))))
              (if (and (not retried)
                       forge-azure-az-login
                       (string-match-p "az login" stderr)
                       (or (not (eq forge-azure-az-login 'ask))
                           (and (not noninteractive)
                                (y-or-n-p "\
Not logged in to Azure; run \"az login\" now? "))))
                  (progn
                    (forge-azure--az-login)
                    (forge-azure--entra-acquire-token t))
                (user-error "az account get-access-token failed: %s"
                            stderr)))))
      (delete-file stderr-file))))

(defun forge-azure--az-login ()
  "Log in to Azure by running \"az login\".
The CLI hands the login flow off to a web browser; block until
it completes."
  (message "Waiting for \"az login\" to complete in your browser...")
  (let ((default-directory temporary-file-directory)
        (stderr-file (make-temp-file "forge-azure-az-stderr")))
    (unwind-protect
        (unless (eq (call-process forge-azure-az-executable nil
                                  (list nil stderr-file) nil
                                  "login" "--only-show-errors"
                                  "--output" "none")
                    0)
          (user-error "az login failed: %s"
                      (string-trim
                       (with-temp-buffer
                         (insert-file-contents stderr-file)
                         (buffer-string)))))
      (delete-file stderr-file))))

(defun forge-azure--entra-expiry (data)
  "Return the expiry of the token described by DATA as a unix timestamp.
If DATA contains no usable expiry, return a time close enough to
now that the token is re-acquired for the next request."
  (or (let ((expires-on (alist-get 'expires_on data)))
        (and (numberp expires-on) expires-on))
      (let ((expires-on (alist-get 'expiresOn data)))
        (and (stringp expires-on)
             ;; A local time "YYYY-MM-DD HH:MM:SS.ffffff".
             (ignore-errors
               (float-time
                (encode-time
                 (parse-time-string
                  (replace-regexp-in-string "\\.[0-9]+\\'" ""
                                            expires-on)))))))
      (+ (float-time) forge-azure--entra-refresh-margin)))

(defun forge-azure--headers (host)
  "Return an alist with the Authorization header for HOST."
  (pcase-exhaustive forge-azure-auth
    ('entra
     ;; The token must be unibyte; `url-http' rejects requests that
     ;; combine multibyte header values with a non-ASCII body.
     `(("Authorization"
        . ,(concat "Bearer " (encode-coding-string
                              (forge-azure--entra-token host) 'utf-8)))))
    ('pat
     (let ((username (ghub--username host 'azure)))
       `(("Authorization"
          . ,(concat "Basic "
                     (base64-encode-string
                      (concat username ":"
                              (ghub--token host username 'forge nil 'azure))
                      t))))))))

(defun forge-azure--list-value (data)
  "Return the list wrapped in DATA, or DATA itself.
List responses wrap the actual list in an object with a `count'
and a `value' key."
  (if (and (listp data)
           (assq 'count data)
           (assq 'value data))
      (alist-get 'value data)
    data))

(cl-defun forge-azure--get (obj resource
                                &optional params
                                &key query payload headers
                                silent paginate noerror reader
                                host callback errorback)
  (declare (indent defun))
  (let ((resource (if obj (forge--format-resource obj resource) resource))
        (host (or host (oref (forge-get-repository obj) apihost))))
    (unless (assq 'api-version params)
      (setq params (cons '(api-version . "7.1") params)))
    (cond
      (paginate
       ;; The API does not send a "Link" header; list endpoints
       ;; paginate using the `$top' and `$skip' query parameters.
       (letrec ((top 100)
                (skip 0)
                (value nil)
                (fetch
                 (lambda ()
                   (ghub-request "GET" resource
                     `(,@params ($top . ,top) ($skip . ,skip))
                     :forge 'azure :host host :auth 'none
                     :query query :payload payload
                     :headers (append headers (forge-azure--headers host))
                     :silent silent :noerror noerror :reader reader
                     :callback
                     (lambda (data &rest _)
                       (let ((page (forge-azure--list-value data)))
                         (setq value (nconc value page))
                         (if (= (length page) top)
                             (progn (cl-incf skip top)
                                    (funcall fetch))
                           (funcall callback value))))
                     :errorback (or errorback (and callback t))))))
         (funcall fetch)))
      (callback
       (ghub-request "GET" resource params
         :forge 'azure :host host :auth 'none
         :query query :payload payload
         :headers (append headers (forge-azure--headers host))
         :silent silent :noerror noerror :reader reader
         :callback (lambda (data &rest _)
                     (funcall callback (forge-azure--list-value data)))
         :errorback (or errorback (and callback t))))
      ((forge-azure--list-value
        (ghub-request "GET" resource params
          :forge 'azure :host host :auth 'none
          :query query :payload payload
          :headers (append headers (forge-azure--headers host))
          :silent silent :noerror noerror :reader reader
          :errorback errorback))))))

(cl-defun forge-azure--request (method obj resource
                                       &optional params
                                       &key query payload headers
                                       silent noerror reader
                                       host callback errorback)
  (let ((host (or host (oref (forge-get-repository obj) apihost))))
    (ghub-request method (forge--format-resource obj resource)
      params
      :forge 'azure :host host :auth 'none
      :query (cons '(api-version . "7.1") query)
      :payload payload
      :headers (append headers (forge-azure--headers host))
      :silent silent :noerror noerror :reader reader
      :callback callback
      :errorback (or errorback (and callback t)))))

(cl-defun forge-azure--post (obj resource &optional params &rest keys)
  (declare (indent defun))
  (apply #'forge-azure--request "POST" obj resource params keys))

(cl-defun forge-azure--put (obj resource &optional params &rest keys)
  (declare (indent defun))
  (apply #'forge-azure--request "PUT" obj resource params keys))

(cl-defun forge-azure--patch (obj resource &optional params &rest keys)
  (declare (indent defun))
  (apply #'forge-azure--request "PATCH" obj resource params keys))

(cl-defun forge-azure--delete (obj resource &optional params &rest keys)
  (declare (indent defun))
  (apply #'forge-azure--request "DELETE" obj resource params keys))

;;; _
(provide 'forge-azure)
;;; forge-azure.el ends here
