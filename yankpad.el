;;; yankpad.el --- Paste snippets from an org-mode file         -*- lexical-binding: t; -*-

;; Copyright (C) 2016--present Erik Sjöstrand
;; MIT License

;; Author: Erik Sjöstrand
;; URL: http://github.com/Kungsgeten/yankpad
;; Version: 2.40
;; Keywords: abbrev convenience
;; Package-Requires: ((emacs "25.1"))

;;; Commentary:

;; A way to insert text snippets from an org-mode file.  The org-mode file in
;; question is defined in `yankpad-file' and is set to "yankpad.org" in your
;; `org-directory' by default.  In this file, each heading specifies a snippet
;; category and each subheading of that category defines a snippet.  This way
;; you can have different yankpads for different occasions.
;;
;; You can open your `yankpad-file' by using `yankpad-edit' (or just open it in
;; any other way).  Another way to add new snippets is by using
;; `yankpad-capture-snippet', which will add a snippet to the current
;; `yankpad-category'.
;;
;; If you have yasnippet installed, yankpad will try to use it when pasting
;; snippets.  This means that you can use the features that yasnippet provides
;; (tab stops, elisp, etc).  You can use yankpad without yasnippet, and then the
;; snippet will simply be inserted as is.
;;
;; You can also add keybindings to snippets, by setting an `org-mode' tag on the
;; snippet.  The last tag will be interpreted as a keybinding, and the snippet
;; can be run by using `yankpad-map' followed by the key.  `yankpad-map' is not
;; bound to any key by default.
;;
;; Another functionality is that snippets can include function calls, instead of
;; text.  In order to do this, the snippet heading should have a tag named
;; "func".  The snippet name could either be the name of the elisp function that
;; should be executed (will be called without arguments), or the content of the
;; snippet could be an `org-mode' src-block, which will then be executed when
;; you use the snippet.
;;
;; If you name a category to a major-mode name, that category will be switched
;; to when you change major-mode.  You can also name categories to the same name
;; as your project.el or projectile projects.  These snippets will be appended to
;; your active snippets if you change category.
;;
;; To insert a snippet from the yankpad, use `yankpad-insert' or
;; `yankpad-expand'.  `yankpad-expand' will look for a keyword at point, and
;; expand a snippet with a name starting with that word, followed by
;; `yankpad-expand-separator' (a colon by default).  If you need to change the
;; category, use `yankpad-set-category'.  If you want to append snippets from
;; another category (basically having several categories active at the same
;; time), use `yankpad-append-category'.  You can also add `yankpad-capf` to
;; `completion-at-point-functions` in order to use company, corfu, or
;; completion-preview to select snippets.
;;
;; A quick way to add short snippets with a keyword is to add a descriptive list
;; to the category in your `yankpad-file'.  The key of each item in the list will be
;; the keyword, and the description will be the snippet.  You can turn off this
;; behaviour by setting `yankpad-descriptive-list-treatment' to nil, or change
;; descriptive lists to use `abbrev-mode' by setting the variable to 'abbrev
;; instead.
;;
;; For further customization, please see the Github page: https://github.com/Kungsgeten/yankpad
;;
;; Here's an example of what yankpad.org could look like:

;;; Yankpad example:

;; * Category 1
;; ** Snippet 1
;;
;;    This is a snippet.
;;
;; ** snip2: Snippet 2
;;
;;    This is another snippet.  This snippet can be expanded by first typing "snip2" and
;;    then executing the `yankpad-expand' command.
;;    \* Org-mode doesn't like lines beginning with *
;;    Typing \* at the beginning of a line will be replaced with *
;;
;;    If yanking a snippet into org-mode, this will respect the
;;    current tree level by default.  Set the variable
;;    `yankpad-respect-current-org-level' to nil in order to change that.
;;
;; * Category 2
;;
;;   Descriptive lists will be treated as snippets.  You can set them to be
;;   treated as `abbrev-mode' abbrevs instead, by setting
;;   `yankpad-descriptive-list-treatment' to abbrev.  If a heading could be considered
;;   to be a snippet, add the `snippetlist' tag to ignore the snippet and scan
;;   it for descriptive lists instead.
;;
;;   - name :: Erik Sjöstrand
;;   - key :: Typing "key" followed by `yankpad-expand' will insert this snippet.
;;
;; ** Snippet 1
;;
;;    This is yet another snippet, in a different category.
;; ** Snippet 2        :s:
;;
;;    This snippet will be bound to "s" when using `yankpad-map'.  Let's say you
;;    bind `yankpad-map' to f7, you can now press "f7 s" to insert this snippet.
;;
;; ** magit-status          :func:
;; ** Run magit-status      :func:m:
;;    #+BEGIN_SRC emacs-lisp
;;    (magit-status)
;;    #+END_SRC
;;
;; * org-mode
;; ** Snippet 1
;;    This category will be switched to automatically when visiting an org-mode buffer.
;;
;; * Category 3
;;   :PROPERTIES:
;;   :INCLUDE:  Category 1|Category 2
;;   :END:
;; ** A snippet among many!
;;    This category will include snippets from Category 1 and Category 2.
;;    This is done by setting the INCLUDE property of the category.
;;
;; * Global category       :global:
;; ** Always available
;;    Snippets in a category with the :global: tag are always available for expansion.
;; * Default                                           :global:
;; ** Fallback for major-mode categories
;;
;; If you open a file, but have no category named after its major-mode, a
;; category named "Default" will be used instead (if you have it defined in your
;;                                                   Yankpad). It is probably a good idea to make this category global. You can
;; change the name of the default category by setting the variable
;; yankpad-default-category.

;;; Code:

(require 'org-element)
(require 'org-capture)
(require 'org-macs)
(require 'thingatpt)
(require 'subr-x)
(require 'seq)
(require 'cl-lib)
(when (version< (org-version) "8.3")
  (require 'ox))

(defgroup yankpad nil
  "Paste snippets from an org-mode file."
  :group 'editing)

(defcustom yankpad-file (expand-file-name "yankpad.org" org-directory)
  "The path to your yankpad."
  :type 'string
  :group 'yankpad)

(defvar yankpad-category nil
  "The current yankpad category.  Change with `yankpad-set-category'.")
(put 'yankpad-category 'safe-local-variable #'string-or-null-p)

(defcustom yankpad-default-category "Default"
  "Used as fallback if no category is found when running `yankpad-local-category-to-major-mode'."
  :type 'string
  :group 'yankpad)

(defcustom yankpad-category-heading-level 1
  "The `org-mode' heading level of categories in the `yankpad-file'."
  :type 'integer
  :group 'yankpad)

(defcustom yankpad-respect-current-org-level t
  "Whether to respect `org-current-level' when using \* in snippets and yanking them into `org-mode' buffers."
  :type 'boolean
  :group 'yankpad)

(defcustom yankpad-auto-category-functions
  '(yankpad-major-mode-category
    yankpad-project-category
    yankpad-projectile-category)
  "List of functions that return an implicit category name.

Each item is a function that returns a category name or
nil. Categories returned from these functions are added as well
as the category explicitly selected by the user and global
categories."
  :type '(repeat function))

(defvar yankpad-switched-category-hook nil
  "Hooks run after changing `yankpad-category'.")

(defvar yankpad-before-snippet-hook nil
  "Hooks run before inserting a snippet.
Each hook function should take the snippet as an argument.
The snippet can be modified by using `setf' or similar.
A snippet is a list with the following elements:
\(name tags src-blocks content properties\)")

(defcustom yankpad-expand-separator ":"
  "String used to separate a keyword, at the start of a snippet name, from the title.  Used for `yankpad-expand'."
  :type 'string
  :group 'yankpad)

(defvar yankpad--active-snippets nil
  "A cached version of the snippets in the current category.")

(defvar yankpad--last-snippet nil
  "The last snippet executed. Used by `yankpad-repeat'.")

(defcustom yankpad-descriptive-list-treatment 'snippet
  "How items inside descriptive lists of `yankpad-category-heading-level' should be treated.

If nil, `yankpad' will ignore them.

If 'snippet, `yankpad' will treat them as snippets, where the key
of the description will be treated as a keyword in `yankpad'.

If 'abbrev, the items will overwrite `local-abbrev-table'."
  :type '(choice
          (const :tag "Snippet" snippet)
          (const :tag "Local abbrev" abbrev)
          (const :tag "Ignore" nil))
  :group 'yankpad)

(defcustom yankpad-global-tag "global"
  "Snippets in a category with this tag are always active."
  :type 'string
  :group 'yankpad)

(defcustom yankpad-use-yasnippet t
  "If non-nil and yasnippet is available, use it when pasting
snippets."
  :type 'boolean
  :group 'yankpad)

(defun yankpad-active-snippets ()
  "Get the snippets in the current category."
  (or yankpad--active-snippets (yankpad-set-active-snippets)))

;;;###autoload
(defun yankpad-set-category ()
  "Change the yankpad category."
  (interactive)
  (let ((categories (yankpad--categories)))
    (cond ((equal (length categories) 0)
           (user-error "Your yankpad file doesn't contain any categories"))
          ((equal (length categories) 1)
           (setq yankpad-category (car categories)))
          (t (setq yankpad-category (completing-read "Category: " categories)))))
  (run-hooks 'yankpad-switched-category-hook))

(defun yankpad-set-local-category (category)
  "Set `yankpad-category' to CATEGORY locally."
  (set (make-local-variable 'yankpad-category) category)
  (set (make-local-variable 'yankpad--active-snippets) nil)
  (run-hooks 'yankpad-switched-category-hook))

(defsubst yankpad-major-mode-category ()
  "Return a category name based on the major mode."
  (symbol-name major-mode))

(defsubst yankpad-projectile-category ()
  "Return a category name based on the projectile project name."
  (when (require 'projectile nil t)
    (projectile-project-name)))

(defsubst yankpad-project-category ()
  "Return a category name based on the project.el project name."
  (when (require 'project nil t)
    (when-let ((proj (project-current)))
      (project-name proj))))

(defun yankpad-set-active-snippets ()
  "Set the `yankpad--active-snippets' to the snippets in the active category.
If no active category, call `yankpad-set-category'.
Also append major mode and/or project categories if `yankpad-category' is local."
  (unless yankpad-category
    (yankpad-set-category))
  (setq yankpad--active-snippets (yankpad--snippets yankpad-category))
  (when (local-variable-p 'yankpad-category)
    (thread-last (mapcar #'funcall yankpad-auto-category-functions)
                 (delq nil)
                 (seq-intersection (yankpad--categories))
                 (mapc #'yankpad-append-category)))
  (mapc #'yankpad-append-category (yankpad--global-categories))
  yankpad--active-snippets)

(defun yankpad-append-category (category)
  "Add snippets from CATEGORY into the list of active snippets.
Prompts for CATEGORY if it isn't provided."
  (interactive (list (completing-read "Category: " (yankpad--categories))))
  (unless (equal category yankpad-category)
    (unless yankpad--active-snippets (yankpad-set-active-snippets))
    (dolist (x (yankpad--snippets category))
      (add-to-list 'yankpad--active-snippets x t))))

(defun yankpad--add-abbrevs-from-category (category)
  "`define-abbrev' in `local-abbrev-table' for each descriptive list item in CATEGORY."
  (dolist (abbrev (yankpad-category-descriptions category))
    (define-abbrev local-abbrev-table (car abbrev) (cdr abbrev))))

(defun yankpad-load-abbrevs ()
  "Load abbrevs related to `yankpad-category'."
  (if-let* ((major-abbrev-table (intern-soft (concat (symbol-name major-mode) "-abbrev-table"))))
      (setq local-abbrev-table (copy-abbrev-table (eval major-abbrev-table)))
    (clear-abbrev-table local-abbrev-table))
  (yankpad--add-abbrevs-from-category yankpad-category)
  (mapc #'yankpad--add-abbrevs-from-category (yankpad--global-categories))
  (when (local-variable-p 'yankpad-category)
    (let ((categories (yankpad--categories)))
      (when-let* ((major-mode-category (car (member (symbol-name major-mode)
                                                    categories))))
        (yankpad--add-abbrevs-from-category major-mode-category))
      (when (require 'projectile nil t)
        (when-let* ((projectile-category (car (member (projectile-project-name)
                                                      categories))))
          (yankpad--add-abbrevs-from-category projectile-category)))
      (when (require 'project nil t)
        (when-let* ((proj (project-current))
                    (project-category (car (member (project-name proj)
                                                   categories))))
          (yankpad--add-abbrevs-from-category project-category))))))

(defun yankpad-reload ()
  "Clear the snippet cache.
The next try to `yankpad-insert` will reload `yankpad-file`.
Useful to run after editing the `yankpad-file`.

If `yankpad-descriptive-list-treatment' is 'abbrev,
`yankpad-category' will be scanned for abbrevs."
  (interactive)
  (setq yankpad--active-snippets nil)
  (setq yankpad--cache nil)
  (when (and (eq yankpad-descriptive-list-treatment 'abbrev)
             yankpad-category)
    (yankpad-load-abbrevs)))

(add-hook 'yankpad-switched-category-hook #'yankpad-reload)

;;;###autoload
(defun yankpad-insert ()
  "Insert an entry from the yankpad.
Uses `yankpad-category', and prompts for it if it isn't set."
  (interactive)
  (unless yankpad-category
    (or (yankpad-local-category-to-major-mode)
        (yankpad-set-category)))
  (yankpad-insert-from-current-category))

(defun yankpad-snippet-text (snippet)
  "Get text from SNIPPET, as a string.
SNIPPET can be a list: Yankpad's internal representation of
snippets. It can also be a string, in which case it should match
a snippet name in the current category."
  (if (stringp snippet)
      (if-let ((real-snippet (assoc snippet (yankpad-active-snippets))))
          (yankpad-snippet-text real-snippet)
        (error (concat "No snippet named " snippet)))
    (let ((snippet (copy-sequence snippet)))
      (let ((name (car snippet))
            (tags (nth 1 snippet))
            (src-blocks (nth 2 snippet))
            (content (nth 3 snippet)))
        (cond
         (src-blocks
          (yankpad-snippet-text
           (list name tags nil
                 (string-trim-right
                  (mapconcat
                   (lambda (x)
                     (org-remove-indentation (org-element-property :value x)))
                   src-blocks "")
                  "\n"))))
         ((or (member "func" tags)
              (member "results" tags))
          (yankpad--trigger-snippet-function name content))
         (t
          (if (string-empty-p content)
              (message (concat "\"" name "\" snippet doesn't contain any text. Check your yankpad file."))
            ;; Respect the tree level when yanking org-mode headings.
            (let ((prepend-asterisks 1))
              (when (and (equal major-mode 'org-mode)
                         (or yankpad-respect-current-org-level
                             (member "orglevel" tags))
                         (not (member "no_orglevel" tags))
                         (org-current-level))
                (setq prepend-asterisks (org-current-level)))
              (replace-regexp-in-string
               "^\\\\?[*]" (make-string prepend-asterisks ?*) content)))))))))

(defun yankpad--use-yasnippet ()
  "Determine if we can use yasnippet for pasting snippets.

The yasnippet package must be available and the setting
`yankpad-use-yasnippet' (default t) must be non-nil."
  (and yankpad-use-yasnippet
       (require 'yasnippet nil t)))

(defun yankpad--insert-snippet-text (text indent wrap)
  "Insert TEXT into buffer.  INDENT is whether/how to indent the snippet.
WRAP is the value for `yas-wrap-around-region', if `yasnippet' is available.
Use yasnippet and `yas-indent-line' if available."
  (if (and (yankpad--use-yasnippet)
           yas-minor-mode)
      (if (region-active-p)
          (yas-expand-snippet text (region-beginning) (region-end)
                              `((yas-indent-line (quote ,indent))
                                (yas-wrap-around-region (quote ,wrap))))
        (yas-expand-snippet text nil nil `((yas-indent-line (quote ,indent)))))
    (let ((start (point)))
      (insert text)
      (when indent
        (indent-region start (point))))))

(defun yankpad--trigger-snippet-function (snippetname content)
  "SNIPPETNAME can be an elisp function, without arguments, if CONTENT is nil.
If non-nil, CONTENT should hold a single `org-mode' src-block, to be executed.
Return the result of the function output as a string."
  (if (string-empty-p (string-trim content))
      (if (intern-soft snippetname)
          (prin1-to-string (funcall (intern-soft snippetname)))
        (error (concat "\"" snippetname "\" isn't a function")))
    (with-temp-buffer
      (delay-mode-hooks
        (org-mode)
        (insert content)
        (goto-char (point-min))
        (if (or (org-in-src-block-p)
                (and (ignore-errors (org-next-block 1))
                     (org-in-src-block-p)))
            (let ((result (org-babel-execute-src-block)))
              (if (stringp result) result (prin1-to-string result)))
          (error "First block in snippet must be an org-mode src block"))))))

(defun yankpad--run-snippet (snippet)
  "Triggers the SNIPPET behaviour."
  (setq yankpad--last-snippet snippet)
  (let ((snippet (copy-sequence snippet)))
    (run-hook-with-args 'yankpad-before-snippet-hook snippet)
    (let ((tags (nth 1 snippet)))
      (cond
       ((member "func" tags)
        (yankpad-snippet-text snippet))
       (t
        (let ((indent (cond ((member "indent_nil" tags)
                             nil)
                            ((member "indent_fixed" tags)
                             'fixed)
                            ((member "indent_auto" tags)
                             'auto)
                            ((and (yankpad--use-yasnippet) yas-minor-mode)
                             yas-indent-line)
                            (t t)))
              (wrap (cond ((or (not (and (yankpad--use-yasnippet) yas-minor-mode))
                               (member "wrap_nil" tags))
                           nil)
                          ((member "wrap" tags)
                           t)
                          (t yas-wrap-around-region))))
          (yankpad--insert-snippet-text (yankpad-snippet-text snippet) indent wrap)))))))

(defun yankpad-repeat ()
  "Repeats the last used snippet."
  (interactive)
  (if yankpad--last-snippet
      (yankpad--run-snippet yankpad--last-snippet)
    (error "There has been no previous snippet")))

(defun yankpad--remove-id-from-yankpad-capture ()
  "Remove ID property from last `yankpad-capture-snippet', save `yankpad-file'."
  (let* ((properties (ignore-errors (org-entry-properties org-capture-last-stored-marker)))
         (file (cdr (assoc "FILE" properties))))
    (when (and file (file-equal-p file yankpad-file))
      (when (org-entry-delete org-capture-last-stored-marker "ID")
        (with-current-buffer (get-file-buffer file)
          (save-buffer)))
      (yankpad-reload))))
(add-hook 'org-capture-after-finalize-hook #'yankpad--remove-id-from-yankpad-capture)

;;;###autoload
(defun yankpad-capture-snippet ()
  "`org-capture' a snippet to current `yankpad-category' (prompts if not set)."
  (interactive)
  (unless yankpad-category
    (yankpad-set-category))
  (let ((org-capture-entry
         `("y" "Yankpad" entry (file+headline ,yankpad-file ,yankpad-category)
           "* %?\n%i")))
    (org-capture)))

(defun yankpad-insert-from-current-category (&optional name)
  "Insert snippet NAME from `yankpad-category'.  Prompts for NAME unless set.
Does not change `yankpad-category'."
  (let ((snippets (yankpad-active-snippets)))
    (unless name
      (setq name (completing-read "Snippet: " snippets)))
    (if-let ((snippet (assoc name (yankpad-active-snippets))))
        (yankpad--run-snippet snippet)
      (message (concat "No snippet named " name))
      nil)))

(defun yankpad-keyword-with-bounds-at-point ()
  "Get current keyword and its bounds."
  (save-excursion
    (let (beg (end (point)))
      (when (re-search-backward "\\([[:blank:]\n]\\|^\\)" nil t 1)
        (setq beg (if (bolp)
                      (point)
                    (1+ (point))))
        (cons (buffer-substring-no-properties beg end) (cons beg end))))))

;;;###autoload
(defun yankpad-expand (&optional _first)
  "Replace symbol at point with a snippet.
Only works if the symbol is found in the first matching group of
`yankpad-expand-keyword-regex'.

This function can be added to `hippie-expand-try-functions-list'."
  (interactive)
  (when (and (called-interactively-p 'any)
             (not yankpad-category))
    (yankpad-set-category))
  (let* ((symbol-with-bounds (yankpad-keyword-with-bounds-at-point))
         (symbol (car symbol-with-bounds))
         (bounds (cdr symbol-with-bounds))
         (snippet-prefix (concat symbol yankpad-expand-separator))
         (possible-snippets '())
         (case-fold-search nil))
    (when (and symbol yankpad-category)
      (catch 'loop
        (mapc
         (lambda (snippet)
           ;; See if there's an expand regex
           (if-let ((regex (cdr (assoc "YP_EXPAND_REGEX" (nth 4 snippet)))))
               (when (string-match (concat "\\b" regex "\\b") symbol)
                 (let ((match (cddr (match-data)))
                       (snippet (copy-sequence snippet))
                       strings)
                   (while match
                     (push (substring symbol (pop match) (pop match)) strings))
                   (setf (nth 3 snippet)
                         (apply #'format (nth 3 snippet) (reverse strings)))
                   (delete-region (car bounds) (cdr bounds))
                   (yankpad--run-snippet snippet)
                   (throw 'loop snippet)))

             ;; Otherwise look for expand keyword
             (when (member symbol (butlast (split-string (car snippet) yankpad-expand-separator)))
               (delete-region (car bounds) (cdr bounds))
               (yankpad--run-snippet snippet)
               (throw 'loop snippet))

             ;; Collect suffix matches
             (let ((snippet-keyword (car (split-string (car snippet) yankpad-expand-separator))))
               (when (string-suffix-p snippet-keyword symbol)
                 (add-to-list 'possible-snippets (cons snippet-keyword snippet))))))
         (yankpad-active-snippets))

        ;; Find the longest suffix match and apply it, if we have one
        (when possible-snippets
          (let* ((snippet-info (seq-reduce
                                (lambda (acc it)
                                  (if (> (length (car it)) (length acc))
                                      it acc))
                                possible-snippets ""))
                 (snippet (cdr snippet-info))
                 (snippet-keyword (car snippet-info)))
            (delete-region (- (cdr bounds) (length snippet-keyword)) (cdr bounds))
            (yankpad--run-snippet (cdr snippet-info))
            (throw 'loop snippet)))
        nil))))

;;;###autoload
(defun yankpad-edit ()
  "Open the yankpad file for editing."
  (interactive)
  (let ((category yankpad-category))
    (find-file-other-window yankpad-file)
    (when category
      (goto-char (yankpad-category-marker category))
      (org-show-entry)
      (org-show-subtree))))

(defun yankpad--file-elements ()
  "Run `org-element-parse-buffer' on the `yankpad-file'."
  (with-temp-buffer
    (delay-mode-hooks
      (org-mode)
      (insert-file-contents yankpad-file)
      (org-element-parse-buffer))))

(defun yankpad--categories ()
  "Get the yankpad categories as a list."
  (let ((data (yankpad--file-elements)))
    (org-element-map data 'headline
      (lambda (h)
        (when (equal (org-element-property :level h)
                     yankpad-category-heading-level)
          (org-element-property :raw-value h))))))

(defun yankpad--global-categories ()
  "Get the yankpad categories with `yankpad-global-tag' as a list."
  (org-element-map (yankpad--file-elements) 'headline
    (lambda (h)
      (when (and (equal (org-element-property :level h)
                        yankpad-category-heading-level)
                 (member yankpad-global-tag (org-element-property :tags h)))
        (org-element-property :raw-value h)))))

(defun yankpad-category-marker (category)
  "Get marker to CATEGORY in `yankpad-file'."
  (org-element-map (yankpad--file-elements) 'headline
    (lambda (h)
      (when (and (equal (org-element-property :level h)
                        yankpad-category-heading-level)
                 (string-equal (org-element-property :raw-value h) category))
        (set-marker (make-marker)
                    (org-element-property :begin h)
                    (find-file-noselect yankpad-file))))
    nil t))

(defun yankpad--category-include-property (category-name)
  "Get the \"INCLUDE\" property from CATEGORY-NAME."
  (org-entry-get (yankpad-category-marker category-name) "INCLUDE"))

(defun yankpad-snippets-from-link (link)
  "Get snippets from LINK."
  (string-match "\\(^[[:alpha:]]+\\):\\(.+\\)" link)
  (let* ((type (match-string 1 link))
         (value (match-string 2 link))
         (file (car (split-string value "::" t)))
         (search (cadr (split-string value "::" t))))
    (cond
     ((string-equal type "id")
      (org-with-point-at (org-id-find value t)
        (yankpad-snippets-at-point t)))
     ((string-equal type "file")
      (with-current-buffer (find-file-noselect (if (file-name-absolute-p file)
                                                   file
                                                 (expand-file-name file)))
        (if search
            (let ((org-link-search-must-match-exact-headline t))
              (org-link-search search)
              (yankpad-snippets-at-point t))
          (cl-reduce #'append
                     (org-map-entries (lambda () (yankpad-snippets-at-point t)))))))
     (t
      (user-error "Link type `%s' isn't supported by Yankpad" type)))))

(defun yankpad-snippets-at-point (&optional remove-props)
  "Return snippets at point.
If REMOVE-PROPS is non nil, `org-mode' property drawers will be
removed from the snippet text."
  (let* ((heading (substring-no-properties (org-get-heading t t t t)))
         (link (and (string-match org-bracket-link-regexp heading)
                    (match-string 1 heading))))
    (if link
        (yankpad-snippets-from-link link)
      (if (save-excursion (org-goto-first-child))
          (cl-reduce #'append
                     (org-map-entries
                      (lambda () (yankpad-snippets-at-point t))
                      (format "+LEVEL=%s" (1+ (org-current-level))) 'tree))
        (let* ((text (substring-no-properties (org-remove-indentation (org-get-entry))))
               (tags (org-get-tags))
               (src-blocks (when (member "src" tags)
			     (org-element-map
				 (with-temp-buffer (insert text) (org-element-parse-buffer))
				 'src-block #'identity)))
               (properties (when (member "props" tags) (org-entry-properties))))
          (if (member "snippetlist" tags)
              nil
            (when (or remove-props (member "props" tags))
              (setq text (string-trim-left
                          (replace-regexp-in-string org-property-drawer-re "" text))))
            (list (list heading tags src-blocks text properties))))))))

(defvar yankpad--cache nil "An alist of category-name . snippets.")

(defun yankpad--snippets (category-name)
  "Get an alist of the snippets in CATEGORY-NAME.
Each snippet is a list (NAME TAGS SRC-BLOCKS TEXT).
Tries to get a cached version from `yankpad--cache' if there is one."
  (or (alist-get category-name yankpad--cache)
      (let* ((propertystring (yankpad--category-include-property category-name))
             (include (when propertystring
                        (split-string propertystring "|")))
             (snippets
              (append
               (when (eq yankpad-descriptive-list-treatment 'snippet)
                 (mapcar (lambda (d)
                           (list (concat (car d) yankpad-expand-separator) nil nil (cdr d)))
                         (yankpad-category-descriptions category-name)))
               (org-with-point-at (yankpad-category-marker category-name)
                 (cl-reduce #'append
                            (org-map-entries #'yankpad-snippets-at-point
                                             (format "+LEVEL=%s" (1+ yankpad-category-heading-level))
                                             'tree)))))
             (all-snippets (append snippets (cl-reduce #'append (mapcar #'yankpad--snippets include)))))
        (add-to-list 'yankpad--cache (cons category-name all-snippets))
        all-snippets)))

;;;###autoload
(defun yankpad-map ()
  "Create and execute a keymap out of the last tags of snippets in `yankpad-category'."
  (interactive)
  (define-prefix-command 'yankpad-keymap)
  (let (map-help)
    (mapc (lambda (snippet)
            (let ((last-tag (car (last (nth 1 snippet)))))
              (when (and last-tag
                         (not (string-prefix-p "indent_" last-tag))
                         (not (string-prefix-p "wrap" last-tag))
                         (not (member last-tag '("func" "results" "src" "props"))))
                (let ((heading (car snippet))
                      (key (substring-no-properties last-tag)))
                  (push (cons key (format "[%s] %s " key heading)) map-help)
                  (define-key yankpad-keymap (kbd key)
                              `(lambda ()
                                 (interactive)
                                 (yankpad--run-snippet ',snippet)))))))
          (yankpad-active-snippets))
    (let ((message-log-max nil))
      (message "yankpad: %s"
               (if map-help
                   (apply 'concat (mapcar 'cdr (sort map-help
                                                     (lambda (x y)
                                                       (string-lessp (car x) (car y))))))
                 (format "nothing is defined in %s" yankpad-category)))))
  (set-transient-map 'yankpad-keymap))

(defmacro yankpad-map-simulate (key)
  "Create and return a command which presses KEY in `yankpad-map'."
  `(defun ,(intern (concat "yankpad-map-press-" key)) ()
     ,(concat "Press '" key "' in `yankpad-map'.")
     (interactive)
     (setq unread-command-events (listify-key-sequence (kbd ,key)))
     (yankpad-map)))

(defun yankpad-local-category-to-major-mode ()
  "Try to change `yankpad-category' to match the buffer's major mode.
If successful, make `yankpad-category' buffer-local.
If no major mode category is found, it uses `yankpad-default-category',
if that is defined in the `yankpad-file'."
  (when (file-exists-p yankpad-file)
    (let* ((categories (yankpad--categories))
           (category (or (car (member (symbol-name major-mode)
                                      categories))
                         (car (member yankpad-default-category categories)))))
      (when category (yankpad-set-local-category category)))))

(add-hook 'after-change-major-mode-hook #'yankpad-local-category-to-major-mode)
;; Run the function when yankpad is loaded
(yankpad-local-category-to-major-mode)

(defun yankpad-local-category-to-projectile ()
  "Try to change `yankpad-category' to match the `projectile-project-name'.
If successful, make `yankpad-category' buffer-local."
  (when (and (require 'projectile nil t)
             (file-exists-p yankpad-file))
    (when-let* ((category (car (member (projectile-project-name)
                                       (yankpad--categories)))))
      (yankpad-set-local-category category))))

(eval-after-load "projectile"
  (add-hook 'projectile-find-file-hook #'yankpad-local-category-to-projectile))
;; Run the function when yankpad is loaded
(yankpad-local-category-to-projectile)

(with-eval-after-load "auto-yasnippet"
  (defun yankpad-aya-persist (name)
    "Add `aya-current' as NAME to `yankpad-category'."
    (interactive
     (if (eq aya-current "")
         (user-error "Aborting: You don't have a current auto-snippet defined")
       (list (read-string "Snippet name: "))))
    (unless yankpad-category (yankpad-set-category))
    (let ((org-capture-entry
           `("y" "Yankpad" entry (file+headline ,yankpad-file ,yankpad-category)
             ,(format "* %s\n%s\n" name aya-current)
             :immediate-finish t)))
      (org-capture))))

(defun yankpad-category-descriptions (category)
  "Get a list of all descriptions in CATEGORY.
Descriptions are fetched from descriptive lists in `org-mode',
under the same heading level as CATEGORY.
Each element is (KEY . DESCRIPTION), both strings."
  (org-with-point-at (yankpad-category-marker category)
    (org-narrow-to-subtree)
    (apply
     #'append
     (org-element-map (org-element-parse-buffer) 'plain-list
       (lambda (dl)
         (let ((parent (funcall (if (version< (org-version) "8.3")
                                    #'org-export-get-genealogy
                                  #'org-element-lineage)
                                dl '(headline))))
           (when (and (equal (org-element-property :type dl) 'descriptive)
                      (or (equal (org-element-property :level parent)
                                 yankpad-category-heading-level)
                          (save-excursion
                            (goto-char (org-element-property :begin parent))
                            (org-goto-first-child))
                          (member "snippetlist" (org-element-property :tags parent))))
             (org-element-map dl 'item
               (lambda (i)
                 (cons (org-no-properties (car (org-element-property :tag i)))
                       (string-trim (buffer-substring-no-properties
                                     (org-element-property :contents-begin i)
                                     (org-element-property :contents-end i)))))))))))))

(defun yankpad--get-completion-candidates (prefix snippets categories)
  "Return a list of completion candidates based on PREFIX and separator."
  (let ((candidates '())
        (sep yankpad-expand-separator))
    (dolist (cat categories)
      (when (string-prefix-p prefix cat t)
        (push cat candidates)))
    (dolist (snippet snippets)
      (let* ((name (car snippet))
             (name-parts (split-string name sep t))
             (keyword (car name-parts))
             (annotation (mapconcat 'identity (cdr name-parts) sep)))
        (when (and keyword (string-prefix-p prefix keyword t))
          (push (propertize keyword 'annotation annotation) candidates))))
    (sort (delete-dups candidates) #'string-lessp)))

(defun yankpad--doc-buffer (candidate)
  "Return a buffer with detailed documentation for the Yankpad CANDIDATE."
  (let ((snippets (yankpad-active-snippets))
        (categories (yankpad--categories)))
    (let* ((full-snippet-name
            (cl-find-if (lambda (snippet)
                          (string-prefix-p candidate (car snippet)))
                        snippets))
           (snippet (assoc (car full-snippet-name) snippets)))
      (when snippet
        (with-current-buffer (get-buffer-create "*Yankpad Doc*")
          (erase-buffer)
          (insert (format "Snippet: %s\n\n" (car snippet)))
          (let ((snippet-text (yankpad-snippet-text snippet)))
            (when snippet-text
              (insert "Content:\n")
              (insert snippet-text)
              (insert "\n\n")))
          (when (> (length snippet) 1)
            (insert "Additional details:\n")
            (dolist (detail (cdr snippet))
              (insert (format "- %S\n" detail))))
          (goto-char (point-min))
          (current-buffer))))))

;;;###autoload
(defun yankpad-capf ()
  "Completion-at-point function for Yankpad with advanced support."
  (interactive)
  (when (and (featurep 'yankpad) yankpad-file)
    (let* ((bounds (or (bounds-of-thing-at-point 'word) (cons (point) (point))))
           (start (car bounds))
           (end (cdr bounds))
           (prefix (buffer-substring-no-properties start end))
           (snippets (yankpad-active-snippets))
           (categories (yankpad--categories))
           (completions (yankpad--get-completion-candidates prefix snippets categories)))
      (when (and completions
                 (or (> (length prefix) 0)
                     (> (length completions) 0)))
        (list start end completions
              :annotation-function (lambda (candidate)
                                     (get-text-property 0 'annotation candidate))
              :company-kind (lambda (_) 'snippet)
              :company-doc-buffer #'yankpad--doc-buffer
              :exit-function (lambda (candidate status)
                               (when (string= status "finished")
                                 (let* ((current-point (point))
                                        (region-start (- current-point (length candidate))))
                                   (delete-region region-start current-point)
                                   (if (member candidate categories)
                                       (progn
                                         (insert candidate)
                                         (yankpad-set-category)
                                         (message "Category changed to %s" candidate))
                                     (let* ((full-snippet-name
                                             (cl-find-if (lambda (snippet)
                                                          (string-prefix-p candidate (car snippet)))
                                                        snippets))
                                            (yankpad-snippet (assoc (car full-snippet-name) snippets)))
                                       (when yankpad-snippet
                                         (yankpad--run-snippet yankpad-snippet))))))
              :exclusive 'yes))))))

(provide 'yankpad)
;;; yankpad.el ends here
