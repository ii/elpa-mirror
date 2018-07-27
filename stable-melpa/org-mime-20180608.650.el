;;; org-mime.el --- org html export for text/html MIME emails

;; Copyright (C) 2010-2015 Eric Schulte

;; Author: Eric Schulte
;; Maintainer: Chen Bin (redguardtoo)
;; Keywords: mime, mail, email, html
;; Package-Version: 20180608.650
;; Homepage: http://github.com/org-mime/org-mime
;; Version: 0.1.1
;; Package-Requires: ((emacs "24.4") (cl-lib "0.5"))

;; This file is not part of GNU Emacs.

;;; License:

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; WYSIWYG, html mime composition using org-mode
;;
;; For mail composed using the orgstruct-mode minor mode, this
;; provides a function for converting all or part of your mail buffer
;; to embedded html as exported by org-mode.  Call `org-mime-htmlize'
;; in a message buffer to convert either the active region or the
;; entire buffer to html.
;;
;; Similarly the `org-mime-org-buffer-htmlize' function can be called
;; from within an org-mode buffer to convert the buffer to html, and
;; package the results into an email handling with appropriate MIME
;; encoding.
;;
;; `org-mime-org-subtree-htmlize' is similar to `org-mime-org-buffer-htmlize'
;; but works on a subtree. It can also read the following subtree properties:
;; MAIL_SUBJECT, MAIL_TO, MAIL_CC, and MAIL_BCC. Note the behavior of this is
;; controlled by `org-mime-up-subtree-heading'. The default is to go up to the
;; heading containing the current subtree.

;; Here is the sample of a subtree:
;;
;; * mail one
;;   :PROPERTIES:
;;   :MAIL_SUBJECT: mail title
;;   :MAIL_TO: person1@gmail.com
;;   :MAIL_CC: person2@gmail.com
;;   :MAIL_BCC: person3@gmail.com
;;   :END:
;;
;; To avoid exporting the table of contents, you can setup
;; `org-mime-export-options':
;;   (setq org-mime-export-options '(:section-numbers nil
;;                                   :with-author nil
;;                                   :with-toc nil))
;;
;; Or just setup your export options in the org buffer/subtree. These are
;; overridden by `org-mime-export-options' when it is non-nil.
;;
;;
;; Quick start:
;; Write a message in message-mode, make sure the mail body follows
;; org format. Before sending mail, run `M-x org-mime-htmlize' to convert the
;; body to html, then send the mail as usual.
;;
;; Setup (OPTIONAL):
;; You might want to bind this to a key with something like the
;; following message-mode binding
;;
;;   (add-hook 'message-mode-hook
;;             (lambda ()
;;               (local-set-key (kbd "C-c M-o") 'org-mime-htmlize)))
;;
;; and the following org-mode binding
;;
;;   (add-hook 'org-mode-hook
;;             (lambda ()
;;               (local-set-key (kbd "C-c M-o") 'org-mime-org-buffer-htmlize)))
;;
;; Extra Tips:
;; 1. In order to embed images into your mail, use the syntax below,
;; [[/full/path/to/your.jpg]]
;;
;; 2. It's easy to add your own emphasis markup. For example, to render text
;; between "@" in a red color, you can add a function to `org-mime-html-hook':
;;
;;   (add-hook 'org-mime-html-hook
;;             (lambda ()
;;               (while (re-search-forward "@\\([^@]*\\)@" nil t)
;;                 (replace-match "<span style=\"color:red\">\\1</span>"))))
;;
;; 3. Now the quoted mail uses a modern style (like Gmail), so mail replies
;; looks clean and modern. If you prefer the old style, please set
;; `org-mime-beautify-quoted-mail' to nil.

;;; Code:
(require 'cl-lib)
(require 'xml)
(require 'org)
(require 'ox-org)

(defcustom org-mime-beautify-quoted-mail t
  "Beautify quoted mail in more clean HTML, like Gmail."
  :group 'org-mime
  :type 'boolean)

(defcustom org-mime-use-property-inheritance nil
  "Non-nil means al MAIL_ properties apply also for sublevels."
  :group 'org-mime
  :type 'boolean)

(defcustom org-mime-default-header
  "#+OPTIONS: latex:t toc:nil H:3\n"
  "Default header to control html export options.
And ensure first line isn't assumed to be a title line."
  :group 'org-mime
  :type 'string)

(defcustom org-mime-library 'mml
  "Library to use for marking up MIME elements."
  :group 'org-mime
  :type '(choice 'mml 'semi 'vm))

(defcustom org-mime-preserve-breaks t
  "Temporary value of `org-export-preserve-breaks' during mime encoding."
  :group 'org-mime
  :type 'boolean)

(defcustom org-mime-fixedwith-wrap
  "<pre style=\"font-family: courier, monospace;\">\n%s</pre>\n"
  "Format string used to wrap a fixedwidth HTML email."
  :group 'org-mime
  :type 'string)

(defcustom org-mime-find-html-start 'identity
  "Call back to search the new HTML start for htmlize in message buffer."
  :group 'org-mime
  :type 'sexp)

(defcustom org-mime-org-html-with-latex-default 'dvipng
  "Default value of `org-html-with-latex'."
  :group 'org-mime
  :type 'sexp)

(defvar org-mime-export-options nil
  "Default export options which may overrides org buffer/subtree options.
You avoid exporting section-number/author/toc with the setup below,
`(setq org-mime-export-options '(:section-numbers nil :with-author nil :with-toc nil))'")

(defvar org-mime-html-hook nil
  "Hook to run over the html buffer before attachment to email.
This could be used for example to post-process html elements.")

(defvar org-mime-pre-html-hook nil
  "Hook to run before html export.
Functions should take no arguments and will be run in a
buffer holdin the text to be exported.")

(defvar org-mime-send-buffer-hook nil
  "Hook to run in the Org-mode file before export.")

(defvar org-mime-debug nil
  "Enable debug logger.")

(defvar org-mime-up-subtree-heading 'org-up-heading-safe
  "Function to call before exporting a subtree.
You could use either `org-up-heading-safe' or `org-back-to-heading'.")


(defun org-mime-get-export-options (subtreep)
  "SUBTREEP is t if current node is subtree."
  (cond
   (subtreep
    (or org-mime-export-options
        (if (fboundp 'org-export--get-subtree-options)
            (org-export--get-subtree-options))))
   (t
    (or org-mime-export-options
        (if (fboundp 'org-export--get-inbuffer-options)
            (org-export--get-inbuffer-options))))))

(defun org-mime-get-exported-content (fmt subtreep)
  "Similar to `org-html-export-as-html' and `org-org-export-as-org'.
FMT is either 'org or 'html.
SUBTREEP is t if current node is subtree."
  (let* ((buf (org-export-to-buffer fmt "*Org Mime Export*"
                nil subtreep nil (org-mime-get-export-options subtreep)))
         (body (prog1
                   (with-current-buffer buf
                     (format "#+BEGIN_EXPORT %s\n%s\n#+END_EXPORT"
                             (symbol-name fmt)
                             (buffer-string)))
                 (kill-buffer buf))))
    body))

(defun org-mime--export-string (s fmt &optional opts)
  "Export string S using FMT as the backend.
OPTS is export options."
  ;; Emacs 25+ prefer exporting drawer by default
  ;; obviously not acceptable in exporting to mail body
  (let* ((org-export-with-drawers nil))
    (when org-mime-debug (message "org-mime--export-string called => %s" opts))
    ;; we won't export title from org file anyway
    (if opts (setq opts (plist-put opts 'title nil)))
    ;; emacs24.4+
    (org-export-string-as s fmt t (or org-mime-export-options opts))))

;; example hook, for setting a dark background in
;; <pre style="background-color: #EEE;"> elements
(defun org-mime-change-element-style (element style)
  "Set <ELEMENT> elements in exported html with new default html STYLE."
  (while (re-search-forward (format "<%s" element) nil t)
    (replace-match (format "<%s style=\"%s\"" element style))))

(defun org-mime-change-class-style (class style)
  "CLASS is used for new default html STYLE in exported html."
  (while (re-search-forward (format "class=\"%s\"" class) nil t)
    (replace-match (format "class=\"%s\" style=\"%s\"" class style))))

;; ;; example addition to `org-mime-html-hook' adding a dark background
;; ;; color to <pre> elements
;; (add-hook 'org-mime-html-hook
;;           (lambda ()
;;             (org-mime-change-element-style
;;              "pre" (format "color: %s; background-color: %s;"
;;                            "#E6E1DC" "#232323"))
;;             (org-mime-change-class-style
;;              "verse" "border-left: 2px solid gray; padding-left: 4px;")))

(defun org-mime-file (ext path id)
  "Markup a file with EXT, PATH and ID for attachment."
  (when org-mime-debug (message "org-mime-file called => %s %s %s" ext path id))
  (cl-case org-mime-library
    (mml (format "<#part type=\"%s\" filename=\"%s\" disposition=inline id=\"<%s>\">\n<#/part>\n"
                 ext path id))
    (semi (concat
           (format "--[[%s\nContent-Disposition: inline;\nContent-ID: <%s>][base64]]\n"
                   ext id)
           (base64-encode-string
            (with-temp-buffer
              (set-buffer-multibyte nil)
              (insert-file-contents-literally path)
              (buffer-string)))))
    (vm "?")))

(defun org-mime-encode-quoted-mail-body ()
  "Please note quoted mail body could be with reply."
  (let* ((b (save-excursion
              (goto-char (point-min))
              (search-forward-regexp "^[^ ]*&gt; ")
              (search-backward-regexp "<p>")
              (line-beginning-position)))
         (e (save-excursion
              (goto-char (point-max))
              (search-backward-regexp "^[^ ]*&gt; ")
              (search-forward-regexp "</p>")
              (line-end-position)))
         (str (format "<div>%s</div>" (buffer-substring-no-properties b e)))
         (paragraphs (xml-node-children (car (with-temp-buffer
                                               (insert str)
                                               (xml--parse-buffer nil nil)))))
         (is-quoted t)
         lines
         (rlt "<blockquote class=\"gmail_quote\" style=\"margin:0 0 0 .8ex;border-left:1px #ccc solid;padding-left:1ex\">\n<p>\n"))
    (dolist (p paragraphs)
      (when (and p (> (length p) 2))
        (dolist (s p)
          (when (and s
                     (not (eq s 'p))
                     (not (consp s))
                     (not (string= s "\n")))
            ;; trim string
            (setq s (replace-regexp-in-string "\\`[ \t\n]*" "" (replace-regexp-in-string "[ \t\n]*\\'" "" s)))
            (setq lines (split-string s "\n"))
            (dolist (l lines)
              (cond
               ((string-match "^ *[^ ]*> ?\\(.*\\)" l)
                (when (not is-quoted)
                  (setq rlt (concat rlt "</p>\n<blockquote class=\"gmail_quote\" style=\"margin:0 0 0 .8ex;border-left:1px #ccc solid;padding-left:1ex\">\n<p>\n"))
                  (setq is-quoted t))
                (setq rlt (concat rlt (match-string 1 l) "<br />\n")))
               ((string= l "")
                (set rlt (concat rlt "<br />")))
               (t
                (when is-quoted
                  (setq rlt (concat rlt "</p>\n</blockquote>\n<p>\n"))
                  (setq is-quoted nil))
                (setq rlt (concat rlt l "\n")))))))))
    (setq rlt (concat rlt (if is-quoted "</p>\n</blockquote>\n" "</p>\n")))
    (list b e rlt )))

(defun org-mime-cleanup-quoted (html)
  "Clean up quoted mail in modern UI style.
HTML is the body of the message."
  (cond
   (org-mime-beautify-quoted-mail
    (let* (info)
      (with-temp-buffer
        ;; clean title of quoted
        (insert (replace-regexp-in-string
                 "<p>[\n\r]*&gt;&gt;&gt;&gt;&gt; .* == \\([^\r\n]*\\)[\r\n]*</p>"
                 "<div class=\"gmail_quote\">\\1</div>"
                 html))
        (unwind-protect
            (let (retval)
              (condition-case ex
                  (setq info (org-mime-encode-quoted-mail-body))
                (setq retval info)
                ('error (setq info nil)))
              retval))
        (cond
         (info
          (delete-region (nth 0 info) (nth 1 info))
          (goto-char (nth 0 info))
          (insert (nth 2 info))
          (buffer-substring-no-properties (point-min) (point-max)))
         (t
          html)))))
   (t
    html)))

(defun org-mime-multipart (plain html &optional images)
  "Markup a multipart/alternative PLAIN with PLAIN and HTML alternatives.
If html portion of message includes IMAGES they are wrapped in multipart/related part."
  (cl-case org-mime-library
    (mml (concat "<#multipart type=alternative><#part type=text/plain>"
                 plain
                 (when images "<#multipart type=related>")
                 "<#part type=text/html>"
                 (org-mime-cleanup-quoted html)
                 images
                 (when images "<#/multipart>\n")
                 "<#/multipart>\n"))
    (semi (concat
           "--" "<<alternative>>-{\n"
           "--" "[[text/plain]]\n" plain
           (when images (concat "--" "<<alternative>>-{\n"))
           "--" "[[text/html]]\n"  html
           images
           (when images (concat "--" "}-<<alternative>>\n"))
           "--" "}-<<alternative>>\n"))
    (vm "?")))

(defun org-mime-url-to-path (url current-file)
  "If URL is file path, convert to valid path.
Or else use CURRENT-FILE to calculate path."
  (let* ((dir (file-name-directory current-file))
         (path (expand-file-name url dir)))
    (cond
     ((string-match-p "^file:///" url)
      (replace-regexp-in-string "^file://" "" url))
     ((file-exists-p path)
      path)
     (t
      (expand-file-name url default-directory)))))

(defun org-mime-replace-images (str current-file)
  "Replace images in STR with cid links.
CURRENT-FILE is used to calculate full path of images."
  (when org-mime-debug (message "org-mime-replace-images called => %s" current-file))
  (let* (html-images)
    (cons
     (replace-regexp-in-string ;; replace images in html
      "src=\"\\([^\"]+\\)\""
      (lambda (text)
        (format
         "src=\"cid:%s\""
         (let* ((url (and (string-match "src=\"\\([^\"]+\\)\"" text)
                          (match-string 1 text)))
                (path (org-mime-url-to-path url current-file))
                (ext (file-name-extension path))
                (id (replace-regexp-in-string "[\/\\\\]" "_" path)))

           ;; Catch non-existent files here. Otherwise users get an error on sending.
           (unless (file-exists-p path)
             (user-error "path: %s does not exist" path))

           ;; Do it
           (add-to-list 'html-images
                        (org-mime-file (concat "image/" ext) path id))
           id)))
      str)
     html-images)))

(defun org-mime-extract-non-image-files ()
  "Extract non-image links in current buffer."
  (cond
   ((>= (org-mime-org-major-version) 9)
    (org-element-map (org-element-parse-buffer) 'link
      (lambda (link)
        (when (and (string= (org-element-property :type link) "file")
                   (not (string-match
                         (cdr (assoc "file" org-html-inline-image-rules))
                         (org-element-property :path link))))
          (org-element-property :path link)))))
   (t
    (message "Warning: org-element-map is not available. File links will not be attached.")
    nil)))

(defun org-mime-insert-html-content (body file s opts)
  (let* ((files (org-mime-extract-non-image-files))
         ;; dvipng for inline latex because MathJax doesn't work in mail
         ;; Also @see https://github.com/org-mime/org-mime/issues/16
         ;; (setq org-html-with-latex nil) sometimes useful
         (org-html-with-latex org-mime-org-html-with-latex-default)
         ;; we don't want to convert org file links to html
         (org-html-link-org-files-as-html nil)
         (org-link-file-path-type 'absolute)
         ;; makes the replies with ">"s look nicer
         (org-export-preserve-breaks org-mime-preserve-breaks)
         (plain (org-mime--export-string body 'org))
         ;; org 9
         (org-html-htmlize-output-type 'inline-css)
         ;; org 8
         (org-export-htmlize-output-type 'inline-css)
         (html-and-images (org-mime-replace-images (org-mime--export-string s 'html opts)
                                                   file))
         (images (cdr html-and-images))
         (html (org-mime-apply-html-hook (car html-and-images))))

    ;; If there are files that were attached, we should remove the links,
    ;; and mark them as attachments. The links don't work in the html file.
    (when files
      (mapc (lambda (f)
              (setq html (replace-regexp-in-string
                          (format "<a href=\"%s\">%s</a>"
                                  (regexp-quote f) (regexp-quote f))
                          (format "%s (attached)" (file-name-nondirectory f))
                          html)))
            files))

    (insert (org-mime-multipart plain
                                html
                                (mapconcat 'identity images "\n")))

    ;; Attach any residual files
    (when files
      (mapc (lambda (f)
              (when org-mime-debug (message "attaching: %s" f))
              (mml-attach-file f))
            files))))

;;;###autoload
(defun org-mime-htmlize ()
  "Export a portion of an email to html using `org-mode'.
If called with an active region only export that region, otherwise entire body."
  (interactive)
  (when org-mime-debug (message "org-mime-htmlize called"))
  (let* ((region-p (org-region-active-p))
         (html-start (funcall org-mime-find-html-start
                              (or (and region-p (region-beginning))
                                  (save-excursion
                                    (goto-char (point-min))
                                    (search-forward mail-header-separator)
                                    (+ (point) 1)))))
         (html-end (or (and region-p (region-end))
                       ;; TODO: should catch signature...
                       (point-max)))
         (body (buffer-substring
                html-start html-end))
         (str (concat org-mime-default-header body))
         (file (make-temp-name (expand-file-name
                                "mail" temporary-file-directory)))


         ;; to hold attachments for inline html images
         (opts (if (fboundp 'org-export--get-inbuffer-options)
                   (org-export--get-inbuffer-options))))

    ;; delete current region
    (delete-region html-start html-end)
    (goto-char html-start)
    ;; insert new current
    (org-mime-insert-html-content body file str opts)))

(defun org-mime-apply-html-hook (html)
  "Apply HTML hook."
  (if org-mime-html-hook
      (with-temp-buffer
        (insert html)
        (goto-char (point-min))
        (run-hooks 'org-mime-html-hook)
        (buffer-string))
    html))

(defun org-mime--get-buffer-title ()
  "Get buffer title."
  (let* ((tmp (if (fboundp 'org-export--get-inbuffer-options)
                  (plist-get (org-export--get-inbuffer-options) :title))))
    (when tmp
      (let ((txt (car tmp)))
        (set-text-properties 0 (length txt) nil txt)
        txt))))

(defun org-mime-compose (body file to subject headers subtreep)
  "Create mail BODY in FILE with TO, SUBJECT, HEADERS.
If SUBTREEP is t, curret org node is subtree."
  ;; start composing mail
  (unless (featurep 'message)
    (require 'message))
  (message-mail to subject headers nil)
  (message-goto-body)

  ;; insert text
  (let* ((str (with-temp-buffer
                (insert body)
                (goto-char (point-min))
                (run-hooks 'org-mime-pre-html-hook)
                (buffer-string))))
    (org-mime-insert-html-content body
                                  file
                                  str
                                  (org-mime-get-export-options subtreep))))

(defun org-mime-extract-keywords ()
  "Extract keyword from "
  (cond
   ((>= (org-mime-org-major-version) 9)
    (org-element-map (org-element-parse-buffer) 'keyword
      (lambda (keyword)
        (cons (org-element-property :key keyword)
              (org-element-property :value keyword)))))
   (t
    (message "Warning: org-element-map is not available. File keywords will not work.")
    '())))

(defun org-mime-build-mail-other-headers (cc bcc)
  "Build mail header from CC and BCC."
  (cond
   ((and cc bcc)
    (list (cons "Cc" cc)
          (cons "Bcc" bcc)))
   (cc
    (list (cons "Cc" cc)))
   (bcc
    (list (cons "Bcc" bcc)))
   (t
    nil)))

;;;###autoload
(defun org-mime-org-buffer-htmlize ()
  "Create an email buffer of the current org buffer.
The email buffer will contain both html and in org formats as mime
alternatives.

The following file keywords can be used to control the headers:
#+MAIL_TO: some1@some.place
#+MAIL_SUBJECT: a subject line
#+MAIL_CC: some2@some.place
#+MAIL_BCC: some3@some.place

The cursor ends in the TO field."
  (interactive)
  (run-hooks 'org-mime-send-buffer-hook)
  (let* ((region-p (org-region-active-p))
         (file (buffer-file-name (current-buffer)))
         (keywords (org-mime-extract-keywords))
         (subject (or (cdr (assoc "MAIL_SUBJECT" keywords))
                      (org-mime--get-buffer-title)
                      (if (not file) (buffer-name (buffer-base-buffer))
                        (file-name-sans-extension
                         (file-name-nondirectory file)))))
         (body (org-mime-get-exported-content 'html nil))
         (to (cdr (assoc "MAIL_TO" keywords)))
         (cc (cdr (assoc "MAIL_CC" keywords)))
         (bcc (cdr (assoc "MAIL_BCC" keywords)))
         (other-headers (org-mime-build-mail-other-headers cc bcc)))
    (org-mime-compose body file to subject other-headers nil)
    (message-goto-to)))

(defun org-mime-org-major-version ()
  "Get Org major version."
  (string-to-number (car (split-string (org-release) "\\."))))

;; TODO integrating patch
;;;###autoload
(defun org-mime-org-subtree-htmlize ()
  "Create an email buffer of the current subtree.
The buffer will contain both html and in org formats as mime
alternatives.

The following headline properties can determine the headers.
* subtree heading
   :PROPERTIES:
   :MAIL_SUBJECT: mail title
   :MAIL_TO: person1@gmail.com
   :MAIL_CC: person2@gmail.com
   :MAIL_BCC: person3@gmail.com
   :END:

The cursor is left in the TO field."
  (interactive)
  (save-excursion
    (funcall org-mime-up-subtree-heading)
    (cl-flet ((mp (p) (org-entry-get nil p org-mime-use-property-inheritance)))
      (let* ((file (buffer-file-name (current-buffer)))
             (subject (or (mp "MAIL_SUBJECT") (nth 4 (org-heading-components))))
             (to (mp "MAIL_TO"))
             (cc (mp "MAIL_CC"))
             (bcc (mp "MAIL_BCC"))
             ;; Thanks to Matt Price improving handling of cc & bcc headers
             (other-headers (org-mime-build-mail-other-headers cc bcc))
             (org-export-show-temporary-export-buffer nil)
             (subtree-opts (when (fboundp 'org-export--get-subtree-options)
                             (org-export--get-subtree-options)))
             (org-export-show-temporary-export-buffer nil)
             (org-major-version (org-mime-org-major-version))
             ;; I wrap these bodies in export blocks because in org-mime-compose
             ;; they get exported again. This makes each block conditionally
             ;; exposed depending on the backend.
             (org-body (save-restriction
                        (org-narrow-to-subtree)
                        (org-mime-get-exported-content 'org t)))
             (html-body (save-restriction
                         (org-narrow-to-subtree)
                         (org-mime-get-exported-content 'html t)))
             (body (concat org-body "\n" html-body)))
        (save-restriction
          (org-narrow-to-subtree)
          (org-mime-compose body file to subject other-headers t))
        (message-goto-to)))))

(provide 'org-mime)
;; Local Variables:
;; coding: utf-8
;; tab-width: 2
;; indent-tabs-mode: nil
;; End:
;;; org-mime.el ends here
