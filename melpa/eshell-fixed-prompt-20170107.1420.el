;;; eshell-fixed-prompt.el --- Minor mode to restrict eshell to a single fixed prompt -*- lexical-binding: t -*-

;; Copyright © 2017 Tijs Mallaerts
;;
;; Author: Tijs Mallaerts <tijs.mallaerts@gmail.com>

;; Package-Requires: ((emacs "25") (s "1.11.0"))
;; Package-Version: 20170107.1420

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Restrict eshell to a single fixed prompt

;;; Code:

(require 's)

(defun eshell-fixed-prompt-send-input ()
  "Send input and keep fixed prompt."
  (interactive)
  (let ((prompt-before (funcall eshell-prompt-function))
        (cmd (buffer-substring (eshell-fixed-prompt-input-start-position)
                               (line-end-position))))
    (unless (s-blank? cmd)
      (eshell/clear-scrollback)
      (eshell-send-input)
      (insert cmd)
      (eshell-send-input)
      (let ((prompt-after (funcall eshell-prompt-function)))
        (unless (string= prompt-before prompt-after)
          (eshell/clear-scrollback)
          (eshell-send-input))))))

(defun eshell-fixed-prompt-input-start-position ()
  "Return the start position of the fixed prompt."
  (save-excursion
    (eshell-bol)
    (point)))

(defun eshell-fixed-prompt-delete-input ()
  "Delete the input at the fixed prompt."
  (delete-region
   (eshell-fixed-prompt-input-start-position)
   (line-end-position)))

(defun eshell-fixed-prompt-remove-next-prompt ()
  "Remove the next eshell prompt."
  (let ((first-prompt-line (save-excursion
                             (eshell-goto-input-start)
                             (line-number-at-pos)))
        (last-line (save-excursion
                     (goto-char (point-max))
                     (line-number-at-pos)))
        (inhibit-read-only t))
    (when (and (/= first-prompt-line last-line)
               (save-excursion
                 (forward-line last-line)
                 (s-contains? (funcall eshell-prompt-function)
                              (buffer-substring-no-properties
                               (line-beginning-position)
                               (line-end-position)))))
      (save-excursion
        (forward-line last-line)
        (delete-region (line-beginning-position)
                       (line-end-position))))))

(defun eshell-fixed-prompt-goto-input-start ()
  "Move to start of input and remove other prompts."
  (let ((curr-line (buffer-substring-no-properties (line-beginning-position)
                                                   (line-end-position))))
    (unless (or (s-contains? "password" curr-line)
                (s-contains? "passphrase" curr-line))
      (eshell-goto-input-start)
      (eshell-fixed-prompt-delete-input)
      (eshell-fixed-prompt-remove-next-prompt))))

(defun eshell-fixed-prompt-select-history-item ()
  "Select eshell history item."
  (interactive)
  (let ((ivy-sort-functions-alist nil))
    (insert (completing-read "History item: " (ring-elements eshell-history-ring)))))

(defvar eshell-fixed-prompt-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map [remap eshell-send-input]
      'eshell-fixed-prompt-send-input)
    (define-key map [remap beginning-of-buffer]
      (lambda ()
        (interactive)
        (eshell-goto-input-start)))
    (define-key map [remap eshell-previous-matching-input-from-input]
      'eshell-fixed-prompt-select-history-item)
    (define-key map [remap eshell-next-matching-input-from-input]
      'eshell-fixed-prompt-select-history-item)
    map))

;;;###autoload
(define-minor-mode eshell-fixed-prompt-mode
  "Minor mode to restrict eshell to a single fixed prompt."
  :lighter " esh-fixed"
  :keymap eshell-fixed-prompt-mode-map

  (if eshell-fixed-prompt-mode
      (progn (add-to-list 'eshell-output-filter-functions
                          'eshell-fixed-prompt-goto-input-start))
    (setq-local eshell-output-filter-functions
                (delete 'eshell-fixed-prompt-goto-input-start
                        eshell-output-filter-functions))))

(provide 'eshell-fixed-prompt)

;;; eshell-fixed-prompt.el ends here
