;;; cl-preloaded.el --- Preloaded part of the CL library  -*- lexical-binding: t; -*-

;; Copyright (C) 2015-2024 Free Software Foundation, Inc

;; Author: Stefan Monnier <monnier@iro.umontreal.ca>
;; Package: emacs

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; The cl-defstruct macro is full of circularities, since it uses the
;; cl-structure-class type (and its accessors) which is defined with itself,
;; and it setups a default parent (cl-structure-object) which is also defined
;; with cl-defstruct, and to make things more interesting, the class of
;; cl-structure-object is of course an object of type cl-structure-class while
;; cl-structure-class's parent is cl-structure-object.
;; Furthermore, the code generated by cl-defstruct generally assumes that the
;; parent will be loaded when the child is loaded.  But at the same time, the
;; expectation is that structs defined with cl-defstruct do not need cl-lib at
;; run-time, which means that the `cl-structure-object' parent can't be in
;; cl-lib but should be preloaded.  So here's this preloaded circular setup.

;;; Code:

(eval-when-compile (require 'cl-lib))
(eval-when-compile (require 'cl-macs))  ;For cl--struct-class.

;; The `assert' macro from the cl package signals
;; `cl-assertion-failed' at runtime so always define it.
(define-error 'cl-assertion-failed (purecopy "Assertion failed"))

(defun cl--assertion-failed (form &optional string sargs args)
  (if debug-on-error
      (funcall debugger 'error `(cl-assertion-failed (,form ,string ,@sargs)))
    (if string
        (apply #'error string (append sargs args))
      (signal 'cl-assertion-failed `(,form ,@sargs)))))

(defun cl--builtin-type-p (name)
  (if (not (fboundp 'built-in-class-p)) ;; Early bootstrap
      nil
    (let ((class (and (symbolp name) (get name 'cl--class))))
      (and class (built-in-class-p class)))))

(defun cl--struct-name-p (name)
  "Return t if NAME is a valid structure name for `cl-defstruct'."
  (and name (symbolp name) (not (keywordp name))
       (not (cl--builtin-type-p name))))

;; When we load this (compiled) file during pre-loading, the cl--struct-class
;; code below will need to access the `cl-struct' info, since it's considered
;; already as its parent (because `cl-struct' was defined while the file was
;; compiled).  So let's temporarily setup a fake.
(defvar cl-struct-cl-structure-object-tags nil)
(unless (cl--find-class 'cl-structure-object)
  (setf (cl--find-class 'cl-structure-object) 'dummy))

(fset 'cl--make-slot-desc
      ;; To break circularity, we pre-define the slot constructor by hand.
      ;; It's redefined a bit further down as part of the cl-defstruct of
      ;; cl-slot-descriptor.
      ;; BEWARE: Obviously, it's important to keep the two in sync!
      (lambda (name &optional initform type props)
        (record 'cl-slot-descriptor
                name initform type props)))

;; In use by comp.el
(defun cl--struct-get-class (name)
  (or (if (not (symbolp name)) name)
      (cl--find-class name)
      (if (not (get name 'cl-struct-type))
          ;; FIXME: Add a conversion for `eieio--class' so we can
          ;; create a cl-defstruct that inherits from an eieio class?
          (error "%S is not a struct name" name)
        ;; Backward compatibility with a defstruct compiled with a version
        ;; cl-defstruct from Emacs<25.  Convert to new format.
        (let ((tag (intern (format "cl-struct-%s" name)))
              (type-and-named (get name 'cl-struct-type))
              (descs (get name 'cl-struct-slots)))
          (cl-struct-define name nil (get name 'cl-struct-include)
                            (unless (and (eq (car type-and-named) 'vector)
                                         (null (cadr type-and-named))
                                         (assq 'cl-tag-slot descs))
                              (car type-and-named))
                            (cadr type-and-named)
                            descs
                            (intern (format "cl-struct-%s-tags" name))
                            tag
                            (get name 'cl-struct-print))
          (cl--find-class name)))))

(defun cl--plist-to-alist (plist)
  (let ((res '()))
    (while plist
      (push (cons (pop plist) (pop plist)) res))
    (nreverse res)))

(defun cl--struct-register-child (parent tag)
  ;; Can't use (cl-typep parent 'cl-structure-class) at this stage
  ;; because `cl-structure-class' is defined later.
  (while (cl--struct-class-p parent)
    (add-to-list (cl--struct-class-children-sym parent) tag)
    ;; Only register ourselves as a child of the leftmost parent since structs
    ;; can only have one parent.
    (setq parent (car (cl--struct-class-parents parent)))))

;;;###autoload
(defun cl-struct-define (name docstring parent type named slots children-sym
                              tag print)
  (cl-check-type name (satisfies cl--struct-name-p))
  (unless type
    ;; Legacy defstruct, using tagged vectors.  Enable backward compatibility.
    (with-suppressed-warnings ((obsolete cl-old-struct-compat-mode))
      (message "cl-old-struct-compat-mode is obsolete!")
      (cl-old-struct-compat-mode 1)))
  (when (eq type 'record)
    ;; Defstruct using record objects.
    (setq type nil)
    ;; `cl-structure-class' and `cl-structure-object' are allowed to be
    ;; defined without specifying the parent, because their parent
    ;; doesn't exist yet when they're defined.
    (cl-assert (or parent (memq name '(cl-structure-class
                                       cl-structure-object)))))
  (cl-assert (or type (not named)))
  (if (boundp children-sym)
      (add-to-list children-sym tag)
    (set children-sym (list tag)))
  (and (null type) (eq (caar slots) 'cl-tag-slot)
       ;; Hide the tag slot from "standard" (i.e. non-`type'd) structs.
       (setq slots (cdr slots)))
  (let* ((parent-class (if parent (cl--struct-get-class parent)
                         (cl--find-class (if (eq type 'list) 'cons
                                           (or type 'record)))))
         (n (length slots))
         (index-table (make-hash-table :test 'eq :size n))
         (vslots (let ((v (make-vector n nil))
                       (i 0)
                       (offset (if type 0 1)))
                   (dolist (slot slots)
                     (put (car slot) 'slot-name t)
                     (let* ((props (cl--plist-to-alist (cddr slot)))
                            (typep (assq :type props))
                            (type (if (null typep) t
                                    (setq props (delq typep props))
                                    (cdr typep))))
                       (aset v i (cl--make-slot-desc
                                  (car slot) (nth 1 slot)
                                  type props)))
                     (puthash (car slot) (+ i offset) index-table)
                     (cl-incf i))
                   v))
         (class (cl--struct-new-class
                 name docstring
                 (unless (symbolp parent-class) (list parent-class))
                 type named vslots index-table children-sym tag print)))
    (cl-assert (or (not (symbolp parent-class))
                   (memq name '(cl-structure-class cl-structure-object))))
    (when (cl--struct-class-p parent-class)
      (let ((pslots (cl--struct-class-slots parent-class)))
        (or (>= n (length pslots))
            (let ((ok t))
              (dotimes (i (length pslots))
                (unless (eq (cl--slot-descriptor-name (aref pslots i))
                            (cl--slot-descriptor-name (aref vslots i)))
                  (setq ok nil)))
              ok)
            (error "Included struct %S has changed since compilation of %S"
                   parent name))))
    (add-to-list 'current-load-list `(define-type . ,name))
    (cl--struct-register-child parent-class tag)
    (unless (or (eq named t) (eq tag name))
      ;; We used to use `defconst' instead of `set' but that
      ;; has a side-effect of purecopying during the dump, so that the
      ;; class object stored in the tag ends up being a *copy* of the
      ;; one stored in the `cl--class' property!  We could have fixed
      ;; this needless duplication by using the purecopied object, but
      ;; that then breaks down a bit later when we modify the
      ;; cl-structure-class class object to close the recursion
      ;; between cl-structure-object and cl-structure-class (because
      ;; modifying purecopied objects is not allowed.  Since this is
      ;; done during dumping, we could relax this rule and allow the
      ;; modification, but it's cumbersome).
      ;; So in the end, it's easier to just avoid the duplication by
      ;; avoiding the use of the purespace here.
      (set tag class)
      ;; In the cl-generic support, we need to be able to check
      ;; if a vector is a cl-struct object, without knowing its particular type.
      ;; So we use the (otherwise) unused function slots of the tag symbol
      ;; to put a special witness value, to make the check easy and reliable.
      (fset tag :quick-object-witness-check))
    (setf (cl--find-class name) class)))

(cl-defstruct (cl-structure-class
               (:conc-name cl--struct-class-)
               (:predicate cl--struct-class-p)
               (:constructor nil)
               (:constructor cl--struct-new-class
                (name docstring parents type named slots index-table
                      children-sym tag print))
               (:copier nil))
  "The type of CL structs descriptors."
  ;; The first few fields here are actually inherited from cl--class, but we
  ;; have to define this one before, to break the circularity, so we manually
  ;; list the fields here and later "backpatch" cl--class as the parent.
  ;; BEWARE: Obviously, it's indispensable to keep these two structs in sync!
  (name nil :type symbol)               ;The type name.
  (docstring nil :type string)
  (parents nil :type (list-of cl--class)) ;The included struct.
  (slots nil :type (vector cl-slot-descriptor))
  (index-table nil :type hash-table)
  (tag nil :type symbol) ;Placed in cl-tag-slot.  Holds the struct-class object.
  (type nil :type (memq (vector list)))
  (named nil :type bool)
  (print nil :type bool)
  (children-sym nil :type symbol) ;This sym's value holds the tags of children.
  )

(cl-defstruct (cl-structure-object
               (:predicate cl-struct-p)
               (:constructor nil)
               (:copier nil))
  "The root parent of all \"normal\" CL structs")

(setq cl--struct-default-parent 'cl-structure-object)

(cl-defstruct (cl-slot-descriptor
               (:conc-name cl--slot-descriptor-)
               (:constructor nil)
               (:constructor cl--make-slot-descriptor
                (name &optional initform type props))
               (:copier cl--copy-slot-descriptor-1))
  ;; FIXME: This is actually not used yet, for circularity reasons!
  "Descriptor of structure slot."
  name                                  ;Attribute name (symbol).
  initform
  type
  ;; Extra properties, kept in an alist, can include:
  ;;  :documentation, :protection, :custom, :label, :group, :printer.
  (props nil :type alist))

(defun cl--copy-slot-descriptor (slot)
  (let ((new (cl--copy-slot-descriptor-1 slot)))
    (cl-callf copy-alist (cl--slot-descriptor-props new))
    new))

(cl-defstruct (cl--class
               (:constructor nil)
               (:copier nil))
  "Abstract supertype of all type descriptors."
  ;; Intended to be shared between defstruct and defclass.
  (name nil :type symbol)               ;The type name.
  (docstring nil :type string)
  ;; For structs there can only be one parent, but when EIEIO classes inherit
  ;; from cl--class, we'll need this to hold a list.
  (parents nil :type (list-of cl--class))
  (slots nil :type (vector cl-slot-descriptor))
  (index-table nil :type hash-table))

(cl-assert
 (let ((sc-slots (cl--struct-class-slots (cl--find-class 'cl-structure-class)))
       (c-slots (cl--struct-class-slots (cl--find-class 'cl--class)))
       (eq t))
   (dotimes (i (length c-slots))
     (let ((sc-slot (aref sc-slots i))
           (c-slot (aref c-slots i)))
       (unless (eq (cl--slot-descriptor-name sc-slot)
                   (cl--slot-descriptor-name c-slot))
         (setq eq nil))))
   eq))

;; Close the recursion between cl-structure-object and cl-structure-class.
(setf (cl--struct-class-parents (cl--find-class 'cl-structure-class))
      (list (cl--find-class 'cl--class)))
(cl--struct-register-child
 (cl--find-class 'cl--class)
 (cl--struct-class-tag (cl--find-class 'cl-structure-class)))

(cl-assert (cl--find-class 'cl-structure-class))
(cl-assert (cl--find-class 'cl-structure-object))
(cl-assert (cl-struct-p (cl--find-class 'cl-structure-class)))
(cl-assert (cl-struct-p (cl--find-class 'cl-structure-object)))
(cl-assert (cl--class-p (cl--find-class 'cl-structure-class)))
(cl-assert (cl--class-p (cl--find-class 'cl-structure-object)))

(defun cl--class-allparents (class)
  (cons (cl--class-name class)
        (merge-ordered-lists (mapcar #'cl--class-allparents
                                     (cl--class-parents class)))))

(cl-defstruct (built-in-class
               (:include cl--class)
               (:constructor nil)
               (:constructor built-in-class--make (name docstring parents))
               (:copier nil))
  "Type descriptors for built-in types.
The `slots' (and hence `index-table') are currently unused."
  )

(defmacro cl--define-built-in-type (name parents &optional docstring &rest slots)
  ;; `slots' is currently unused, but we could make it take
  ;; a list of "slot like properties" together with the corresponding
  ;; accessor, and then we could maybe even make `slot-value' work
  ;; on some built-in types :-)
  (declare (indent 2) (doc-string 3))
  (unless (listp parents) (setq parents (list parents)))
  (unless (or parents (eq name t))
    (error "Missing parents for %S: %S" name parents))
  (let ((predicate (intern-soft (format
                                 (if (string-match "-" (symbol-name name))
                                     "%s-p" "%sp")
                                 name))))
    (unless (fboundp predicate) (setq predicate nil))
    (while (keywordp (car slots))
      (let ((kw (pop slots)) (val (pop slots)))
        (pcase kw
          (:predicate (setq predicate val))
          (_ (error "Unknown keyword arg: %S" kw)))))
    `(progn
       ,(if predicate `(put ',name 'cl-deftype-satisfies #',predicate)
          ;; (message "Missing predicate for: %S" name)
          nil)
       (put ',name 'cl--class
            (built-in-class--make ',name ,docstring
                                  (mapcar (lambda (type)
                                            (let ((class (get type 'cl--class)))
                                              (unless class
                                                (error "Unknown type: %S" type))
                                              class))
                                          ',parents))))))

;; FIXME: Our type DAG has various quirks:
;; - Some `keyword's are also `symbol-with-pos' but that's not reflected
;;   in the DAG.
;; - An OClosure can be an interpreted function or a `byte-code-function',
;;   so the DAG of OClosure types is "orthogonal" to the distinction
;;   between interpreted and compiled functions.

(cl--define-built-in-type t nil "Abstract supertype of everything.")
(cl--define-built-in-type atom t "Abstract supertype of anything but cons cells."
                          :predicate atom)

(cl--define-built-in-type tree-sitter-compiled-query atom)
(cl--define-built-in-type tree-sitter-node atom)
(cl--define-built-in-type tree-sitter-parser atom)
(declare-function user-ptrp "data.c")
(unless (fboundp 'user-ptrp)
  (cl--define-built-in-type user-ptr atom nil
                            :predicate user-ptrp)) ;; FIXME: Shouldn't it be called `user-ptr-p'?
(cl--define-built-in-type font-object atom)
(cl--define-built-in-type font-entity atom)
(cl--define-built-in-type font-spec atom)
(cl--define-built-in-type condvar atom)
(cl--define-built-in-type mutex atom)
(cl--define-built-in-type thread atom)
(cl--define-built-in-type terminal atom)
(cl--define-built-in-type hash-table atom)
(cl--define-built-in-type frame atom)
(cl--define-built-in-type buffer atom)
(cl--define-built-in-type window atom)
(cl--define-built-in-type process atom)
(cl--define-built-in-type finalizer atom)
(cl--define-built-in-type window-configuration atom)
(cl--define-built-in-type overlay atom)
(cl--define-built-in-type number-or-marker atom
  "Abstract supertype of both `number's and `marker's.")
(cl--define-built-in-type symbol atom
  "Type of symbols."
  ;; Example of slots we could document.  It would be desirable to
  ;; have some way to extract this from the C code, or somehow keep it
  ;; in sync (probably not for `cons' and `symbol' but for things like
  ;; `font-entity').
  (name     symbol-name)
  (value    symbol-value)
  (function symbol-function)
  (plist    symbol-plist))

(cl--define-built-in-type obarray atom)
(cl--define-built-in-type native-comp-unit atom)

(cl--define-built-in-type sequence t "Abstract supertype of sequences.")
(cl--define-built-in-type list sequence)
(cl--define-built-in-type array (sequence atom) "Abstract supertype of arrays.")
(cl--define-built-in-type number (number-or-marker)
  "Abstract supertype of numbers.")
(cl--define-built-in-type float (number))
(cl--define-built-in-type integer-or-marker (number-or-marker)
  "Abstract supertype of both `integer's and `marker's.")
(cl--define-built-in-type integer (number integer-or-marker))
(cl--define-built-in-type marker (integer-or-marker))
(cl--define-built-in-type bignum (integer)
  "Type of those integers too large to fit in a `fixnum'.")
(cl--define-built-in-type fixnum (integer)
  (format "Type of small (fixed-size) integers.
The size depends on the Emacs version and compilation options.
For this build of Emacs it's %dbit."
          (1+ (logb (1+ most-positive-fixnum)))))
(cl--define-built-in-type keyword (symbol)
  "Type of those symbols whose first char is `:'.")
(cl--define-built-in-type boolean (symbol)
  "Type of the canonical boolean values, i.e. either nil or t.")
(cl--define-built-in-type symbol-with-pos (symbol)
  "Type of symbols augmented with source-position information.")
(cl--define-built-in-type vector (array))
(cl--define-built-in-type record (atom)
  "Abstract type of objects with slots.")
(cl--define-built-in-type bool-vector (array) "Type of bitvectors.")
(cl--define-built-in-type char-table (array)
  "Type of special arrays that are indexed by characters.")
(cl--define-built-in-type string (array))
(cl--define-built-in-type null (boolean list) ;FIXME: `atom' comes before `list'?
  "Type of the nil value."
  :predicate null)
(cl--define-built-in-type cons (list)
  "Type of cons cells."
  ;; Example of slots we could document.
  (car car) (cdr cdr))
(cl--define-built-in-type function (atom)
  "Abstract supertype of function values.")
(cl--define-built-in-type compiled-function (function)
  "Abstract type of functions that have been compiled.")
(cl--define-built-in-type byte-code-function (compiled-function)
  "Type of functions that have been byte-compiled.")
(cl--define-built-in-type subr (atom)
  "Abstract type of functions compiled to machine code.")
(cl--define-built-in-type module-function (function)
  "Type of functions provided via the module API.")
(cl--define-built-in-type interpreted-function (function)
  "Type of functions that have not been compiled.")
(cl--define-built-in-type special-form (subr)
  "Type of the core syntactic elements of the Emacs Lisp language.")
(cl--define-built-in-type subr-native-elisp (subr compiled-function)
  "Type of functions that have been compiled by the native compiler.")
(cl--define-built-in-type primitive-function (subr compiled-function)
  "Type of functions hand written in C.")

(unless (cl--class-parents (cl--find-class 'cl-structure-object))
  ;; When `cl-structure-object' is created, built-in classes didn't exist
  ;; yet, so we couldn't put `record' as the parent.
  ;; Fix it now to close the recursion.
  (setf (cl--class-parents (cl--find-class 'cl-structure-object))
      (list (cl--find-class 'record))))

;; Make sure functions defined with cl-defsubst can be inlined even in
;; packages which do not require CL.  We don't put an autoload cookie
;; directly on that function, since those cookies only go to cl-loaddefs.
(autoload 'cl--defsubst-expand "cl-macs")
;; Autoload, so autoload.el and font-lock can use it even when CL
;; is not loaded.
(put 'cl-defun    'doc-string-elt 3)
(put 'cl-defmacro 'doc-string-elt 3)
(put 'cl-defsubst 'doc-string-elt 3)
(put 'cl-defstruct 'doc-string-elt 2)

(provide 'cl-preloaded)
;;; cl-preloaded.el ends here
