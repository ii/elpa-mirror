;;; org-recent-headings.el --- Jump to recently used Org headings  -*- lexical-binding: t -*-

;; Author: Adam Porter <adam@alphapapa.net>
;; Url: http://github.com/alphapapa/org-recent-headings
;; Package-Version: 20190115.1540
;; Version: 0.1
;; Package-Requires: ((emacs "25.1") (org "9.0.5") (dash "2.13.0") (frecency "0.1"))
;; Keywords: hypermedia, outlines, Org

;;; Commentary:

;; This package keeps a list of recently used Org headings and lets
;; you quickly choose one to jump to by calling one of these commands:

;; The list is kept by advising functions that are commonly called to
;; access headings in various ways.  You can customize this list in
;; `org-recent-headings-advise-functions'.  Suggestions for additions
;; to the default list are welcome.

;; Note: This probably works with Org 8 versions, but it's only been
;; tested with Org 9.

;; This package makes use of handy functions and settings in
;; `recentf'.

;;; Installation:

;; Install from MELPA, or manually by putting this file in your
;; `load-path'.  Then put this in your init file:

;; (require 'org-recent-headings)
;; (org-recent-headings-mode)

;; You may also install Helm and/or Ivy, but they aren't required.

;;; Usage:

;; Activate `org-recent-headings-mode' to install the advice that will
;; track recently used headings.  Then play with your Org files by
;; going to headings from the Agenda, calling
;; `org-tree-to-indirect-buffer', etc.  Then call one of these
;; commands to jump to a heading:

;; + `org-recent-headings'
;; + `org-recent-headings-ivy'
;; + `org-recent-headings-helm'

;;; License:

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Code:

;; FIXME: Need way to transition from old list format automatically.

;;;; Requirements

(require 'cl-lib)
(require 'org)
(require 'recentf)
(require 'seq)

(require 'dash)
(require 'frecency)

;;;; Variables

(defvar org-recent-headings-debug nil
  "When non-nil, enable debug warnings.")

(defvar org-recent-headings-list nil
  ;; Similar to `org-refile-cache'.  List of lists, each in format
  ;;
  ;; ((:file file-path :id id :regexp heading-regexp) .
  ;;  (:display display-string :timestamps access-timestamps :num-timestamps number-of-access-timestamps))
  "List of recent Org headings.")

(defconst org-recent-headings-save-file-header
  ";;; Automatically generated by `org-recent-headings' on %s.\n"
  "Header to be written into the `org-recent-headings-save-file'.")

(defgroup org-recent-headings nil
  "Jump to recently used Org headings."
  :group 'org)

(defcustom org-recent-headings-advise-functions '(org-agenda-goto
                                                  org-agenda-show
                                                  org-agenda-show-mouse
                                                  org-show-entry
                                                  org-reveal
                                                  org-refile
                                                  org-tree-to-indirect-buffer
                                                  helm-org-parent-headings
                                                  helm-org-in-buffer-headings
                                                  helm-org-agenda-files-headings
                                                  org-bookmark-jump
                                                  helm-org-bookmark-jump-indirect)
  "Functions to advise to store recent headings.
Whenever one of these functions is called, the heading for the
entry at point will be added to the recent-headings list.  This
means that the point should be in a regular Org buffer (i.e. not
an agenda buffer)."
  ;; FIXME: This needs to toggle the mode when set, if it's active
  :type '(repeat function)
  :group 'org-recent-headings)

(defcustom org-recent-headings-store-heading-hooks '(org-capture-prepare-finalize-hook)
  "Hooks to add heading-storing function to."
  :type '(repeat variable))

(defcustom org-recent-headings-candidate-number-limit 10
  "Number of candidates to display in Helm source."
  :type 'integer)

(defcustom org-recent-headings-save-file (locate-user-emacs-file "org-recent-headings")
  "File to save the recent Org headings list into."
  :type 'file
  :initialize 'custom-initialize-default
  :set (lambda (symbol value)
         (let ((oldvalue (eval symbol)))
           (custom-set-default symbol value)
           (and (not (equal value oldvalue))
                org-recent-headings-mode
                (org-recent-headings--load-list)))))

(defcustom org-recent-headings-show-entry-function 'org-recent-headings--show-entry-indirect
  "Default function to use to show selected entries."
  :type '(radio (function :tag "Show entries in real buffers." org-recent-headings--show-entry-direct)
                (function :tag "Show entries in indirect buffers." org-recent-headings--show-entry-indirect)
                (function :tag "Custom function")))

(defcustom org-recent-headings-list-size 200
  "Maximum size of recent headings list."
  :type 'integer)

(defcustom org-recent-headings-reverse-paths nil
  "Reverse outline paths.
This way, the most narrowed-down heading will be listed first."
  :type 'boolean)

(defcustom org-recent-headings-truncate-paths-by 12
  "Truncate outline paths by this many characters.
Depending on your org-level faces, you may want to adjust this to
prevent paths from being wrapped onto a second line."
  :type 'integer)

(defcustom org-recent-headings-use-ids nil
  "Use Org IDs to jump to headings instead of regexp matchers.
Org IDs are more flexible, because Org may be able to find them
when headings are refiled to other files or locations.  However,
jumping by IDs may cause Org to load other Org files before
jumping, in order to find the IDs, which may cause delays, so
some users may prefer to just use regexp matchers."
  ;; FIXME: When the regexp test is removed, update this tag.
  :type '(radio (const :tag "Never; just use regexps" nil)
                (const :tag "When available" when-available)
                (const :tag "Always; create new IDs when necessary" always)))

;;;; Functions

(defun org-recent-headings--compare-keys (a b)
  "Return non-nil if A and B point to the same entry."
  (-let (((&plist :file a-file :id a-id :regexp a-regexp :outline-path a-outline-path) a)
         ((&plist :file b-file :id b-id :regexp b-regexp :outline-path b-outline-path) b))
    (when (and a-file b-file) ; Sanity check
      (or (when (and a-id b-id)
            ;; If the Org IDs are set and are the same, the entries point to
            ;; the same heading
            (string-equal a-id b-id))
          (when (and a-outline-path b-outline-path)
            ;; If both entries have outline-path in keys, compare file and olp
            (and (string-equal a-file b-file)
                 (equal a-outline-path b-outline-path)))
          (when (and a-regexp b-regexp)
            ;; NOTE: Very important to verify that both a-regexp and
            ;; b-regexp are non-nil, because `string-equal' returns t
            ;; if they are both nil.

            ;; Otherwise, if both the file path and regexp are the same,
            ;; they point to the same heading
            ;; FIXME: Eventually, remove this test when we remove :regexp
            (and (string-equal a-file b-file)
                 (string-equal a-regexp b-regexp)))))))

(defun org-recent-headings--compare-entries (a b)
  "Compare keys of cons cells A and B with `org-recent-headings--compare-keys'."
  (org-recent-headings--compare-keys (car a) (car b)))

(defun org-recent-headings--remove-duplicates ()
  "Remove duplicates from `org-recent-headings-list'."
  (cl-delete-duplicates org-recent-headings-list
                        :test #'org-recent-headings--compare-entries
                        :from-end t))

(defun org-recent-headings--show-entry-default (real)
  "Show heading specified by REAL using default function.
Default function set in `org-recent-headings-show-entry-function'."
  ;; This is for the Helm source, to allow it to make use of a
  ;; customized option setting the default function.  Maybe there's a
  ;; better way, but this works.
  (funcall org-recent-headings-show-entry-function real))

(defun org-recent-headings--show-entry-direct (real)
  "Go to heading specified by REAL.
REAL is a plist with `:file', `:id', and `:regexp' entries.  If
`:id' is non-nil, `:file' and `:regexp may be nil.'"
  (let ((marker (org-recent-headings--entry-marker real)))
    (switch-to-buffer (marker-buffer marker))
    (widen)
    (goto-char marker)
    (org-reveal)))

(defun org-recent-headings--show-entry-indirect (real)
  "Show heading specified by REAL in an indirect buffer.
REAL is a plist with `:file', `:id', and `:regexp' entries.  If
`:id' is non-nil, `:file' and `:regexp may be nil.'"
  ;; By using `save-excursion' and `save-restriction', this function doesn't
  ;; change the position or narrowing of the entry's underlying buffer.
  (let ((marker (org-recent-headings--entry-marker real)))
    (save-excursion
      (save-restriction
        (switch-to-buffer (marker-buffer marker))
        (widen)
        (goto-char marker)
        (org-reveal)
        (org-tree-to-indirect-buffer)))))

(defun org-recent-headings--entry-marker (real)
  "Return marker for entry specified by REAL.
Raises an error if entry can't be found."
  (let* ((file-path (plist-get real :file))
         (id (plist-get real :id))
         (regexp (plist-get real :regexp))
         (outline-path (plist-get real :outline-path))
         (buffer (or (org-find-base-buffer-visiting file-path)
                     (find-file-noselect file-path)
                     (unless id
                       ;; Don't give error if an ID, because Org might still be able to find it
                       (error "File not found: %s" file-path)))))
    (if buffer
        (with-current-buffer buffer
          (save-excursion
            (save-restriction
              (widen)
              (goto-char (point-min))
              ;; TODO: If showing the entry fails, optionally automatically remove it from list.
              ;; TODO: Factor out entry-finding into separate function.
              (cond (id (org-id-find id 'marker))
                    (outline-path (org-find-olp outline-path 'this-buffer))
                    (regexp (if (re-search-forward regexp nil t)
                                (point-marker)
                              (error "org-recent-headings: Couldn't find regexp for entry: %S" real)))
                    (t (error "org-recent-headings: No way to find entry: %S" real))))))
      ;; No buffer; let Org try to find it.
      ;; NOTE: Not sure if it's helpful to do this separately in the code above when `buffer' is set.
      (org-id-find id 'marker))))

(defun org-recent-headings--store-heading (&rest ignore)
  "Add current heading to `org-recent-headings' list."
  (-if-let* ((buffer (pcase major-mode
                       ('org-agenda-mode
                        (org-agenda-with-point-at-orig-entry
                         ;; Get buffer the agenda entry points to
                         (current-buffer)))
                       ('org-mode
                        ;;Get current buffer
                        (current-buffer))))
             (file-path (buffer-file-name (buffer-base-buffer buffer))))
      (with-current-buffer buffer
        (org-with-wide-buffer
         (unless (org-before-first-heading-p)
           (-when-let (heading (org-get-heading t t))
             ;; Heading is not empty
             (let* ((outline-path (if org-recent-headings-reverse-paths
                                      (s-join "\\" (nreverse (org-split-string (org-format-outline-path (org-get-outline-path t)
                                                                                                        1000 nil "")
                                                                               "")))
                                    (org-format-outline-path (org-get-outline-path t))))
                    (display (concat (file-name-nondirectory file-path)
                                     ":"
                                     outline-path))
                    (id (or (org-id-get)
                            (when (eq org-recent-headings-use-ids 'always)
                              (org-id-get-create))))
                    (outline-path (org-get-outline-path t))
                    (key (list :file file-path :id id :outline-path outline-path)))
               ;; Look for existing item
               (if-let ((existing (cl-assoc key org-recent-headings-list :test #'org-recent-headings--compare-keys))
                        (attrs (frecency-update (cdr existing) :get-fn #'plist-get :set-fn #'plist-put)))
                   ;; TODO: Try using `map-put' here instead of deleting and then re-adding.  Might
                   ;; fix this weird bug, too.  Or maybe we could use (setf (cl-getf)) or
                   ;; (cl--set-getf).
                   (progn
                     ;; Delete existing item
                     ;; NOTE: cl-delete-if is destructive, but it
                     ;; isn't working here, so we have to use setq and
                     ;; cl-remove-if.
                     (setq org-recent-headings-list (--remove (org-recent-headings--compare-keys (car it) key)
                                                              org-recent-headings-list))
                     (push (cons key attrs) org-recent-headings-list))
                 ;; No existing item; add new one
                 (push (cons key
                             (frecency-update (list :display display)
                               :get-fn #'plist-get
                               :set-fn #'plist-put))
                       org-recent-headings-list)))))))
    ;; NOTE: Going to try only sorting and trimming when the list is presented.
    ;; (cl-sort org-recent-headings-list #'> :key #'frecency-score)
    ;; (org-recent-headings--trim)
    (when org-recent-headings-debug
      (warn
       ;; If this happens, it probably means that a function should be
       ;; removed from `org-recent-headings-advise-functions'
       "`org-recent-headings--store-heading' called in non-Org buffer: %s.  Please report this bug." (current-buffer)))))

(defun org-recent-headings--trim ()
  "Trim recent headings list.
This assumes the list is already sorted.  Whichever entries are
at the end of the list, beyond the allowed list size, are
removed."
  (when (> (length org-recent-headings-list)
           org-recent-headings-list-size)
    (setq org-recent-headings-list (cl-subseq org-recent-headings-list
                                              0 org-recent-headings-list-size))))

(defun org-recent-headings--prepare-list ()
  "Sort and trim `org-recent-headings-list'."
  ;; FIXME: See task in notes.org.
  (setq org-recent-headings-list
        (-sort (-on #'> (lambda (item)
                          (frecency-score item :get-fn (lambda (item key)
                                                         (plist-get (cdr item) key)))))
               org-recent-headings-list))
  (org-recent-headings--trim))

;;;; File saving/loading

;; Mostly copied from `recentf'

(defun org-recent-headings--save-list ()
  "Save the recent Org headings list.
Write data into the file specified by `org-recent-headings-save-file'."
  (interactive)
  (condition-case err
      (with-temp-buffer
        (erase-buffer)
        (set-buffer-file-coding-system recentf-save-file-coding-system)
        (insert (format-message org-recent-headings-save-file-header
				(current-time-string)))
        (recentf-dump-variable 'org-recent-headings-list)
        (insert "\n\n;; Local Variables:\n"
                (format ";; coding: %s\n" recentf-save-file-coding-system)
                ";; End:\n")
        (write-file (expand-file-name org-recent-headings-save-file))
        (when recentf-save-file-modes
          (set-file-modes org-recent-headings-save-file recentf-save-file-modes))
        nil)
    (error
     (warn "org-recent-headings-mode: %s" (error-message-string err)))))

(defun org-recent-headings--load-list ()
  "Load a previously saved recent list.
Read data from the file specified by `org-recent-headings-save-file'."
  (interactive)
  (let ((file (expand-file-name org-recent-headings-save-file)))
    (when (file-readable-p file)
      (load-file file))))

;;;; Minor mode

;;;###autoload
(define-minor-mode org-recent-headings-mode
  "Global minor mode to keep a list of recently used Org headings so they can be quickly selected and jumped to.
With prefix argument ARG, turn on if positive, otherwise off."
  :global t
  (let ((advice-function (if org-recent-headings-mode
                             (lambda (to fun)
                               ;; Enable mode
                               (advice-add to :after fun))
                           (lambda (from fun)
                             ;; Disable mode
                             (advice-remove from fun))))
        (hook-setup (if org-recent-headings-mode 'add-hook 'remove-hook)))
    (dolist (target org-recent-headings-advise-functions)
      (when (fboundp target)
        (funcall advice-function target 'org-recent-headings--store-heading)))
    (dolist (hook org-recent-headings-store-heading-hooks)
      (funcall hook-setup hook 'org-recent-headings--store-heading))
    ;; Add/remove save hook
    (funcall hook-setup 'kill-emacs-hook 'org-recent-headings--save-list)
    ;; Load/save list
    (if org-recent-headings-mode
        (org-recent-headings--load-list)
      (org-recent-headings--save-list))
    ;; Display message
    (if org-recent-headings-mode
        (message "org-recent-headings-mode enabled.")
      (message "org-recent-headings-mode disabled."))))

;;;; Plain completing-read

(cl-defun org-recent-headings (&optional &key (completing-read-fn #'completing-read))
  "Choose from recent Org headings."
  (interactive)
  (org-recent-headings--prepare-list)
  (let* ((heading-display-strings (--map (plist-get (cdr it) :display) org-recent-headings-list))
         (selected-heading (completing-read "Heading: " heading-display-strings))
         ;; FIXME: If there are two headings with the same name, this
         ;; will only pick the first one.  I guess it won't happen if
         ;; full-paths are used, which most likely will be, but maybe
         ;; it should still be fixed.
         (real (car (cl-rassoc selected-heading org-recent-headings-list
                               :test #'string=
                               :key (lambda (it)
                                      (plist-get it :display))))))
    (funcall org-recent-headings-show-entry-function real)))

;;;; Helm

(with-eval-after-load 'helm

  (defvar org-recent-headings-helm-map
    (let ((map (copy-keymap helm-map)))
      (define-key map (kbd "<C-return>") 'org-recent-headings--show-entry-indirect-helm-action)
      map)
    "Keymap for `helm-source-org-recent-headings'.")

  ;; This declaration is absolutely necessary for some reason.  Even
  ;; if `helm' is loaded before this package is loaded, an "invalid
  ;; function" error will be raised when this package is loaded,
  ;; unless this declaration is here.  Even if I manually "(require
  ;; 'helm)" and then load this package after the error (and Helm is
  ;; already loaded, and I've verified that `helm-build-sync-source'
  ;; is defined), once Emacs has tried to load this package thinking
  ;; that the function is invalid, it won't stop thinking it's
  ;; invalid.  It also seems to be related to `defvar' not doing
  ;; anything when run a second time (unless called with
  ;; `eval-defun').  But at the same time, the error didn't always
  ;; happen in my config, or with different combinations of
  ;; `with-eval-after-load', "(when (fboundp 'helm) ...)", and loading
  ;; packages in a different order.  I don't know exactly why it's
  ;; happening, but at the moment, this declaration seems to fix it.
  ;; Let us hope it really does.  I hope no one else is suffering from
  ;; this, because if so, I have inflicted mighty annoyances upon
  ;; them, and I wouldn't blame them if they never used this package
  ;; again.
  (declare-function helm-build-sync-source "helm")

  (defvar helm-source-org-recent-headings
    (helm-build-sync-source " Recent Org headings"
      :candidates (lambda ()
                    (org-recent-headings--prepare-list)
                    org-recent-headings-list)
      :candidate-number-limit 'org-recent-headings-candidate-number-limit
      :candidate-transformer 'org-recent-headings--truncate-candidates
      :keymap org-recent-headings-helm-map
      :action (helm-make-actions
               "Show entry (default function)" 'org-recent-headings--show-entry-default
               "Show entry in real buffer" 'org-recent-headings--show-entry-direct
               "Show entry in indirect buffer" 'org-recent-headings--show-entry-indirect
               "Remove entry" 'org-recent-headings--remove-entries
               "Bookmark heading" 'org-recent-headings--bookmark-entry))
    "Helm source for `org-recent-headings'.")

  (defun org-recent-headings--show-entry-indirect-helm-action ()
    "Action to call `org-recent-headings--show-entry-indirect' from Helm session keymap."
    (interactive)
    (with-helm-alive-p
      (helm-exit-and-execute-action 'org-recent-headings--show-entry-indirect)))

  (defun org-recent-headings-helm ()
    "Choose from recent Org headings with Helm."
    (interactive)
    (helm :sources helm-source-org-recent-headings))

  (defun org-recent-headings--truncate-candidates (candidates)
    "Return CANDIDATES with their DISPLAY string truncated to frame width."
    (cl-loop with width = (- (frame-width) org-recent-headings-truncate-paths-by)
             for (real . attrs) in candidates
             for display = (plist-get attrs :display)
             ;; FIXME: Why using setf here instead of just collecting the result of s-truncate?
             collect (cons (setf display (s-truncate width display))
                           real)))

  (defun org-recent-headings--bookmark-entry (real)
    "Bookmark heading specified by REAL."
    (-let (((&plist :file file :regexp regexp) real))
      (with-current-buffer (or (org-find-base-buffer-visiting file)
                               (find-file-noselect file)
                               (error "File not found: %s" file))
        (org-with-wide-buffer
         (goto-char (point-min))
         (re-search-forward regexp)
         (bookmark-set)))))

  (defun org-recent-headings--remove-entries (&optional entries)
    "Remove ENTRIES from recent headings list.
ENTRIES should be a REAL cons, or a list of REAL conses."
    ;; FIXME: Test this since list format changed.
    (let ((entries (or (helm-marked-candidates)
                       entries)))
      (setq org-recent-headings-list
            (seq-difference org-recent-headings-list
                            entries
                            (lambda (a b)
                              ;; `entries' is only a list of keys, so we have to get
                              ;; just the key of each entry in
                              ;; `org-recent-headings-list' to compare them
                              (let ((a (if (consp (car a))
                                           (car a)
                                         a))
                                    (b (if (consp (car b))
                                           (car b)
                                         b)))
                                (org-recent-headings--compare-keys a b))))))))

;;;; Ivy

(with-eval-after-load 'ivy

  ;; TODO: Might need to declare `ivy-completing-read' also, but I
  ;; haven't hit the error yet.

  (defun org-recent-headings-ivy ()
    "Choose from recent Org headings with Ivy."
    (interactive)
    (org-recent-headings :completing-read-fn #'ivy-completing-read)))

(provide 'org-recent-headings)

;;; org-recent-headings.el ends here
