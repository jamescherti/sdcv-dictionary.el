;;; quick-sdcv.el --- Interface for the sdcv command (StartDict cli dictionary) -*- lexical-binding: t -*-

;; Copyright (C) 2024 James Cherti | https://www.jamescherti.com/contact/
;; Copyright (C) 2009 Andy Stewart

;; Filename: quick-sdcv.el
;; Description: Interface for sdcv (StartDict console version).
;; Package-Requires: ((emacs "25.1"))
;; Maintainer: James Cherti
;; Original Author: Andy Stewart
;; Created: 2009-02-05 22:04:02
;; Version: 3.6
;; URL: https://github.com/jamescherti/quick-sdcv.el
;; Keywords: docs, startdict, sdcv

;;; License
;;
;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program; see the file COPYING.  If not, write to
;; the Free Software Foundation, Inc., 51 Franklin Street, Fifth
;; Floor, Boston, MA 02110-1301, USA.

;;; Commentary:
;;
;; The `quick-sdcv` package serves as an Emacs interface for the `sdcv`
;; command-line interface, which is the console version of the StarDict
;; dictionary application.
;;
;; This integration allows users to access and utilize dictionary
;; functionalities directly within the Emacs environment, leveraging the
;; capabilities of `sdcv` to look up words and translations from various
;; dictionary files formatted for StarDict.
;;
;; Below are the commands you can use:
;; - `quick-sdcv-search-at-point': Searches the word around the cursor and
;;   displays the result in a buffer.
;; - `quick-sdcv-search-input': Searches the input word and displays the result
;;   in a buffer.
;;

;;; Require

(require 'json)
(require 'cl-lib)
(require 'outline)
(require 'subword)

;;; Code:

;;; Customize

(defgroup quick-sdcv nil
  "Interface for sdcv (StartDict console version)."
  :group 'edit)

(defcustom quick-sdcv-unique-buffers nil
  "If non-nil, create a unique buffer for each word lookup.
For instance, if the user searches for the word computer:
- When non-nil, the buffer name will be *sdcv:computer*
- When nil, the buffer name will be *sdcv*
This can be customized with: `quick-sdcv-buffer-name-prefix',
`quick-sdcv-buffer-name-separator', and `quick-sdcv-buffer-name-suffix'"
  :type 'boolean
  :group 'quick-sdcv)

(defcustom quick-sdcv-buffer-name-prefix "*sdcv"
  "The prefix of the sdcv buffer name."
  :type 'string
  :group 'quick-sdcv)

(defcustom quick-sdcv-buffer-name-separator ":"
  "The separator of the sdcv buffer name."
  :type 'string
  :group 'quick-sdcv)

(defcustom quick-sdcv-buffer-name-suffix "*"
  "The suffix of the sdcv buffer name."
  :type 'string
  :group 'quick-sdcv)

(defcustom quick-sdcv-program "sdcv"
  "Path to sdcv."
  :type 'file
  :group 'quick-sdcv)

(defcustom quick-sdcv-dictionary-complete-list nil
  "A list of dictionaries used for translation in quick-sdcv."
  :type '(repeat string)
  :group 'quick-sdcv)

(defcustom quick-sdcv-dictionary-data-dir nil
  "The sdcv data directory where dictionaries are."
  :type '(choice (const :tag "Default" nil) directory)
  :group 'quick-sdcv)

(defcustom quick-sdcv-only-data-dir nil
  "Use only the dictionaries in `quick-sdcv-dictionary-data-dir'.
It prevents sdcv from searching in user and system directories."
  :type 'boolean
  :group 'quick-sdcv)

(defcustom quick-sdcv-exact-search nil
  "Do not fuzzy-search for similar words, only return exact matches."
  :type 'boolean
  :group 'quick-sdcv)

(defcustom quick-sdcv-dictionary-prefix-symbol "►"
  "Symbol character used in sdcv dictionaries that replaces ('-->') visually."
  :group 'quick-sdcv
  :type '(choice (string :tag "Bullet character" :size 1)
                 (const :tag "No bullet" nil)))

(defcustom quick-sdcv-verbose nil
  "If non-nil, `my-quick-sdcv' will show verbose messages."
  :type 'boolean
  :group 'my-quick-sdcv)

;;; Variables

(defvar quick-sdcv-current-translate-object nil
  "The search object.")

(defvar quick-sdcv-fail-notify-string nil
  "Search with additional dictionaries if no definition is available.")

(defvar quick-sdcv--symbols-keywords
  `(("^-->.*\n-->"
     (0 (let* ((heading-start (match-beginning 0))
               (heading-end (+ heading-start 3))
               (symbol-enabled
                (and quick-sdcv-dictionary-prefix-symbol
                     (> (length quick-sdcv-dictionary-prefix-symbol) 0)))
               (symbol (if symbol-enabled
                           (substring quick-sdcv-dictionary-prefix-symbol 0 1)
                         nil)))
          (when (and symbol (not (string= symbol "")))
            (compose-region (- heading-end 3) (- heading-end 1) symbol)
            (compose-region heading-end (- heading-end 1) " ")
            (put-text-property (- heading-end 3) heading-end
                               'face 'font-lock-type-face))
          nil)))))

(defvar quick-sdcv-mode-font-lock-keywords
  '(;; Dictionary name
    ("^-->\\(.*\\)\n-" . (1 font-lock-type-face))
    ;; Search word
    ("^-->\\(.*\\)[ \t\n]*" . (1 font-lock-function-name-face))
    ;; Serial number
    ("\\(^[0-9] \\|[0-9]+:\\|[0-9]+\\.\\)" . (1 font-lock-constant-face))
    ;; Type name
    ("^<<\\([^>]*\\)>>$" . (1 font-lock-comment-face))
    ;; Phonetic symbol
    ("^/\\([^>]*\\)/$" . (1 font-lock-string-face))
    ("^\\[\\([^]]*\\)\\]$" . (1 font-lock-string-face)))
  "Expressions to highlight in `quick-sdcv-mode'.")

;; Optionally, you might want to define the mode itself here.
(defvar quick-sdcv-mode-map
  (let ((map (make-sparse-keymap)))
    map))

(define-derived-mode quick-sdcv-mode nil "sdcv"
  "Major mode to look up word through sdcv.
\\{quick-sdcv-mode-map}"
  (setq font-lock-defaults '(quick-sdcv-mode-font-lock-keywords t))
  (setq buffer-read-only t)
  (set (make-local-variable 'outline-regexp) "^-->.*\n-->")
  (set (make-local-variable 'outline-level) #'(lambda()
                                                1))
  (outline-minor-mode)
  (quick-sdcv--toggle-symbol-fontification t))

;;; Interactive Functions

;;;###autoload
(defun quick-sdcv-search-at-point ()
  "Retrieve the word under the cursor and display its definition in a buffer."
  (interactive)
  (quick-sdcv--search-detail (quick-sdcv--get-region-or-word)))

;;;###autoload
(defun quick-sdcv-search-input (&optional word)
  "Translate the specified input WORD and display the results in another buffer.
If WORD is not provided, the function prompts the user to enter a word."
  (interactive)
  (quick-sdcv--search-detail (or word (quick-sdcv--prompt-input))))

;;;###autoload

(defun quick-sdcv-check ()
  "Check for missing StarDict dictionaries."
  (let* ((dicts (quick-sdcv--get-list-dicts))
         (missing-complete-dicts (quick-sdcv--get-missing-dicts
                                  quick-sdcv-dictionary-complete-list
                                  dicts)))
    (if (not missing-complete-dicts)
        (message (concat "The dictionary's settings look correct, sdcv "
                         "should work as expected."))
      (dolist (dict missing-complete-dicts)
        (message (concat "quick-sdcv-dictionary-complete-list: dictionary "
                         "'%s' does not exist, remove it or download the "
                         "corresponding dictionary file to %s")
                 dict quick-sdcv-dictionary-data-dir)))))

;;; Utilitiy Functions

(defun quick-sdcv--get-buffer-name (&optional word force-include-word)
  "Return the buffer name for WORD.
If FORCE-INCLUDE-WORD is non-nil, always include WORD in the buffer name."
  (concat quick-sdcv-buffer-name-prefix
          (when (and (or force-include-word
                         quick-sdcv-unique-buffers)
                     word)
            (concat quick-sdcv-buffer-name-separator
                    word))
          quick-sdcv-buffer-name-suffix))

(defun quick-sdcv--toggle-symbol-fontification (enabled)
  "Toggle fontification of bullets in the quick-sdcv buffer.
When ENABLED is non-nil, adds font-lock keywords to replace '-->' with a symbol.
When ENABLED is nil: Deconstructs any symbol regions marked by '-->'."
  (if enabled
      (when (and quick-sdcv-dictionary-prefix-symbol
                 (> (length quick-sdcv-dictionary-prefix-symbol) 0))
        (font-lock-add-keywords nil quick-sdcv--symbols-keywords))
    (save-excursion
      (goto-char (point-min))
      (font-lock-remove-keywords nil quick-sdcv--symbols-keywords)
      (while (re-search-forward "^-->.*\n-->" nil t)
        (decompose-region (match-beginning 0) (match-end 0)))))

  ;; Fontify the buffer
  (when font-lock-mode
    (save-restriction
      (widen)
      (when (fboundp 'font-lock-flush)
        (font-lock-flush))
      (when (fboundp 'font-lock-ensure)
        (font-lock-ensure)))
    (with-no-warnings
      (font-lock-fontify-buffer))))

(defun quick-sdcv--call-process (&rest arguments)
  "Call `quick-sdcv-program' with ARGUMENTS. Result is parsed as json."
  (unless (executable-find quick-sdcv-program)
    (error (concat "The program '%s' is not found. Please ensure it is "
                   "installed and the path is correctly set "
                   "in `quick-sdcv-program`.")
           quick-sdcv-program))
  (with-temp-buffer
    (save-excursion
      (let ((exit-code (apply #'call-process quick-sdcv-program nil t nil
                              (append (list "--non-interactive"
                                            "--json-output"
                                            "--utf8-output")
                                      (when quick-sdcv-exact-search
                                        (list "--exact-search"))
                                      (when quick-sdcv-only-data-dir
                                        (list "--only-data-dir"))
                                      (when quick-sdcv-dictionary-data-dir
                                        (list "--data-dir"
                                              quick-sdcv-dictionary-data-dir))
                                      arguments))))
        (if (not (zerop exit-code))
            (error "Failed to call %s: exit code %d" quick-sdcv-program
                   exit-code))))
    (ignore-errors (json-read))))

(defun quick-sdcv--get-list-dicts ()
  "List dictionaries present in sdcv."
  (mapcar (lambda (dict) (cdr (assq 'name dict)))
          (quick-sdcv--call-process "--list-dicts")))

(defun quick-sdcv--get-missing-dicts (list &optional dicts)
  "List missing LIST dictionaries in DICTS.
If DICTS is nil, it utilizes `quick-sdcv--get-list-dicts'."
  (let ((dicts (or dicts (quick-sdcv--get-list-dicts))))
    (cl-set-difference list dicts :test #'string=)))

(defun quick-sdcv--search-detail (&optional word)
  "Search WORD in `quick-sdcv-dictionary-complete-list'.
The result will be displayed in a buffer."
  (when word
    (let* ((buffer-name (quick-sdcv--get-buffer-name word))
           (buffer (get-buffer buffer-name))
           (refresh (or (not buffer)
                        ;; When the words share the same buffer, always refresh
                        (not quick-sdcv-unique-buffers))))
      (unless buffer
        (setq buffer (quick-sdcv--get-buffer word)))

      (when buffer
        (with-current-buffer buffer
          (when refresh
            (when quick-sdcv-verbose
              (message "[SDCV] Searching..."))
            (setq buffer-read-only nil)
            (erase-buffer)
            (set-buffer-file-coding-system 'utf-8)  ;; Force UTF-8
            (setq quick-sdcv-current-translate-object word)
            (insert (quick-sdcv--search-with-dictionary
                     word
                     quick-sdcv-dictionary-complete-list))

            (setq buffer-read-only t)
            (goto-char (point-min))

            (when quick-sdcv-verbose
              (message "[SDCV] Finished searching `%s'."
                       quick-sdcv-current-translate-object)))
          (pop-to-buffer buffer))))))

(defun quick-sdcv--search-with-dictionary (word dictionary-list)
  "Search some WORD with DICTIONARY-LIST.
Argument DICTIONARY-LIST the word that needs to be transformed."
  (let* ((word (or word (quick-sdcv--get-region-or-word)))
         (translate-result (quick-sdcv--translate-result word dictionary-list)))
    (when (and (string= quick-sdcv-fail-notify-string translate-result)
               (setq word (thing-at-point 'word t)))
      (setq translate-result (quick-sdcv--translate-result word dictionary-list)))
    translate-result))

(defun quick-sdcv--translate-result (word dictionary-list)
  "Search for WORD in DICTIONARY-LIST. Return filtered string of results."
  (let* ((arguments (cons word (mapcan (lambda (d) (list "-u" d)) dictionary-list)))
         (result (mapconcat
                  (lambda (result)
                    (let-alist result
                      (format "-->%s\n-->%s\n%s\n\n" .dict .word .definition)))
                  (apply #'quick-sdcv--call-process arguments)
                  "")))
    (if (string-empty-p result)
        quick-sdcv-fail-notify-string
      result)))

(defun quick-sdcv--get-buffer (&optional word)
  "Get the sdcv buffer of WORD. Create one if there's none."
  (let* ((buffer-name (quick-sdcv--get-buffer-name word))
         (buffer (get-buffer buffer-name)))
    (unless buffer
      (setq buffer (get-buffer-create buffer-name)))
    (when buffer
      (with-current-buffer buffer
        (unless (eq major-mode 'quick-sdcv-mode)
          (quick-sdcv-mode)))
      buffer)))

(defun quick-sdcv--prompt-input ()
  "Prompt input for translation."
  (let* ((word (quick-sdcv--get-region-or-word))
         (default (if word (format " (default: %s)" word) "")))
    (read-string (format "Word%s: " default) nil nil word)))

(defun quick-sdcv--get-region-or-word ()
  "Return the region or the word under the cursor."
  (if (use-region-p)
      (buffer-substring-no-properties (region-beginning) (region-end))
    (thing-at-point 'word t)))

(provide 'quick-sdcv)

;;; quick-sdcv.el ends here
