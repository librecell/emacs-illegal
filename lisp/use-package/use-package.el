;;; use-package.el --- A use-package declaration for simplifying your .emacs

;; Copyright (C) 2012 John Wiegley

;; Author: John Wiegley <jwiegley@gmail.com>
;; Created: 17 Jun 2012
;; Version: 2.0
;; Package-Requires: ((bind-key "1.0") (diminish "0.44"))
;; Keywords: dotemacs startup speed config package
;; X-URL: https://github.com/jwiegley/use-package

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 2, or (at
;; your option) any later version.

;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.

;;; Commentary:

;; The `use-package' declaration macro allows you to isolate package
;; configuration in your ".emacs" in a way that is performance-oriented and,
;; well, just tidy.  I created it because I have over 80 packages that I use
;; in Emacs, and things were getting difficult to manage.  Yet with this
;; utility my total load time is just under 1 second, with no loss of
;; functionality!
;;
;; Please see README.md from the same repository for documentation.

;;; Code:

(require 'bind-key)
(require 'bytecomp)
(require 'diminish nil t)

(declare-function package-installed-p 'package)

(defgroup use-package nil
  "A use-package declaration for simplifying your `.emacs'."
  :group 'startup)

(defcustom use-package-verbose nil
  "Whether to report about loading and configuration details.

If you customize this, then you should require the `use-package'
feature in files that use one of the macros `use-package' or
`use-package-with-elapsed-timer', even if these files only
contain compiled expansions of the macros.  If you don't do so,
then the expanded macros do their job silently."
  :type 'boolean
  :group 'use-package)

(defcustom use-package-minimum-reported-time 0.1
  "Minimal load time that will be reported.

Note that `use-package-verbose' has to be set to t, for anything
to be reported at all.

If you customize this, then you should require the `use-package'
feature in files that use one of the macros `use-package' or
`use-package-with-elapsed-timer', even if these files only
contain compiled expansions of the macros.  If you don't do so,
then the expanded macros do their job silently."
  :type 'number
  :group 'use-package)

(defmacro use-package-with-elapsed-timer (text &rest body)
  (declare (indent 1))
  (let ((nowvar (make-symbol "now")))
    (if (bound-and-true-p use-package-verbose)
        `(let ((,nowvar (current-time)))
           (message "%s..." ,text)
           (prog1
               (progn ,@body)
             (let ((elapsed
                    (float-time (time-subtract (current-time) ,nowvar))))
               (if (> elapsed
                      (or (bound-and-true-p use-package-minimum-reported-time)
                          "0.01"))
                   (message "%s...done (%.3fs)" ,text elapsed)
                 (message "%s...done" ,text)))))
      `(progn ,@body))))

(defsubst use-package-error (msg)
  "Report MSG as an error, so the user knows it came from this package."
  (error "use-package: %s" msg))

(defun use-package-normalize-form (label args)
  "Given a list of forms, return it wrapped in `progn'."
  (unless (listp (car args))
    (use-package-error (concat label " wants a sexp or list of sexps")))
  (if (= (length args) 1)
      (car args)
    (cons 'progn args)))

(defsubst use-package-normalize-value (label arg)
  "Normalize a value."
  (cond ((symbolp arg)
         `(symbol-value ',arg))
        ((functionp arg)
         `(funcall #',arg))
        (t arg)))

(defun use-package-normalize-diminish (name-symbol label arg &optional recursed)
  "Normalize the arguments to diminish down to a list of one of two forms:
     SYMBOL
     (SYMBOL . STRING)"
  (cond
   ((symbolp arg)
    (list arg))
   ((stringp arg)
    (list (cons (intern (concat (symbol-name name-symbol) "-mode")) arg)))
   ((and (consp arg) (stringp (cdr arg)))
    (list arg))
   ((and (not recursed) (listp arg) (listp (cdr arg)))
    (mapcar #'(lambda (x) (car (use-package-normalize-diminish
                           name-symbol label x t))) arg))
   (t
    (use-package-error
     (concat label " wants a string, symbol, "
             "(symbol . string) or list of these")))))

(defun use-package-only-one (label args f)
  "Call F on the first member of ARGS if it has exactly one element."
  (declare (indent 1))
  (cond
   ((and (listp args) (listp (cdr args))
         (= (length args) 1))
    (funcall f label (car args)))
   (t
    (use-package-error
     (concat label " wants exactly one argument")))))

(defun use-package-as-one (label args f)
  "Call F on the first element of ARGS if it has one element, or all of ARGS."
  (declare (indent 1))
  (if (and (listp args) (listp (cdr args)))
      (if (= (length args) 1)
          (funcall f label (car args))
        (funcall f label args))
    (use-package-error
     (concat label " wants a list"))))

(defsubst use-package-is-sympair (x)
  "Return t if X has the type (STRING . SYMBOL)."
  (and (consp x)
       (stringp (car x))
       (symbolp (cdr x))))

(defun use-package-normalize-pairs (name-symbol label arg &optional recursed)
  "Normalize a list of string/symbol pairs."
  (cond
   ((stringp arg)
    (list (cons arg name-symbol)))
   ((use-package-is-sympair arg)
    (list arg))
   ((and (not recursed) (listp arg) (listp (cdr arg)))
    (mapcar #'(lambda (x) (car (use-package-normalize-pairs
                           name-symbol label x t))) arg))
   (t
    (use-package-error
     (concat label " wants a string, (string . symbol) or list of these")))))

(defun use-package-normalize-symbols (label arg &optional recursed)
  "Normalize a list of symbols."
  (cond
   ((symbolp arg)
    (list arg))
   ((and (not recursed) (listp arg) (listp (cdr arg)))
    (mapcar #'(lambda (x) (car (use-package-normalize-symbols label x t))) arg))
   (t
    (use-package-error
     (concat label " wants a symbol, or list of symbols")))))

(defun use-package-normalize-paths (label arg &optional recursed)
  "Normalize a list of filesystem paths."
  (cond
   ((or (symbolp arg) (functionp arg))
    (let ((value (use-package-normalize-value label arg)))
      (use-package-normalize-paths label (eval value))))
   ((stringp arg)
    (let ((path (if (file-name-absolute-p arg)
                    arg
                  (expand-file-name arg user-emacs-directory))))
      (if (file-directory-p path)
          (list path)
        (use-package-error
         (concat label " wants a directory path, or list of paths")))))
   ((and (not recursed) (listp arg) (listp (cdr arg)))
    (mapcar #'(lambda (x)
                (car (use-package-normalize-paths label x t))) arg))
   (t
    (use-package-error
     (concat label " wants a directory path, or list of paths")))))

(defun use-package-split-list (pred xs)
  (let ((ys (list nil)) (zs (list nil)) flip)
    (dolist (x xs)
      (if flip
          (nconc zs (list x))
        (if (funcall pred x)
            (progn
              (setq flip t)
              (nconc zs (list x)))
          (nconc ys (list x)))))
    (cons (cdr ys) (cdr zs))))

(defun use-package-normalize-plist (name-symbol input)
  "Given a pseudo-plist, normalize it to a regular plist."
  (if (null input)
      nil
    (let* ((head (car input))
           (xs (use-package-split-list #'keywordp (cdr input)))
           (args (car xs))
           (tail (cdr xs)))
      (append
       (list
        (cond ((memq head '(:when :unless)) :if)
              (t head))
        (pcase head
          ((or :bind :bind* :bind-keymap :bind-keymap* :interpreter :mode)
           (use-package-as-one (symbol-name head) args
             (apply-partially #'use-package-normalize-pairs name-symbol)))

          ((or :commands :defines :functions :requires)
           (use-package-as-one (symbol-name head) args
             #'use-package-normalize-symbols))

          ((or :defer :demand :disabled)
           (if (null args)
               t
             (use-package-only-one (symbol-name head) args
               #'use-package-normalize-value)))

          (:ensure
           (if (null args)
               t
             (use-package-only-one (symbol-name head) args
               (lambda (label arg)
                 (if (symbolp arg)
                     arg
                   (use-package-error
                    (concat ":ensure wants an optional package name "
                            "(an unquoted symbol name)")))))))

          ((or :if :when :unless)
           (use-package-only-one (symbol-name head) args
             #'use-package-normalize-value))

          (:diminish
           (use-package-as-one (symbol-name head) args
             (apply-partially #'use-package-normalize-diminish name-symbol)))

          ((or :preface :init :config :idle)
           (use-package-normalize-form (symbol-name head) args))

          (:idle-priority
           (if (null args)
               5
             (use-package-only-one (symbol-name head) args
               (lambda (label arg)
                 (if (numberp arg)
                     arg
                   (use-package-error
                    ":idle-priority wants an optional number"))))))

          (:load-path
           (use-package-as-one (symbol-name head) args
             #'use-package-normalize-paths))

          (:pin
           (use-package-only-one (symbol-name head) args
             (lambda (label arg)
               (if (stringp arg)
                   arg
                 (use-package-error ":pin wants an archive name (a string)")))))

          (_ (use-package-error (format "Unrecognized keyword: %s" head)))))
       (use-package-normalize-plist name-symbol tail)))))

(defsubst use-package-cat-maybes (&rest elems)
  "Delete all empty lists from ELEMS (nil or (list nil)), and append them."
  (apply #'nconc (delete nil (delete (list nil) elems))))

(defsubst use-package-expand (name label form)
  (declare (indent 1))
  (when form
    (let ((err (make-symbol "err"))
          (fmt (format "Failure in %s of %s: %%S" label name)))
      `(condition-case-unless-debug ,err
           ,form
         (error
          (ignore
           (display-warning 'use-package (format ,fmt ,err) :error)))))))

(defun use--package (name-symbol name-string args)
  "See docstring for `use-package'."
  (let*
      ((commands (plist-get args :commands))

       ;; Note: evaluation of this forms possibly extends the value of
       ;; `commands'.
       (bindings
        (append
         (mapcar #'(lambda (binding)
                     `(bind-key ,(car binding)
                                #'(lambda () (interactive)
                                    (use-package-autoload-keymap
                                     ',(cdr binding) ,name-symbol nil))))
                 (plist-get args :bind-keymap))

         (mapcar #'(lambda (binding)
                     `(bind-key ,(car binding)
                                #'(lambda () (interactive)
                                    (use-package-autoload-keymap
                                     ',(cdr binding) ,name-symbol t))))
                 (plist-get args :bind-keymap*))

         (mapcar #'(lambda (mode)
                     (push (cdr mode) commands)
                     `(add-to-list 'auto-mode-alist ',mode))
                 (plist-get args :mode))

         (mapcar #'(lambda (interpreter)
                     (push (cdr interpreter) commands)
                     `(add-to-list 'interpreter-mode-alist ',interpreter))
                 (plist-get args :interpreter))

         (mapcar #'(lambda (binding)
                     (push (cdr binding) commands)
                     `(bind-key ,(car binding) #',(cdr binding)))
                 (plist-get args :bind))

         (mapcar #'(lambda (binding)
                     (push (cdr binding) commands)
                     `(bind-key* ,(car binding) #',(cdr binding)))
                 (plist-get args :bind*))))

       ;; Should we defer loading of the package lazily?
       (defer-loading (and (not (plist-get args :demand))
                           (or commands (plist-get args :defer))))

       ;; These are all the configurations to be made after the package has
       ;; loaded.
       (config-body
        (use-package-cat-maybes
         (list (use-package-expand name-string ":config"
                 (plist-get args :config)))

         (mapcar #'(lambda (var)
                     (if (listp var)
                         `(diminish (quote ,(car var)) ,(cdr var))
                       `(diminish (quote ,var))))
                 (plist-get args :diminish)))))

    ;; Return the main body of the macro
    (use-package-cat-maybes
     (list (plist-get args :preface))

     ;; Setup the load-path
     (mapcar #'(lambda (path) `(add-to-list 'load-path ,path))
             (plist-get args :load-path))

     ;; Setup any required autoloads
     (if defer-loading
         (mapcar #'(lambda (command) `(autoload #',command ,name-string nil t))
                 commands))

     (when (bound-and-true-p byte-compile-current-file)
       (mapcar #'(lambda (fn)
                   `(declare-function ,fn ,name-string))
               (append (plist-get args* :functions) commands)))

     ;; The user's initializations
     (list (use-package-expand name-string ":init"
             (plist-get args :init)))

     (if defer-loading
         (use-package-cat-maybes
          bindings
          (if config-body
              (let ((body
                     `(use-package-with-elapsed-timer
                        ,(format "Configuring package %s"
                                 name-string)
                        ,@config-body)))
                (list `(eval-after-load ,name-string
                         ',body)))))
       `((use-package-with-elapsed-timer
           ,(format "Loading package %s" name-string)
           (if (not (require ',name-symbol nil t))
               (message "Could not load package %s" ,name-string)
             ,@(use-package-cat-maybes
                bindings
                config-body)
             t))))

     ;; Any :idle form that should be executed later
     (let ((idle-body (plist-get args :idle)))
       (when idle-body
         `((require 'use-package)
           (use-package-init-on-idle
            #'(lambda () ,(use-package-expand name-string ":idle" idle-body))
            ,(plist-get args :idle-priority)))))

     (list t))))

(defmacro use-package (name &rest args)
  "Declare an Emacs package by specifying a group of configuration options.

For full documentation, please see the README file that came with
this file.  Usage:

  (use-package package-name
     [:keyword [option]]...)

:init          Code to run before PACKAGE-NAME has been loaded.
:config        Code to run after PACKAGE-NAME has been loaded.  Note that if
               loading is deferred for any reason, this code does not execute
               until the lazy load has occurred.

:mode          Form to be added to `auto-mode-alist'.
:interpreter   Form to be added to `interpreter-mode-alist'.

:commands      Define autoloads for commands that will be defined by the
               package.  This is useful if the package is being lazily loaded,
               and you wish to conditionally call functions in your `:init'
               block that are defined in the package.

:bind          Bind keys, and define autoloads for the bound commands.
:bind*         Bind keys, and define autoloads for the bound commands,
               *overriding all minor mode bindings*.
:bind-keymap   Bind a key prefix to an auto-loaded keymap defined in the
               package.  This is like `:bind', but for keymaps.
:bind-keymap*  Like `:bind-keymap', but overrides all minor mode bindings

:defer         Defer loading of a package -- this is implied when using
               `:commands', `:bind', `:bind*', `:mode' or `:interpreter'.
:demand        Prevent deferred loading in all cases.

:if EXPR       Initialize and load only if EXPR evaluates to a non-nil value.
:disabled      The package is ignored completely, the same as `:if nil'.
:defines       Declare certain variables to silence the byte-compiler.
:functions     Declare certain functions to silence the byte-compiler.
:load-path     Add to the `load-path' before attempting to load the package.
:diminish      Support for diminish.el (if installed).
:idle          Adds a form to be run on an idle timer after initialization.
:idle-priority Schedules the :idle form to run with the given priority (lower
               priorities run first).  Default priority is 5; forms with the
               same priority are run in the order in which they are evaluated.
:ensure        Loads the package using package.el if necessary.
:pin           Pin the package to an archive."
  (declare (indent 1))
  (unless (member :disabled args)
    (let* ((name-string (if (stringp name) name (symbol-name name)))
           (name-symbol (if (stringp name) (intern name) name))
           (args*
            (condition-case-unless-debug err
                (use-package-normalize-plist name-symbol args)
              (error (message (error-message-string err))))))

      ;; Pin any packages that have been marked with `:pin'.
      (let ((archive-name (plist-get args* :pin)))
        (when archive-name
          (use-package-pin-package name archive-name)))

      ;; Ensure that the package has been installed, if marked with
      ;; `:ensure'.
      (let* ((ensure (plist-get args* :ensure))
             (package-name (or (and (eq ensure t) name) ensure)))
        (when package-name
          (require 'package)
          (use-package-ensure-elpa package-name)))

      ;; At this point, we can expand the macro using the helper function.
      ;; `use--package'.
      (let*
          ((body (use--package name-symbol name-string args*))
           (pred (plist-get args* :if))
           (expansion (if pred
                          `(when ,pred ,@body)
                        (if (= (length body) 1)
                            (car body)
                          `(progn ,@body))))
           (requires (plist-get args* :requires))

           (pre-compile-load
            ;; When byte-compiling, load the package here so that all of its
            ;; symbols are in scope.
            (when (bound-and-true-p byte-compile-current-file)
              `((eval-when-compile
                  ,@(mapcar #'(lambda (var) `(defvar ,var))
                            (plist-get args* :defines))
                  (with-demoted-errors
                      ,(format "Error in %s: %%S" name-string)
                    (message "Compiling package %s" ,name-string)
                    (require ',name-symbol nil t))))))

           (body*
            (use-package-cat-maybes
             pre-compile-load
             (list
              (if (null requires)
                  expansion
                `(if ,(if (listp requires)
                          `(not (member nil (mapcar #'featurep ',requires)))
                        `(featurep ',requires))
                     ,expansion))))))

        ;; If a dynamic test has been requested -- that certain other
        ;; packages must be loaded first, before attempting to load and
        ;; configure this package -- wrap that logic around the expansion.
        (if (= (length body*) 1)
            (car body*)
          `(progn ,@body*))))))

(defun use-package-autoload-keymap (keymap-symbol package override)
  "Loads PACKAGE and then binds the key sequence used to invoke
this function to KEYMAP-SYMBOL.  It then simulates pressing the
same key sequence a again, so that the next key pressed is routed
to the newly loaded keymap.

This function supports use-package's :bind-keymap keyword.  It
works by binding the given key sequence to an invocation of this
function for a particular keymap.  The keymap is expected to be
defined by the package.  In this way, loading the package is
deferred until the prefix key sequence is pressed."
  (if (not (require package nil t))
      (error "Could not load package %s" package)
    (if (and (boundp keymap-symbol)
             (keymapp (symbol-value keymap-symbol)))
        (let ((key (key-description (this-command-keys-vector)))
              (keymap (symbol-value keymap-symbol)))
          (if override
              ;; eval form is necessary to avoid compiler error
              `(eval `(bind-key* ,key ,keymap))
            (bind-key key keymap))
          (setq unread-command-events
                (listify-key-sequence (this-command-keys-vector))))
      (error "use-package: package %s failed to define keymap %s"
             package keymap-symbol))))

(defconst use-package-font-lock-keywords
  '(("(\\(use-package\\(?:-with-elapsed-timer\\)?\\)\\_>[ \t']*\\(\\(?:\\sw\\|\\s_\\)+\\)?"
     (1 font-lock-keyword-face)
     (2 font-lock-constant-face nil t))))

(font-lock-add-keywords 'emacs-lisp-mode use-package-font-lock-keywords)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; :idle support
;;

(defcustom use-package-idle-interval 3
  "Time to wait when using :idle in a `use-package' specification."
  :type 'number
  :group 'use-package)

(defvar use-package-idle-timer nil)
(defvar use-package-idle-forms (make-hash-table))

(defun use-package-start-idle-timer ()
  "Ensure that the idle timer is running."
  (unless use-package-idle-timer
    (setq use-package-idle-timer
          (run-with-idle-timer use-package-idle-interval t
                               'use-package-idle-eval))))

(defun use-package-init-on-idle (form priority)
  "Add a new form to the idle queue."
  (use-package-start-idle-timer)
  (puthash priority
           (append (gethash priority use-package-idle-forms)
                   (list form))
           use-package-idle-forms))

(defun use-package-idle-priorities ()
  "Get a list of all priorities in the idle queue.
The list is sorted in the order forms should be run."
  (let ((priorities nil))
    (maphash #'(lambda (priority forms)
                 (setq priorities (cons priority priorities)))
             use-package-idle-forms)
    (sort priorities '<)))

(defun use-package-idle-pop ()
  "Pop the top-priority task from the idle queue.
Return nil when the queue is empty."
  (let* ((priority        (car (use-package-idle-priorities)))
         (forms           (gethash priority use-package-idle-forms))
         (first-form      (car forms))
         (forms-remaining (cdr forms)))
    (if forms-remaining
        (puthash priority forms-remaining use-package-idle-forms)
      (remhash priority use-package-idle-forms))
    first-form))

(defun use-package-idle-eval ()
  "Start to eval idle-commands from the idle queue."
  (let ((next (use-package-idle-pop)))
    (if next
        (progn
          (when use-package-verbose
            (message "use-package idle: %s" next))
          (condition-case e
              (funcall next)
            (error
             (error "Failure on use-package idle.  Form: %s, Error: %s"
                    next e)))
          ;; recurse after a bit
          (when (sit-for use-package-idle-interval)
            (use-package-idle-eval)))
      ;; finished (so far!)
      (cancel-timer use-package-idle-timer)
      (setq use-package-idle-timer nil))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; :pin and :ensure support
;;

(eval-when-compile
  (defvar package-pinned-packages)
  (defvar package-archives))

(defun use-package-pin-package (package archive)
  "Pin PACKAGE to ARCHIVE."
  (unless (boundp 'package-pinned-packages)
    (setq package-pinned-packages ()))
  (let ((archive-symbol (if (symbolp archive)
                            archive
                          (intern archive)))
        (archive-name   (if (stringp archive)
                            archive
                          (symbol-name archive))))
    (if (use-package--archive-exists-p archive-symbol)
        (add-to-list 'package-pinned-packages
                     (cons package archive-name))
      (error "Archive '%s' requested for package '%s' is not available."
             archive-name package))
    (package-initialize t)))

(defun use-package--archive-exists-p (archive)
  "Check if a given ARCHIVE is enabled.

ARCHIVE can be a string or a symbol or 'manual to indicate a
manually updated package."
  (if (member archive '(manual "manual"))
      't
    (let ((valid nil))
      (dolist (pa package-archives)
        (when (member archive (list (car pa) (intern (car pa))))
          (setq valid 't)))
      valid)))

(defun use-package-ensure-elpa (package)
  (when (not (package-installed-p package))
    (package-install package)))

(put 'use-package 'lisp-indent-function 'defun)
(put 'use-package-expand 'lisp-indent-function 'defun)
(put 'use-package-only-one 'lisp-indent-function 'defun)
(put 'use-package-as-one 'lisp-indent-function 'defun)
(put 'use-package-with-elapsed-timer 'lisp-indent-function 'defun)

(provide 'use-package)

;; Local Variables:
;; indent-tabs-mode: nil
;; End:

;;; use-package.el ends here
