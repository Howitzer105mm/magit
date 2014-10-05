;;; magit.el --- control Git from Emacs

;; Copyright (C) 2008-2014  The Magit Project Developers
;;
;; For a full list of contributors, see the AUTHORS.md file
;; at the top-level directory of this distribution and at
;; https://raw.github.com/magit/magit/master/AUTHORS.md

;; Author: Marius Vollmer <marius.vollmer@gmail.com>
;; Maintainer: Jonas Bernoulli <jonas@bernoul.li>
;; Former-Maintainers:
;;	Nicolas Dudebout  <nicolas.dudebout@gatech.edu>
;;	Peter J. Weisberg <pj@irregularexpressions.net>
;;	Phil Jackson      <phil@shellarchive.co.uk>
;;	Rémi Vanicat      <vanicat@debian.org>
;;	Yann Hodique      <yann.hodique@gmail.com>

;; Keywords: vc tools
;; Package: magit
;; Package-Requires: ((cl-lib "0.5") (dash "2.8.0") (git-commit-mode "0.15.0") (git-rebase-mode "0.15.0") (with-editor "0.15.0"))

;; Magit requires at least GNU Emacs 24.1 and Git 1.7.2.5.

;; Magit is free software; you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.
;;
;; Magit is distributed in the hope that it will be useful, but WITHOUT
;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
;; or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public
;; License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with Magit.  If not, see http://www.gnu.org/licenses.

;;; Commentary:

;; Invoking the `magit-status' command will show a buffer with the
;; status of the current Git repository and its working tree.  That
;; buffer offers key bindings for manipulating the status in simple
;; ways.
;;
;; The status buffer mainly shows the difference between the working
;; tree and the index, and the difference between the index and the
;; current HEAD.  You can add individual hunks from the working tree
;; to the index, and you can commit the index.
;;
;; See the Magit User Manual for more information.

;;; Code:

(when (version< emacs-version "24.1")
  (error "Magit requires at least GNU Emacs 24.1"))

(require 'cl-lib)
(require 'dash)

(require 'git-commit-mode)
(require 'git-rebase-mode)
(require 'with-editor)
(require 'magit-core)
(require 'magit-diff)
(require 'magit-apply)
(require 'magit-log)

(require 'format-spec)
(require 'package nil t) ; used in `magit-version'

(eval-when-compile (require 'dired-x))
(declare-function dired-jump 'dired-x)
(eval-when-compile (require 'eshell))
(declare-function eshell-parse-arguments 'eshell)
(eval-when-compile (require 'smerge-mode))


;;; Options
;;;; Status Mode

(defgroup magit-status nil
  "Inspect and manipulate Git repositories."
  :group 'magit-modes)

(defcustom magit-status-mode-hook nil
  "Hook run when the `magit-status' buffer is created."
  :group 'magit-status
  :type 'hook)

(defcustom magit-status-headers-hook
  '(magit-insert-status-tags-line)
  "Hook run to insert headers into the status buffer.

This hook is run by `magit-insert-status-headers', which always
inserts the \"Head\" and \"Upstream\" headers before the headers
listed here.  `magit-insert-status-headers' has to be a member
of `magit-insert-status-sections', or no headers are inserted."
  :package-version '(magit . "2.1.0")
  :group 'magit-status
  :type 'hook)

(defcustom magit-status-sections-hook
  '(magit-insert-status-headers
    magit-insert-merge-log
    magit-insert-rebase-sequence
    magit-insert-am-sequence
    magit-insert-sequencer-sequence
    magit-insert-bisect-output
    magit-insert-bisect-rest
    magit-insert-bisect-log
    magit-insert-untracked-files
    magit-insert-unstaged-changes
    magit-insert-staged-changes
    magit-insert-stashes
    magit-insert-unpulled-commits
    magit-insert-unpushed-commits)
  "Hook run to insert sections into the status buffer.

This option allows reordering the sections and adding sections
that are by default displayed in other Magit buffers.  Doing the
latter is currently not recommended because not all functions
that insert sections have been adapted yet.  Only inserters that
take no argument can be used and some functions exist that begin
with the `magit-insert-' prefix but do not insert a section.

Note that there are already plans to improve this and to add
similar hooks for other Magit modes."
  :package-version '(magit . "2.1.0")
  :group 'magit-status
  :type 'hook)

(defcustom magit-status-buffer-switch-function 'pop-to-buffer
  "Function used by `magit-status' to switch to the status buffer.

The function is given one argument, the status buffer."
  :group 'magit-status
  :type '(radio (function-item switch-to-buffer)
                (function-item pop-to-buffer)
                (function :tag "Other")))

(defcustom magit-status-buffer-name-format "*magit: %a*"
  "Name format for buffers used to display a repository's status.
The following `format'-like specs are supported:
%a the absolute filename of the repository toplevel.
%b the basename of the repository toplevel."
  :package-version '(magit . "2.1.0")
  :group 'magit-status
  :type 'string)

;;;; Refs Mode

(defgroup magit-refs nil
  "Inspect and manipulate Git branches and tags."
  :group 'magit-modes)

(defcustom magit-refs-sections-hook
  '(magit-insert-branch-description
    magit-insert-local-branches
    magit-insert-remote-branches
    magit-insert-tags)
  "Hook run to insert sections into the references buffer."
  :package-version '(magit . "2.1.0")
  :group 'magit-refs
  :type 'hook)

(defcustom magit-refs-buffer-name-format "*magit-refs: %a*"
  "Name format for buffers used to display and manage refs.

The following `format'-like specs are supported:
%a the absolute filename of the repository toplevel.
%b the basename of the repository toplevel."
  :package-version '(magit . "2.1.0")
  :group 'magit-refs
  :type 'string)

;;;; Miscellaneous

(defcustom magit-merge-warn-dirty-worktree t
  "Whether to warn before merging with a dirty worktree."
  :package-version '(magit . "2.1.0")
  :group 'magit-commands
  :type 'boolean)

(defcustom magit-repository-directories nil
  "Directories containing Git repositories.
Magit will look into these directories for Git repositories
and offer them as choices for `magit-status'."
  :group 'magit
  :type '(repeat string))

(defcustom magit-repository-directories-depth 3
  "The maximum depth to look for Git repositories.
When looking for a Git repository below the directories in
`magit-repository-directories', Magit will only descend this
many levels deep."
  :group 'magit
  :type 'integer)

;;;; Faces

(defface magit-dimmed
  '((((class color) (background light)) :foreground "grey50")
    (((class color) (background  dark)) :foreground "grey50"))
  "Face for text that shouldn't stand out."
  :group 'magit-faces)

(defface magit-hash
  '((((class color) (background light)) :foreground "grey60")
    (((class color) (background  dark)) :foreground "grey40"))
  "Face for the sha1 part of the log output."
  :group 'magit-faces)

(defface magit-tag
  '((((class color) (background light))
     :background "grey80"
     :foreground "Goldenrod4")
    (((class color) (background dark))
     :background "grey30"
     :foreground "LightGoldenrod2"))
  "Face for tag labels shown in log buffer."
  :group 'magit-faces)

(defface magit-branch-remote
  '((((class color) (background light))
     :background "grey80"
     :foreground "DarkOliveGreen4")
    (((class color) (background dark))
     :background "grey30"
     :foreground "DarkSeaGreen2"))
  "Face for remote branch head labels shown in log buffer."
  :group 'magit-faces)

(defface magit-branch-local
  '((((class color) (background light))
     :background "grey80"
     :foreground "SkyBlue4")
    (((class color) (background dark))
     :background "grey30"
     :foreground "LightSkyBlue1"))
  "Face for local branches."
  :group 'magit-faces)

(defface magit-branch-current
  '((((class color) (background light)) :inherit magit-branch-local :box t)
    (((class color) (background dark))  :inherit magit-branch-local :box t))
  "Face for local branches."
  :group 'magit-faces)

(defface magit-head
  '((((class color) (background light)) :inherit magit-branch-local)
    (((class color) (background dark))  :inherit magit-branch-local))
  "Face for the symbolic ref \"HEAD\"."
  :group 'magit-faces)

(defface magit-refname
  '((((class color) (background light))
     :background "grey75"
     :foreground "grey30")
    (((class color) (background  dark))
     :background "grey30"
     :foreground "grey80"))
  "Face for refnames without a dedicated face."
  :group 'magit-faces)

(defface magit-refname-stash
  '((t :inherit magit-refname))
  "Face for wip refnames."
  :group 'magit-faces)

(defface magit-refname-wip
  '((t :inherit magit-refname))
  "Face for wip refnames."
  :group 'magit-faces)

(defface magit-signature-good
  '((t :foreground "green"))
  "Face for good signatures."
  :group 'magit-faces)

(defface magit-signature-bad
  '((t :foreground "red"))
  "Face for bad signatures."
  :group 'magit-faces)

(defface magit-signature-untrusted
  '((t :foreground "cyan"))
  "Face for good untrusted signatures."
  :group 'magit-faces)

(defface magit-cherry-unmatched
  '((t :foreground "cyan"))
  "Face for unmatched cherry commits.")

(defface magit-cherry-equivalent
  '((t :foreground "magenta"))
  "Face for equivalent cherry commits.")

;;; Inspect
;;;; Status Mode

(defvar magit-status-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit-mode-map)
    (define-key map "jz" 'magit-jump-to-stashes)
    (define-key map "jn" 'magit-jump-to-untracked)
    (define-key map "ju" 'magit-jump-to-unstaged)
    (define-key map "js" 'magit-jump-to-staged)
    (define-key map "jf" 'magit-jump-to-unpulled)
    (define-key map "jp" 'magit-jump-to-unpushed)
    map)
  "Keymap for `magit-status-mode'.")

(eval-after-load 'dired-x
  '(define-key magit-status-mode-map [remap dired-jump] 'magit-dired-jump))

(define-derived-mode magit-status-mode magit-mode "Magit"
  "Mode for looking at Git status.
This mode is documented in info node `(magit)Status'.

\\<magit-status-mode-map>\
Type \\[magit-refresh] to refresh the current buffer.
Type \\[magit-dispatch-popup] to see available action popups.
Type \\[magit-section-toggle] to expand or hide the section at point.
Type \\[magit-visit-file] to visit the thing at point.
Type \\[magit-stage] to stage the change at point; \\[magit-unstage] to unstage.
Type \\[magit-commit-popup] to create a commit.
\n\\{magit-status-mode-map}"
  :group 'magit-status)

;;;###autoload
(defun magit-status (dir &optional switch-function)
  "Open a Magit status buffer for the Git repository containing DIR.
If DIR is not within a Git repository, offer to create a Git
repository in DIR.

Interactively, a prefix argument means to ask the user which
Git repository to use even if `default-directory' is under
Git control.  Two prefix arguments means to ignore
`magit-repository-directories' when asking for user input.

Depending on option `magit-status-buffer-switch-function' the
status buffer is shown in another window (the default) or the
current window.  Non-interactively optional SWITCH-FUNCTION
can be used to override this."
  (interactive (list (if current-prefix-arg
                         (magit-read-top-dir
                          (> (prefix-numeric-value current-prefix-arg) 4))
                       (or (magit-get-top-dir)
                           (magit-read-top-dir nil)))))
  (-when-let (default-directory
              (or (magit-get-top-dir dir)
                  (and (yes-or-no-p
                        (format "No repository in %s.  Create one? " dir))
                       (progn (magit-init dir)
                              (magit-get-top-dir dir)))))
    (magit-mode-setup magit-status-buffer-name-format
                      (or switch-function
                          magit-status-buffer-switch-function)
                      #'magit-status-mode
                      #'magit-status-refresh-buffer)))

(defun magit-status-refresh-buffer ()
  (magit-git-exit-code "update-index" "--refresh")
  (magit-insert-section (status)
    (run-hooks 'magit-status-sections-hook))
  (run-hooks 'magit-refresh-status-hook)) ; TODO

(defun magit-insert-status-headers (&optional branch upstream)
  (unless branch
    (setq branch (magit-get-current-branch)))
  (-if-let  (hash (magit-rev-verify "HEAD"))
      (let ((line (magit-rev-format "%h %s" "HEAD")))
        (string-match "^\\([^ ]+\\) \\(.*\\)" line)
        (magit-bind-match-strings (hash msg) line
          (magit-insert-section (branch (or branch hash))
            (magit-insert-heading
              (magit-string-pad "Head: " 10)
              (propertize hash 'face 'magit-hash) " "
              (and branch
                   (concat (propertize branch 'face 'magit-branch-local) " "))
              msg "\n")
            (when (or upstream (setq upstream (magit-get-tracked-branch branch)))
              (setq line (or (magit-rev-format "%h %s" upstream) ""))
              (string-match "^\\([^ ]+\\) \\(.*\\)" line)
              (magit-bind-match-strings (hash msg) line
                (magit-insert-section (branch upstream)
                  (magit-insert
                   (concat
                    (magit-string-pad "Upstream: " 10)
                    (if hash (propertize hash 'face 'magit-hash) "missing") " "
                    (and (magit-get-boolean "branch" branch "rebase") "onto ")
                    (propertize
                     upstream 'face
                     (if (string= (magit-get "branch" branch "remote") ".")
                         'magit-branch-local
                       'magit-branch-remote))
                    " " msg "\n")))))
            (run-hooks 'magit-status-headers-hook)
            (insert "\n"))))
    (insert "In the beginning there was darkness\n\n")))

(defun magit-insert-status-tags-line ()
  (let* ((this-tag (magit-get-current-tag t))
         (next-tag (magit-get-next-tag t))
         (this-cnt (cadr this-tag))
         (next-cnt (cadr next-tag))
         (this-tag (car this-tag))
         (next-tag (car next-tag))
         (both-tags (and this-tag next-tag t)))
    (when (or this-tag next-tag)
      (magit-insert-section (tag (or this-tag next-tag))
        (magit-insert
         (concat
          (magit-string-pad (if both-tags "Tags: " "Tag: ") 10)
          (and this-tag (magit-format-status-tag-sentence this-tag this-cnt nil))
          (and both-tags ", ")
          (and next-tag (magit-format-status-tag-sentence next-tag next-cnt t))
          "\n"))))))

(defun magit-format-status-tag-sentence (tag count next)
  (concat (propertize tag 'face 'magit-tag)
          (and (> count 0)
               (format " (%s)"
                       (propertize (format "%s" count) 'face
                                   (if next 'magit-tag 'magit-branch-local))))))

(defvar magit-untracked-section-map
  (let ((map (make-sparse-keymap)))
    (define-key map "k"  'magit-discard)
    (define-key map "s"  'magit-stage)
    map)
  "Keymap for the `untracked' section.")

(magit-define-section-jumper untracked "Untracked files")

(defun magit-insert-untracked-files ()
  (-when-let (files (magit-untracked-files))
    (magit-insert-section (untracked)
      (magit-insert-heading "Untracked files:")
      (magit-insert-untracked-files-1 files nil)
      (insert ?\n))))

(defun magit-insert-untracked-files-1 (files directory)
  (while (and files (string-prefix-p (or directory "") (car files)))
    (let ((dir (file-name-directory (car files))))
      (if (equal dir directory)
          (let ((file (pop files)))
            (magit-insert-section (file file)
              (insert file ?\n)))
        (magit-insert-section (file dir t)
          (insert dir ?\n)
          (magit-insert-heading)
          (setq files (magit-insert-untracked-files-1 files dir))))))
  files)

;;;; Refs Mode

(defvar magit-refs-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit-mode-map)
    map)
  "Keymap for `magit-refs-mode'.")

(define-derived-mode magit-refs-mode magit-mode "Magit Branch"
  "Mode which lists and compares references.
This mode is documented in info node `(magit)Branches and Remotes'.

\\<magit-refs-mode-map>\
Type \\[magit-refresh] to refresh the current buffer.
Type \\[magit-branch-popup] to see available branch commands.
Type \\[magit-show-commit] or \\[magit-diff-show-or-scroll-up]\
 to visit the commit at point.
Type \\[magit-merge-popup] to merge the branch or commit at point.
Type \\[magit-cherry-pick] to cherry-pick the commit at point.
Type \\[magit-reset-head] to reset HEAD to the commit at point.
\n\\{magit-refs-mode-map}"
  :group 'magit-modes)

(magit-define-popup magit-show-refs-popup
  "Popup console for `magit-show-refs'."
  'magit-popups
  :man-page "git-branch"
  :switches '((?m "Merged to HEAD"            "--merged")
              (?M "Merged to master"          "--merged=master")
              (?n "Not merged to HEAD"        "--no-merged")
              (?N "Not merged to master"      "--no-merged=master"))
  :options  '((?c "Contains"   "--contains="  magit-read-branch-or-commit)
              (?m "Merged"     "--merged="    magit-read-branch-or-commit)
              (?n "Not merged" "--no-merged=" magit-read-branch-or-commit))
  :actions  '((?y "Show refs, comparing them with current branch"
                  magit-show-refs-head)
              (?b "Show refs, comparing them with other branch"
                  magit-show-refs))
  :default-action 'magit-show-refs-head
  :use-prefix 'popup)

;;;###autoload
(defun magit-show-refs-head (&optional head args)
  "List and compare references in a dedicated buffer.
Refs are compared with the current branch or `HEAD' if
it is detached."
  (interactive (list (magit-get-current-branch) magit-current-popup-args))
  (magit-show-refs head args))

;;;###autoload
(defun magit-show-refs (&optional head args)
  "List and compare references in a dedicated buffer.
Refs are compared with a branch read form the user."
  (interactive (list (and (or current-prefix-arg magit-current-popup)
                          (magit-read-branch "Compare branch"))
                     magit-current-popup-args))
  (magit-mode-setup magit-refs-buffer-name-format nil
                    #'magit-refs-mode
                    #'magit-refs-refresh-buffer head args))

(defun magit-refs-refresh-buffer (&rest ignore)
  (magit-insert-section (branchbuf)
    (run-hooks 'magit-refs-sections-hook)))

(defconst magit-wash-branch-line-re
  (concat "^"
          "\\(?:[ \\*]\\) "
          "\\(?1:([^)]+)\\|[^ ]+?\\)"       ; branch
          "\\(?: +\\)"
          "\\(?2:[0-9a-fA-F]+\\) "          ; sha1
          "\\(?:\\["
          "\\(?4:[^:\n]+?\\)\\(?:: \\)?"    ; upstream
          "\\(?:ahead \\(?5:[0-9]+\\)\\)?"  ; ahead
          "\\(?:, \\)?"
          "\\(?:behind \\(?6:[0-9]+\\)\\)?" ; behind
          "\\] \\)?"
          "\\(?3:.*\\)"))                   ; message

(defvar magit-local-branch-format "%3c %-25n %U%m\n")
(defvar magit-remote-branch-format "%3c %-25n %m\n")
(defvar magit-tags-format "%3c %n\n")

(defvar magit-branch-section-map
  (let ((map (make-sparse-keymap)))
    (define-key map "\r" 'magit-show-commit)
    (define-key map "k"  'magit-branch-delete)
    (define-key map "R"  'magit-branch-rename)
    map)
  "Keymap for `branch' sections.")

(defvar magit-remote-section-map
  (let ((map (make-sparse-keymap)))
    (define-key map "k"  'magit-remote-remove)
    (define-key map "R"  'magit-remote-rename)
    map)
  "Keymap for `remote' sections.")

(defun magit-insert-local-branches ()
  (magit-insert-section (local nil)
    (magit-insert-heading "Branches:")
    (let ((current  (magit-get-current-branch))
          (branches (magit-list-local-branch-names)))
      (dolist (line (magit-git-lines "branch" "-vv"
                                     (cadr magit-refresh-args)))
        (string-match magit-wash-branch-line-re line)
        (magit-bind-match-strings
            (branch hash message upstream ahead behind) line
          (when (string-match-p "(" branch)
            (setq branch nil))
          (magit-insert-branch
           branch current branches
           magit-local-branch-format 'magit-branch-local
           hash message upstream ahead behind))))
    (insert ?\n)))

(defun magit-insert-remote-branches ()
  (dolist (remote (magit-list-remotes))
    (magit-insert-section (remote remote)
      (magit-insert-heading
        (let ((pull (magit-get "remote" remote "url"))
              (push (magit-get "remote" remote "pushurl")))
          (format "%s (%s):" (capitalize remote)
                  (concat pull (and pull push ", ") push))))
      (let ((current  (magit-get-current-branch))
            (branches (magit-list-local-branch-names)))
        (dolist (line (magit-git-lines "branch" "-vvr"
                                       (cadr magit-refresh-args)))
          (when (string-match magit-wash-branch-line-re line)
            (magit-bind-match-strings (branch hash message) line
              (when (string-match-p (format "^%s/" remote) branch)
                (magit-insert-branch
                 branch current branches
                 magit-remote-branch-format 'magit-branch-remote hash message))))))
      (insert ?\n))))

(defun magit-insert-branch (branch &rest args)
  (if branch
      (magit-insert-section it (branch branch t)
        (apply #'magit-insert-branch-1 it branch args))
    (magit-insert-section it (commit (magit-rev-parse "HEAD") t)
      (apply #'magit-insert-branch-1 it nil args))))

(defun magit-insert-branch-1
    (section branch current branches format face
             &optional hash message upstream ahead behind)
  (let* ((head  (or (car magit-refresh-args) current "HEAD"))
         (count (if branch (cadr (magit-rev-diff-count head branch)) 0)))
    (when upstream
      (setq upstream (propertize upstream 'face
                                 (if (member upstream branches)
                                     'magit-branch-local
                                   'magit-branch-remote))))
    (magit-insert-heading
      (format-spec
       format
       `((?a . ,(or ahead ""))
         (?b . ,(or behind ""))
         (?c . ,(cond
                 ((or (equal branch head)
                      (and (not branch) (equal head "HEAD")))
                  (if (equal branch current)
                      (propertize "@" 'face 'magit-head)
                    (propertize "#" 'face 'magit-tag)))
                 ((> count 0)
                  (propertize (number-to-string count)
                              'face 'magit-dimmed))
                 (t "")))
         (?h . ,(or (propertize hash 'face 'magit-hash) ""))
         (?m . ,(or message ""))
         (?n . ,(propertize (or branch "(detached)") 'face face))
         (?u . ,(or upstream ""))
         (?U . ,(if upstream
                    (format (propertize "[%s%s] " 'face 'magit-dimmed)
                            upstream
                            (if (or ahead behind)
                                (concat ": "
                                        (and ahead (format "ahead %s" ahead))
                                        (and ahead behind ", ")
                                        (and behind (format "behind %s" behind)))
                              ""))
                  "")))))
    (when (> count 0)
      (if (magit-section-hidden section)
          (setf (magit-section-washer section)
                `(lambda ()
                   (magit-insert-cherry-commits-1 ,head ,branch)
                   (insert (propertize "\n" 'magit-section ,section))))
        (magit-insert-cherry-commits-1 head branch)
        (insert ?\n)))))

(defvar magit-tag-section-map
  (let ((map (make-sparse-keymap)))
    (define-key map "\r" 'magit-show-commit)
    (define-key map "k"  'magit-tag-delete)
    map)
  "Keymap for `tag' sections.")

(defun magit-insert-tags ()
  (magit-insert-section (tags)
    (magit-insert-heading "Tags:")
    (dolist (tag (nreverse (magit-git-lines "tag")))
      (let ((count (cadr (magit-rev-diff-count
                          (or (car magit-refresh-args) "HEAD") tag))))
        (magit-insert-section (tag tag)
          (magit-insert
           (format-spec magit-tags-format
                        `((?n . ,(propertize tag 'face 'magit-tag))
                          (?c . ,(if (> count 0)
                                     (propertize (number-to-string count)
                                                 'face 'magit-dimmed)
                                   ""))))))))
    (insert ?\n)))

;;;; Files

;;;###autoload
(defun magit-find-file (rev file)
  (interactive (magit-find-file-read-args "Find file"))
  (switch-to-buffer (magit-find-file-noselect rev file)))

;;;###autoload
(defun magit-find-file-other-window (rev file)
  (interactive (magit-find-file-read-args "Find file in other window"))
  (switch-to-buffer-other-window (magit-find-file-noselect rev file)))

(defun magit-find-file-read-args (prompt)
  (let ((rev (magit-read-branch-or-commit "Find file from revision")))
    (list rev (magit-read-file-from-rev rev prompt))))

(defun magit-get-revision-buffer (rev file &optional create)
  (funcall (if create 'get-buffer-create 'get-buffer)
           (format "%s.~%s~" file (subst-char-in-string ?/ ?_ rev))))

(defun magit-get-revision-buffer-create (rev file)
  (magit-get-revision-buffer rev file t))

(defun magit-find-file-noselect (rev file)
  (with-current-buffer (magit-get-revision-buffer-create rev file)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (magit-git-insert "cat-file" "-p" (concat rev ":" file)))
    (setq magit-buffer-revision  (magit-rev-format "%H" rev)
          magit-buffer-refname   rev
          magit-buffer-file-name (expand-file-name file (magit-get-top-dir)))
    (let ((buffer-file-name magit-buffer-file-name))
      (normal-mode t))
    (setq buffer-read-only t)
    (set-buffer-modified-p nil)
    (goto-char (point-min))
    (run-hooks 'magit-find-file-hook)
    (current-buffer)))

(defun magit-find-file-index-noselect (file)
  (let* ((bufname (concat file ".~{index}~"))
         (origbuf (get-buffer bufname)))
    (with-current-buffer (get-buffer-create bufname)
      (when (or (not origbuf)
                (y-or-n-p (format "%s already exists; revert it? " bufname)))
        (let ((inhibit-read-only t)
              (temp (car (split-string
                          (magit-git-string "checkout-index" "--temp" file)
                          "\t"))))
          (erase-buffer)
          (insert-file-contents temp nil nil nil t)
          (delete-file temp)))
      (setq magit-buffer-revision  "{index}"
            magit-buffer-refname   "{index}"
            magit-buffer-file-name (expand-file-name file (magit-get-top-dir)))
      (let ((buffer-file-name magit-buffer-file-name))
        (normal-mode t))
      (setq buffer-read-only t)
      (set-buffer-modified-p nil)
      (goto-char (point-min))
      (run-hooks 'magit-find-index-hook)
      (current-buffer))))

(defun magit-update-index ()
  (interactive)
  (let ((file (magit-file-relative-name)))
    (unless (equal magit-buffer-refname "{index}")
      (user-error "%s isn't visiting the index" file))
    (unless (y-or-n-p (format "Update index with contents of %s" (buffer-name)))
      (user-error "Abort"))
    (let ((index (make-temp-file "index"))
          (buffer (current-buffer)))
      (with-temp-file index
        (insert-buffer-substring buffer))
      (magit-call-git "update-index" "--cacheinfo"
                      (substring (magit-git-string "ls-files" "-s" file) 0 6)
                      (magit-git-string "hash-object" "-t" "blob" "-w"
                                        (concat "--path=" file)
                                        "--" index)
                      file))
    (set-buffer-modified-p nil))
  (--when-let (magit-mode-get-buffer
               magit-status-buffer-name-format 'magit-status-mode)
    (with-current-buffer it (magit-refresh)))
  t)

(defun magit-visit-file (file &optional other-window)
  (interactive (list (magit-file-at-point) current-prefix-arg))
  (unless (file-exists-p file)
    (user-error "Can't visit deleted file: %s" file))
  (if (file-directory-p file)
      (progn
        (setq file (file-name-as-directory (expand-file-name file)))
        (if (equal (magit-get-top-dir (file-name-directory file))
                   (magit-get-top-dir))
            (magit-dired-jump other-window)
          (magit-status file (if other-window
                                 'pop-to-buffer
                               'switch-to-buffer))))
    (let ((pos (magit-section-when hunk
                 (magit-hunk-file-position it)))
          (buffer (or (get-file-buffer file)
                      (find-file-noselect file))))
      (if (or other-window (get-buffer-window buffer))
          (pop-to-buffer buffer)
        (switch-to-buffer buffer))
      (when pos
        (goto-char (point-min))
        (forward-line (1- (car pos)))
        (move-to-column (cdr pos))))
    (when (magit-anything-unmerged-p file)
      (smerge-start-session))))

(defun magit-hunk-file-position (section)
  (let* ((value (magit-section-value section))
         (hunk-line (line-number-at-pos (point)))
         (goto-line (car (last value)))
         (offset (- (length value) 2))
         (column (current-column)))
    (save-excursion
      (string-match "^\\+\\([0-9]+\\)" goto-line)
      (setq goto-line (string-to-number (match-string 1 goto-line)))
      (goto-char (magit-section-content section))
      (while (< (line-number-at-pos) hunk-line)
        (unless (string-match-p
                 "-" (buffer-substring (point) (+ (point) offset)))
          (cl-incf goto-line))
        (forward-line))
      (cons goto-line (if (looking-at "-") 0 (max 0 (- column offset)))))))

;;;###autoload
(defun magit-dired-jump (&optional other-window)
  "Visit file at point using Dired.
With a prefix argument, visit in other window.  If there
is no file at point then instead visit `default-directory'."
  (interactive "P")
  (dired-jump other-window
              (file-truename (or (magit-file-at-point) default-directory))))

;;; Manipulate
;;;; Init

;;;###autoload
(defun magit-init (directory)
  "Create or reinitialize a Git repository.
Read directory name and initialize it as new Git repository.

If the directory is below an existing repository, then the user
has to confirm that a new one should be created inside; or when
the directory is the root of the existing repository, whether
it should be reinitialized.

Non-interactively DIRECTORY is always (re-)initialized."
  (interactive
   (let* ((dir (file-name-as-directory
                (expand-file-name
                 (read-directory-name "Create repository in: "))))
          (top (magit-get-top-dir dir)))
     (if (and top
              (not (yes-or-no-p
                    (if (string-equal top dir)
                        (format "Reinitialize existing repository %s? " dir)
                      (format "%s is a repository.  Create another in %s? "
                              top dir)))))
         (user-error "Abort")
       (list dir))))
  (magit-run-git "init" (expand-file-name directory)))

;;;; Branch

(magit-define-popup magit-branch-popup
  "Popup console for branch commands."
  'magit-popups
  :man-page "git-branch"
  :switches '((?t "Set upstream configuration" "--track"))
  :actions  '((?b "Checkout"          magit-checkout)
              (?c "Create"            magit-branch)
              (?B "Create & Checkout" magit-branch-and-checkout)
              (?u "Set upstream"      magit-branch-set-upstream)
              (?r "Rename"            magit-branch-rename)
              (?k "Delete"            magit-branch-delete))
  :default-arguments '("--track")
  :default-action 'magit-checkout)

;;;###autoload
(defun magit-checkout (revision)
  "Checkout REVISION, updating the index and the working tree.
If REVISION is a local branch then that becomes the current
branch.  If it is something else then `HEAD' becomes detached.
Checkout fails if the working tree or the staging area contain
changes.
\n(git checkout REVISION)."
  (interactive (list (magit-read-other-branch-or-commit "Checkout")))
  (magit-run-git "checkout" revision))

(defun magit-branch (branch start-point &optional args)
  "Create BRANCH at branch or revision START-POINT.
\n(git branch [ARGS] BRANCH START-POINT)."
  (interactive (magit-branch-read-args "Create branch"))
  (magit-run-git "branch" args branch start-point))

;;;###autoload
(defun magit-branch-and-checkout (branch start-point &optional args)
  "Create and checkout BRANCH at branch or revision START-POINT.
\n(git checkout [ARGS] -b BRANCH START-POINT)."
  (interactive (magit-branch-read-args "Create and checkout branch"))
  (magit-run-git "checkout" args "-b" branch start-point))

(defun magit-branch-read-args (prompt)
  (let* ((args magit-current-popup-args)
         (start (magit-read-branch-or-commit (concat prompt " starting at")))
         (branch
          (magit-read-string
           "Branch name"
           (and (member start (magit-list-remote-branch-names))
                (mapconcat #'identity (cdr (split-string start "/")) "/")))))
    (when (and (member "--track" args)
               (not (magit-branch-p start)))
      (setq args (delete "--track" args)))
    (list branch start args)))

;;;###autoload
(defun magit-branch-delete (branch &optional force)
  "Delete BRANCH.
Without a prefix argument deleting a branch that hasn't been
merged will fail.  With a prefix argument the deletion is forced.
When BRANCH is the current branch offer to first detach HEAD or
checkout the \"master\" branch.
\n(git branch -d|-D BRANCH || git push REMOTE :BRANCH)."
  (interactive (list (magit-read-branch (if current-prefix-arg
                                            "Force delete branch"
                                          "Delete branch")
                                        (magit-get-previous-branch))
                     current-prefix-arg))
  (let ((ref (magit-ref-fullname branch)))
    (unless ref
      (error "%s cannot be resolved" branch))
    (if (string-match "^refs/remotes/\\([^/]+\\)/\\(.+\\)" ref)
        (magit-run-git-async "push"      (match-string 1 ref)
                             (concat ":" (match-string 2 ref)))
      (cl-case (when (equal ref (magit-ref-fullname (magit-get-current-branch)))
                 (let ((msg (format "Branch %s is checked out.  " branch)))
                   (if (or (equal ref "refs/heads/master")
                           (not (magit-ref-exists-p "refs/heads/master")))
                       (magit-read-char-case msg nil
                         (?d "[d]etach HEAD & delete" 'detach)
                         (?a "[a]bort"                'abort))
                     (magit-read-char-case msg nil
                       (?d "[d]etach HEAD & delete"     'detach)
                       (?c "[c]heckout master & delete" 'master)
                       (?a "[a]bort"                    'abort)))))
        (detach (setq force t) (magit-call-git "checkout" "--detach"))
        (master (setq force t) (magit-call-git "checkout" "master"))
        (abort  (user-error "Branch %s not deleted" branch)))
      (magit-run-git "branch" (if force "-D" "-d") branch))))

;;;###autoload
(defun magit-branch-set-upstream (branch upstream)
  "Change the UPSTREAM branch of BRANCH."
  (interactive
   (let ((b (magit-read-local-branch "Change upstream of branch")))
     (list b (magit-read-other-branch "Change upstream to branch" b))))
  (if upstream
      (magit-run-git "branch" (concat "--set-upstream-to=" upstream) branch)
    (magit-run-git "branch" "--unset-upstream" branch)))

;;;###autoload
(defun magit-request-pull (url start)
  (interactive
   (let* ((remote (magit-read-remote "Remote"))
          (branch (magit-read-remote-branch "Branch" remote)))
     (list (magit-get "remote" remote "url")
           (magit-get-tracked-branch))))
  (let ((dir default-directory))
    ;; mu4e changes default-directory
    (compose-mail)
    (setq default-directory dir))
  (message-goto-body)
  (process-file magit-git-executable nil t nil "request-pull" start url)
  (set-buffer-modified-p nil))

;;;###autoload
(defun magit-branch-rename (old new &optional force)
  "Rename branch OLD to NEW.
With prefix, forces the rename even if NEW already exists.
\n(git branch -m|-M OLD NEW)."
  (interactive
   (let ((branch (magit-read-local-branch "Rename branch")))
     (list branch
           (magit-read-string (format "Rename branch '%s' to" branch))
           current-prefix-arg)))
  (unless (string= old new)
    (magit-run-git "branch" (if force "-M" "-m") old new)))

;;;###autoload
(defun magit-branch-edit-description (branch)
  "Edit the description of BRANCH."
  (interactive (list (magit-read-local-branch "Edit branch description")))
  (magit-run-git-with-editor "branch" "--edit-description"))

(defun magit-insert-branch-description ()
  (let ((branch (magit-get-current-branch)))
    (--when-let (magit-git-lines
                 "config" (format "branch.%s.description" branch))
      (magit-insert-section (branchdesc branch t)
        (magit-insert-heading branch ": " (car it))
        (insert (mapconcat 'identity (cdr it) "\n"))
        (insert "\n\n")))))

;;;; Merge

(magit-define-popup magit-merge-popup
  "Popup console for merge commands."
  'magit-popups 'magit-popup-sequence-mode
  :man-page "git-merge"
  :switches '((?f "Fast-forward only" "--ff-only")
              (?n "No fast-forward"   "--no-ff")
              (?s "Squash"            "--squash"))
  :options  '((?s "Strategy" "--strategy=" read-from-minibuffer))
  :actions  '((?m "Merge"                  magit-merge)
              (?e "Merge and edit message" magit-merge-editmsg)
              (?n "Merge but don't commit" magit-merge-nocommit))
  :sequence-actions   '((?c "Commit merge" magit-commit)
                        (?a "Abort merge"  magit-merge-abort))
  :sequence-predicate 'magit-merge-state
  :default-action 'magit-merge)

;;;###autoload
(defun magit-merge (rev &optional args nocommit)
  "Merge commit REV into the current branch; using default message.

Unless there are conflicts or a prefix argument is used create a
merge commit using a generic commit message and without letting
the user inspect the result.  With a prefix argument pretend the
merge failed to give the user the opportunity to inspect the
merge.

\(git merge --no-edit|--no-commit [ARGS] REV)"
  (interactive (list (magit-read-other-branch-or-commit "Merge")
                     magit-current-popup-args
                     current-prefix-arg))
  (magit-merge-assert)
  (magit-run-git "merge" (if nocommit "--no-commit" "--no-edit") args rev))

;;;###autoload
(defun magit-merge-editmsg (rev &optional args)
  "Merge commit REV into the current branch; and edit message.
Perform the merge and prepare a commit message but let the user
edit it.
\n(git merge --edit [ARGS] rev)"
  (interactive (list (magit-read-other-branch-or-commit "Merge")
                     magit-current-popup-args))
  (magit-merge-assert)
  (magit-run-git-with-editor "merge" "--edit" args rev))

;;;###autoload
(defun magit-merge-nocommit (rev &optional args)
  "Merge commit REV into the current branch; pretending it failed.
Pretend the merge failed to give the user the opportunity to
inspect the merge and change the commit message.
\n(git merge --no-commit [ARGS] rev)"
  (interactive (list (magit-read-other-branch-or-commit "Merge")
                     magit-current-popup-args))
  (magit-merge-assert)
  (magit-run-git "merge" "--no-commit" args rev))

;;;###autoload
(defun magit-merge-abort ()
  "Abort the current merge operation.
\n(git merge --abort)"
  (interactive)
  (if (file-exists-p (magit-git-dir "MERGE_HEAD"))
      (when (magit-confirm 'abort-merge "Abort merge")
        (magit-run-git-async "merge" "--abort"))
    (user-error "No merge in progress")))

(defun magit-checkout-stage (file arg &optional restore-conflict)
  "During a conflict checkout and stage side, or restore conflict."
  (interactive
   (let ((default-directory (magit-get-top-dir))
         (file (magit-completing-read "Checkout file"
                                      (magit-tracked-files) nil nil nil
                                      'magit-read-file-hist
                                      (magit-current-file))))
     (cond
      ((member file (magit-unmerged-files))
       (list file (magit-checkout-read-stage file)))
      ((yes-or-no-p (format "Restore conflicts in %s? " file))
       (list file "--merge" t))
      (t
       (user-error "Quit")))))
  (if restore-conflict
      (progn
        (with-temp-buffer
          (insert "0 0000000000000000000000000000000000000000\t" file "\n")
          (--> (magit-git-string "ls-tree" (magit-git-string
                                            "merge-base" "MERGE_HEAD" "HEAD")
                                 file)
            (replace-regexp-in-string "\t" " 1\t" it)
            (insert it "\n"))
          (--> (magit-git-string "ls-tree" "HEAD" file)
            (replace-regexp-in-string "\t" " 2\t" it)
            (insert it "\n"))
          (--> (magit-git-string "ls-tree" "MERGE_HEAD" file)
            (replace-regexp-in-string "\t" " 3\t" it)
            (insert it "\n"))
          (magit-run-git-with-input nil "checkout" arg file))
        (magit-refresh))
    (magit-call-git "checkout" arg file)
    (if (string= arg "--merge")
        (magit-refresh)
      (magit-run-git "add" file))))

(defun magit-merge-state ()
  (file-exists-p (magit-git-dir "MERGE_HEAD")))

(defun magit-merge-assert ()
  (or (not (magit-anything-modified-p))
      (not magit-merge-warn-dirty-worktree)
      (magit-confirm
       'merge-dirty
       "Running merge in a dirty worktree could cause data loss.  Continue")
      (user-error "Abort")))

(defun magit-checkout-read-stage (file)
  (magit-read-char-case (format "For %s checkout: " file) t
    (?o "[o]ur stage"   "--ours")
    (?t "[t]heir stage" "--theirs")
    (?c "[c]onflict"    "--merge")))

(defun magit-insert-merge-log ()
  (-when-let (heads (mapcar 'magit-get-shortname
                            (magit-file-lines (magit-git-dir "MERGE_HEAD"))))
    (magit-insert-section (commit (car heads))
      (magit-insert-heading
        (format "Merging %s:" (mapconcat 'identity heads ", ")))
      (magit-insert-log
       (concat (magit-git-string "merge-base" "--octopus" "HEAD" (car heads))
               ".." (car heads))
       (let ((args magit-log-section-args))
         (unless (member "--decorate=full" magit-log-section-args)
           (push "--decorate=full" args))
         args)))))

;;;; Reset

;;;###autoload
(defun magit-reset-index (commit)
  "Reset the index to COMMIT.
Keep the head and working tree as-is, so if COMMIT refers to the
head this effectivley unstages all changes.
\n(git reset --mixed COMMIT)"
  (interactive (list (magit-read-branch-or-commit "Reset index to")))
  (magit-run-git "reset" commit "--"))

;;;###autoload
(defun magit-reset (commit &optional hard)
  "Reset the head and index to COMMIT, but not the working tree.
With a prefix argument also reset the working tree.
\n(git reset --mixed|--hard COMMIT)"
  (interactive (list (magit-read-branch-or-commit
                      (if current-prefix-arg
                          "Hard reset to"
                        "Reset head to"))
                     current-prefix-arg))
  (unless hard
    (magit-maybe-save-head-message commit))
  (magit-run-git "reset" (if hard "--hard" "--mixed") commit "--"))

;;;###autoload
(defun magit-reset-head (commit)
  "Reset the head and index to COMMIT, but not the working tree.
\n(git reset --mixed COMMIT)"
  (interactive (list (magit-read-branch-or-commit "Reset head to")))
  (magit-maybe-save-head-message commit)
  (magit-run-git "reset" "--mixed" commit "--"))

;;;###autoload
(defun magit-reset-soft (commit)
  "Reset the head to COMMIT, but not the index and working tree.
\n(git reset --soft REVISION)"
  (interactive (list (magit-read-branch-or-commit "Soft reset to")))
  (magit-maybe-save-head-message commit)
  (magit-run-git "reset" "--soft" commit "--"))

;;;###autoload
(defun magit-reset-hard (commit)
  "Reset the head, index, and working tree to COMMIT.
\n(git reset --hard REVISION)"
  (interactive (list (magit-read-branch-or-commit "Hard reset to")))
  (magit-run-git "reset" "--hard" commit "--"))

(defun magit-maybe-save-head-message (commit)
  (when (equal (magit-rev-parse commit)
               (magit-rev-parse "HEAD~"))
    (with-temp-buffer
      (magit-git-insert "show" "-s" "--format=%B" "HEAD")
      (when git-commit-major-mode
        (funcall git-commit-major-mode))
      (git-commit-setup-font-lock)
      (git-commit-save-message))))

;;; Miscellaneous
;;;; Tag

(magit-define-popup magit-tag-popup
  "Popup console for tag commands."
  'magit-popups
  :man-page "git-tag"
  :switches '((?a "Annotate" "--annotate")
              (?s "Sign"     "--sign")
              (?f "Force"    "--force"))
  :actions  '((?t "Create"   magit-tag)
              (?k "Delete"   magit-tag-delete)
              (?p "Prune"    magit-tag-prune))
  :default-action 'magit-tag)

;;;###autoload
(defun magit-tag (name rev &optional args)
  "Create a new tag with the given NAME at REV.
With a prefix argument annotate the tag.
\n(git tag [--annotate] NAME REV)"
  (interactive (list (magit-read-tag "Tag name")
                     (magit-read-branch-or-commit "Place tag on")
                     (let ((args magit-current-popup-args))
                       (when current-prefix-arg
                         (add-to-list 'args "--annotate"))
                       args)))
  (magit-run-git-with-editor "tag" args name rev))

;;;###autoload
(defun magit-tag-delete (tags)
  "Delete one or more tags.
If the region marks multiple tags (and nothing else), then offer
to delete those, otherwise prompt for a single tag to be deleted,
defaulting to the tag at point.
\n(git tag -d TAGS)"
  (interactive
   (let ((tags (magit-current-sections 'tag)))
     (if (> (length tags) 1)
         (if (magit-confirm 'delete-tags "Delete %i tags" tags)
             (list tags)
           (user-error "Abort"))
       (list (magit-read-tag "Delete tag" t)))))
  (magit-run-git "tag" "-d" tags))

(defun magit-tag-prune (tags remote-tags remote)
  "Offer to delete tags missing locally from REMOTE, and vice versa."
  (interactive
   (let* ((remote (magit-read-remote "Prune tags using remote"))
          (tags   (magit-list-tags))
          (rtags  (prog2 (message "Determining remote tags...")
                      (magit-list-remote-tags remote)
                    (message "Determining remote tags...done")))
          (ltags  (-difference tags rtags))
          (rtags  (-difference rtags tags)))
     (unless (or ltags rtags)
       (message "Same tags exist locally and remotely"))
     (when ltags
       (unless (if (> (length ltags) 1)
                   (magit-confirm t "Delete %i tags locally" ltags)
                 (magit-confirm t (format "Delete %s locally" (car ltags))))
         (setq ltags nil)))
     (when rtags
       (unless (if (> (length rtags) 1)
                   (magit-confirm t "Delete %i tags from remote" rtags)
                 (magit-confirm t (format "Delete %s from remote" (car rtags))))
         (setq rtags nil)))
     (list ltags rtags remote)))
  (when tags
    (magit-run-git "tag" "-d" tags))
  (when remote-tags
    (magit-run-git-async "push" remote (--map (concat ":" it) remote-tags))))

;;;; Notes

(magit-define-popup magit-notes-popup
  "Popup console for notes commands."
  'magit-popups 'magit-popup-sequence-mode
  :man-page "git-tag"
  :switches '((?n "Dry run"          "--dry-run"))
  :options  '((?r "Manipulate ref"   "--ref="      magit-notes-popup-read-ref)
              (?s "Merge strategy"   "--strategy=" read-from-minibuffer))
  :actions  '((?T "Edit"             magit-notes-edit)
              (?r "Remove"           magit-notes-remove)
              (?m "Merge"            magit-notes-merge)
              (?p "Prune"            magit-notes-prune)
              (?s "Set ref"          magit-notes-set-ref)
              (?S "Set display refs" magit-notes-set-display-refs))
  :sequence-actions '((?c "Commit merge" magit-notes-merge-commit)
                      (?a "Abort merge"  magit-notes-merge-abort))
  :sequence-predicate 'magit-notes-merging-p
  :default-action 'magit-notes-edit)

(defun magit-notes-edit (commit &optional ref)
  (interactive (magit-notes-read-args "Edit notes"))
  (magit-run-git-with-editor "notes" (and ref (concat "--ref=" ref))
                             "edit" commit))

(defun magit-notes-remove (commit &optional ref)
  (interactive (magit-notes-read-args "Remove notes"))
  (magit-run-git-with-editor "notes" "remove" commit))

(defun magit-notes-merge (ref)
  (interactive (list (magit-read-string "Merge reference")))
  (magit-run-git-with-editor "notes" "merge" ref))

(defun magit-notes-merge-commit ()
  (interactive)
  (magit-run-git-with-editor "notes" "merge" "--commit"))

(defun magit-notes-merge-abort ()
  (interactive)
  (magit-run-git-with-editor "notes" "merge" "--abort"))

(defun magit-notes-prune (&optional dry-run)
  (interactive (list (and (member "--dry-run" magit-current-popup-args) t)))
  (when dry-run
    (magit-process))
  (magit-run-git-with-editor "notes" "prune" (and dry-run "--dry-run")))

(defun magit-notes-set-ref (ref &optional global)
  (interactive
   (list (magit-completing-read "Set notes ref"
                                (nconc (list "refs/" "refs/notes/")
                                       (magit-list-notes-refnames))
                                nil nil
                                (--when-let (magit-get "core.notesRef")
                                  (if (string-match "^refs/notes/\\(.+\\)" it)
                                      (match-string 1 it)
                                    it)))
         current-prefix-arg))
  (if ref
      (magit-run-git "config" (and global "--global") "core.notesRef"
                     (if (string-prefix-p "refs/" ref)
                         ref
                       (concat "refs/notes/" ref)))
    (magit-run-git "config" "--unset" "core.notesRef")))

(defun magit-notes-set-display-refs (refs &optional global)
  (interactive
   (list (magit-completing-read "Set additional notes ref(s)"
                                (nconc (list "refs/" "refs/notes/")
                                       (magit-list-notes-refnames))
                                nil nil
                                (mapconcat #'identity
                                           (magit-get-all "notes.displayRef")
                                           ":"))
         current-prefix-arg))
  (when (and refs (atom refs))
    (setq refs (split-string refs ":")))
  (when global
    (setq global "--global"))
  (magit-git-success "config" "--unset-all" global "notes.displayRef")
  (dolist (ref refs)
    (magit-call-git "config" "--add" global "notes.displayRef" ref))
  (magit-refresh))

(defun magit-notes-read-args (prompt)
 (list (magit-read-branch-or-commit prompt)
       (--when-let (--first (string-match "^--ref=\\(.+\\)" it)
                            magit-current-popup-args)
         (match-string 1 it))))

(defun magit-notes-popup-read-ref (prompt &optional initial-input)
  (magit-completing-read prompt (nconc (list "refs/" "refs/notes/")
                                       (magit-list-notes-refnames))
                         nil nil initial-input))

(defun magit-notes-merging-p ()
  (let ((dir (magit-git-dir "NOTES_MERGE_WORKTREE")))
    (and (file-directory-p dir)
         (directory-files dir nil "^[^.]"))))

;;;; Stash

(magit-define-popup magit-stash-popup
  "Popup console for stash commands."
  'magit-popups
  :man-page "git-stash"
  :switches '((?k "Don't stash index"       "--keep-index")
              (?u "Include untracked files" "--include-untracked")
              (?a "Include all files"       "--all"))
  :actions  '((?z "Save"           magit-stash)
              (?s "Snapshot"       magit-stash-snapshot)
              (?p "Pop"            magit-stash-pop)
              (?k "Drop"           magit-stash-drop)
              (?Z "Save index"     magit-stash-index)
              (?S "Snapshot index" magit-stash-index-snapshot)
              (?a "Apply"          magit-stash-apply)
              (?b "Branch"         magit-stash-branch)
              (?v "View"           magit-diff-stash))
  :default-action 'magit-stash
  :max-action-columns 4)

;;;###autoload
(defun magit-stash (description &optional args)
  "Create new stash of working tree and staging area named DESCRIPTION.
Working tree and staging area revert to the current `HEAD'.
With prefix argument, changes in staging area are kept.
\n(git stash save [ARGS] DESCRIPTION)"
  (interactive (list (read-string "Stash message: ")
                     (magit-current-popup-args)))
  (magit-run-git "stash" "save" args "--" description))

;;;###autoload
(defun magit-stash-snapshot (&optional args)
  "Create new stash of working tree and staging area; keep changes in place.
\n(git stash save [ARGS] \"Snapshot...\";
 git stash apply stash@{0})"
  (interactive (list (magit-current-popup-args)))
  (magit-call-git "stash" "save" args (magit-rev-format "Snapshot: %h %s"))
  (magit-run-git "stash" "apply" "stash@{0}" "--index"))

(defun magit-stash-index (message &optional snapshot)
  "Create a new stash of the index only."
  (interactive (list (read-string "Stash message: ")))
  (error "This command may EAT YOUR DATA!  Disabled until fixed")
  (magit-git-string "stash" "save" "--keep-index" (concat "(" message ")"))
  (let ((both (magit-rev-parse "refs/stash")))
    (message "Saved working directory and index state in %s" both)
    (magit-call-git "stash" "drop")
    (magit-call-git "stash" "save" message)
    (if snapshot
        (magit-run-git "stash" "pop" "--index" both)
      (with-temp-buffer
        (magit-git-insert "diff" (concat "stash@{0}.." both))
        (magit-run-git-with-input nil "apply"))
      (magit-refresh))))

(defun magit-stash-index-snapshot ()
  "Create a new stash of the index only; keep changes in place."
  (interactive)
  (magit-stash-index (magit-rev-format "Snapshot: %h %s") t))

(defun magit-stash-apply (stash)
  "Apply a stash to the working tree.
Try to preserve the stash index.  If that fails because there
are staged changes, apply without preserving the stash index."
  (interactive (list (magit-read-stash "Apply stash" t)))
  (if (magit-git-success "stash" "apply" "--index" stash)
      (magit-refresh)
    (magit-run-git "stash" "apply" stash)))

(defun magit-stash-pop (stash)
  "Apply a stash to the working tree and remove it from stash list.
Try to preserve the stash index.  If that fails because there
are staged changes, apply without preserving the stash index
and forgo removing the stash."
  (interactive (list (magit-read-stash "Apply pop" t)))
  (if (magit-git-success "stash" "pop" "--index" stash)
      (magit-refresh)
    (magit-run-git "stash" "apply" stash)))

(defun magit-stash-drop (stash)
  "Remove a stash from the stash list.
When the region is active offer to drop all contained stashes.
\n(git stash drop stash@{N})"
  (interactive
   (if (use-region-p)
       (let ((stashes (magit-section-region-siblings 'magit-section-value)))
         (when (magit-confirm 'drop-stashes "Drop %i stashes" stashes)
           (deactivate-mark t)
           (list stashes)))
     (list (magit-read-stash "Drop stash"))))
  (if (listp stash)
      (mapc 'magit-stash-drop (nreverse stash))
    (magit-run-git "stash" "drop" stash)))

(defun magit-stash-branch (stash branchname)
  "Create and checkout a branch from STASH.
\n(git stash branch BRANCHNAME stash@{N})"
  (interactive (list (magit-read-stash  "Branch stash" t)
                     (magit-read-string "Branch name")))
  (magit-run-git "stash" "branch" branchname stash))

(defvar magit-stash-section-map
  (let ((map (make-sparse-keymap)))
    (define-key map "\r" 'magit-diff-stash)
    (define-key map "a"  'magit-stash-apply)
    (define-key map "A"  'magit-stash-pop)
    (define-key map "k"  'magit-stash-drop)
    map)
  "Keymap for `stash' sections.")

(magit-define-section-jumper stashes "Stashes")

(defun magit-insert-stashes ()
  (when (magit-rev-verify "refs/stash")
    (magit-insert-section (stashes)
      (magit-insert-heading "Stashes:")
      (magit-git-wash (apply-partially 'magit-log-wash-log 'stash)
        "-c" "log.date=default" ; kludge for <1.7.10.3, see #1427
        "reflog" "--format=%gd %at %gs" "refs/stash"))))

;;;; Submodules

(magit-define-popup magit-submodule-popup
  "Popup console for submodule commands."
  'magit-popups
  :man-page "git-submodule"
  :actions  '((?a "Add"    magit-submodule-add)
              (?b "Setup"  magit-submodule-setup)
              (?i "Init"   magit-submodule-init)
              (?u "Update" magit-submodule-update)
              (?s "Sync"   magit-submodule-sync)))

;;;###autoload
(defun magit-submodule-add (url &optional path)
  "Add the repository at URL as a submodule.
Optional PATH is the path to the submodule relative to the root
of the superproject. If it is nil then the path is determined
based on URL."
  (interactive
   (let* ((default-directory (magit-toplevel))
          (path (read-file-name
                 "Add submodule: " nil nil nil
                 (magit-section-when [file untracked]
                   (directory-file-name (magit-section-value it))))))
     (when path
       (setq path (file-name-as-directory (expand-file-name path)))
       (when (member path (list "" default-directory))
         (setq path nil)))
     (list (magit-read-string
            "Remote url"
            (and path (magit-git-repo-p path t)
                 (let ((default-directory path))
                   (magit-get "remote"
                              (or (magit-get-current-remote) "origin")
                              "url"))))
           (and path (directory-file-name (file-relative-name path))))))
  (magit-run-git "submodule" "add" url path))

;;;###autoload
(defun magit-submodule-setup ()
  "Clone and register missing submodules and checkout appropriate commits."
  (interactive)
  (magit-submodule-update t))

;;;###autoload
(defun magit-submodule-init ()
  "Register submodules listed in .gitmodules into .git/config."
  (interactive)
  (let ((default-directory (magit-get-top-dir)))
    (magit-run-git-async "submodule" "init")))

;;;###autoload
(defun magit-submodule-update (&optional init)
  "Clone missing submodules and checkout appropriate commits.
With a prefix argument also register submodules in .git/config."
  (interactive "P")
  (let ((default-directory (magit-get-top-dir)))
    (magit-run-git-async "submodule" "update" (and init "--init"))))

;;;###autoload
(defun magit-submodule-sync ()
  "Update each submodule's remote URL according to .gitmodules."
  (interactive)
  (let ((default-directory (magit-get-top-dir)))
    (magit-run-git-async "submodule" "sync")))

;;;; Dispatch Popup

(magit-define-popup magit-dispatch-popup
  "Popup console for dispatching other popups."
  'magit-popups
  :actions '((?b "Branching"       magit-branch-popup)
             (?B "Bisecting"       magit-bisect-popup)
             (?c "Committing"      magit-commit-popup)
             (?d "Diffing"         magit-diff-popup)
             (?f "Fetching"        magit-fetch-popup)
             (?F "Pulling"         magit-pull-popup)
             (?g "Refresh Buffers" magit-refresh-all)
             (?l "Logging"         magit-log-popup)
             (?m "Merging"         magit-merge-popup)
             (?M "Remoting"        magit-remote-popup)
             (?P "Pushing"         magit-push-popup)
             (?o "Submoduling"     magit-submodule-popup)
             (?r "Rebasing"        magit-rebase-popup)
             (?s "Show Status"     magit-status)
             (?S "Stage all"       magit-stage-modified)
             (?t "Tagging"         magit-tag-popup)
             (?U "Reset Index"     magit-reset-index)
             (?v "Show Commit"     magit-show-commit)
             (?V "Show File"       magit-find-file)
             (?y "Show Refs"       magit-show-refs)
             (?Y "Cherry"          magit-cherry)
             (?z "Stashing"        magit-stash-popup)
             (?! "Running"         magit-run-popup)
             (?$ "Show Process"    magit-display-process)))

;;;; Git Popup

(defvar magit-git-command-history nil)

(magit-define-popup magit-run-popup
  "Popup console for running raw Git commands."
  'magit-popups
  :actions '((?! "Git Subcommand (from root)" magit-git-command-topdir)
             (?: "Git Subcommand (from pwd)" magit-git-command)
             (?g "Git Gui" magit-run-git-gui)
             (?k "Gitk" magit-run-gitk))
  :default-action 'magit-git-command)

;;;###autoload
(defun magit-git-command (args directory)
  "Execute a Git subcommand asynchronously, displaying the output.
With a prefix argument run Git in the root of the current
repository.  Non-interactively run Git in DIRECTORY with ARGS."
  (interactive (magit-git-command-read-args))
  (require 'eshell)
  (magit-mode-display-buffer (magit-process-buffer)
                             'magit-process-mode 'pop-to-buffer)
  (goto-char (point-max))
  (let ((default-directory directory))
    (magit-run-git-async
     (with-temp-buffer
       (insert args)
       (mapcar 'eval (eshell-parse-arguments (point-min)
                                             (point-max)))))))

(defun magit-git-command-topdir (args directory)
  "Execute a Git subcommand asynchronously, displaying the output.
Run Git in the root of the current repository.
\n(fn)" ; arguments are for internal use
  (interactive (magit-git-command-read-args t))
  (magit-git-command args directory))

(defun magit-git-command-read-args (&optional root)
  (let ((dir (if (or root current-prefix-arg)
                 (or (magit-get-top-dir)
                     (user-error "Not inside a Git repository"))
               default-directory)))
    (list (magit-read-string (format "Git subcommand (in %s)"
                                     (abbreviate-file-name dir))
                             nil 'magit-git-command-history)
          dir)))

;;;; Read Repository

(defun magit-read-top-dir (dir)
  "Ask the user for a Git repository."
  (if (and (not dir) magit-repository-directories)
      (let* ((repos (magit-list-repos-uniquify
                     (--map (cons (file-name-nondirectory it) it)
                            (magit-list-repos))))
             (reply (magit-completing-read "Git repository" repos)))
        (file-name-as-directory
         (or (cdr (assoc reply repos))
             (if (file-directory-p reply)
                 (expand-file-name reply)
               (user-error "Not a repository or a directory: %s" reply)))))
    (file-name-as-directory
     (read-directory-name "Git repository: "
                          (or (magit-get-top-dir) default-directory)))))

(defun magit-list-repos ()
  (--mapcat (magit-list-repos* it magit-repository-directories-depth)
            magit-repository-directories))

(defun magit-list-repos* (directory depth)
  (cond ((file-readable-p (expand-file-name ".git" directory))
         (list directory))
        ((and (> depth 0) (file-accessible-directory-p directory))
         (cl-loop for file in (directory-files directory t "^[^.]" t)
                  when (file-directory-p file)
                  append (magit-list-repos* file (1- depth))))))

(defun magit-list-repos-uniquify (alist)
  (let (result (dict (make-hash-table :test 'equal)))
    (dolist (a (delete-dups alist))
      (puthash (car a) (cons (cdr a) (gethash (car a) dict)) dict))
    (maphash
     (lambda (key value)
       (if (= (length value) 1)
           (push (cons key (car value)) result)
         (setq result
               (append result
                       (magit-list-repos-uniquify
                        (--map (cons (concat
                                      key "\\"
                                      (file-name-nondirectory
                                       (directory-file-name
                                        (substring it 0 (- (length key))))))
                                     it)
                               value))))))
     dict)
    result))

;;;; Various

;;;###autoload
(defun magit-format-patch (range)
  (interactive
   (let ((revs (magit-current-sections 'commit)))
     (setq revs (nreverse (mapcar 'magit-section-value revs)))
     (list (if (or current-prefix-arg (not revs))
               (magit-read-range-or-commit "Format range")
             (concat (car revs) "^.." (car (last revs)))))))
  (magit-run-git "format-patch" range))

(defun magit-copy-as-kill ()
  "Copy the thing at point into the kill ring."
  (interactive)
  (magit-section-when (branch commit mcommit file)
    (kill-new (message "%s" (magit-section-value it)))))

;;; magit.el ends soon

(defconst magit-font-lock-keywords
  (eval-when-compile
    `((,(concat "(\\(magit-define-section-jumper\\)\\_>"
                "[ \t'\(]*"
                "\\(\\(?:\\sw\\|\\s_\\)+\\)?")
       (1 font-lock-keyword-face)
       (2 font-lock-function-name-face nil t))
      (,(concat "(" (regexp-opt '("magit-insert-section"
                                  "magit-section-case"
                                  "magit-section-when"
                                  "magit-bind-match-strings"
                                  "magit-with-temp-index"
                                  "magit-with-blob") t)
                "\\_>")
       . 1))))

(font-lock-add-keywords 'emacs-lisp-mode magit-font-lock-keywords)

(defvar magit-version 'undefined
  "The version of Magit that you're using.
Use the function by the same name instead of this variable.")

(defun magit-version (&optional noerror)
  "The version of Magit that you're using.\n\n\(fn)"
  (interactive)
  (let ((toplib (or load-file-name buffer-file-name)))
    (unless (and toplib
                 (equal (file-name-nondirectory toplib) "magit.el"))
      (setq toplib (locate-library "magit.el")))
    (when toplib
      (let* ((dir (file-name-directory toplib))
             (static (expand-file-name "magit-version.el" dir))
             (gitdir (expand-file-name ".git" dir)))
        (cond ((file-exists-p gitdir)
               (setq magit-version
                     (let ((default-directory dir))
                       (magit-git-string "describe" "--tags" "--dirty")))
               (ignore-errors (delete-file static)))
              ((file-exists-p static)
               (load-file static))
              ((featurep 'package)
               (setq magit-version
                     (or (and (fboundp 'package-desc-vers) ; < 24.3.50
                              (package-version-join
                               (package-desc-vers
                                (cdr (assq 'magit package-alist)))))
                         (and (fboundp 'package-desc-version) ; >= 24.3.50
                              (package-version-join
                               (package-desc-version
                                (cadr (assq 'magit package-alist)))))))))))
    (if (stringp magit-version)
        (when (called-interactively-p 'any)
          (message "magit-%s" magit-version))
      (if noerror
          (progn (setq magit-version 'error)
                 (message "Cannot determine Magit's version"))
        (error "Cannot determine Magit's version")))
    magit-version))

(cl-eval-when (load eval) (magit-version t))

(define-obsolete-variable-alias 'magit-highlight-whitespace 'magit-diff-highlight-whitespace)
(define-obsolete-variable-alias 'magit-highlight-trailing-whitespace 'magit-diff-highlight-trailing)
(define-obsolete-variable-alias 'magit-highlight-indentation 'magit-diff-highlight-indentation)
(define-obsolete-variable-alias 'magit-mode-refresh-buffer-hook 'magit-refresh-buffer-hook)
(define-obsolete-variable-alias 'magit-revert-backup 'magit-apply-backup)
(define-obsolete-variable-alias 'magit-show-child-count 'magit-section-show-child-count)
(define-obsolete-variable-alias 'magit-repo-dirs 'magit-repository-directories)
(define-obsolete-variable-alias 'magit-repo-dirs-depth 'magit-repository-directories-depth)

(provide 'magit)

(require 'magit-sequence)
(require 'magit-commit)
(require 'magit-remote)
(require 'magit-bisect)
(require 'magit-blame)
(require 'magit-ediff)
(require 'magit-extras)
(require 'magit-wip)

;; Local Variables:
;; coding: utf-8
;; indent-tabs-mode: nil
;; End:
;;; magit.el ends here
