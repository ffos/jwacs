;;;; pretty-print.lisp
;;;
;;; Provides generic functions for printing abstract source trees in a parseable (and
;;; human-readable) fashion.  The PRETTY-PRINT generic function is the main interface.
;;; Unit tests are in tests/test-pretty-print.lisp.

(in-package :jwacs)

;;;; Rules for semicolon-termination
;;;
;;; === The ideal situation ===
;;;
;;; There are two basic rules:
;;; 1. Calling `pretty-print` on a statement should always result in a semicolon-terminated statement
;;; 2. Calling `pretty-print` on any other source element (e.g., an expression) should /not/ result in
;;;    a semicolon-terminated line.
;;;
;;; This is (hopefully) an attainable ideal, but it will require us to change our parsing a little in order
;;; to be able to distinguish between (for example) expressions and expression statements.  (We'll
;;; probably just create an expression-statement source element that contains a single expression.)
;;;
;;; I'm a little concerned that we may not be able to create all of the disambiguating source-element
;;; types because the parser itself may not be able to tell all of the cases apart.  I've omitted a few
;;; disambiguating rules from the parser that are in the standard grammar (things like "no newlines allowed
;;; between `return` and its argument"), because they are not expressible in a Lispworks's parser-generator
;;; grammar.  These omissions may have led to some extra ambiguity; certainly there is an awful lot of
;;; complaining when Lispworks is compiling the grammar.
;;;
;;; === The actual situation ===
;;;
;;; For now, we assume that neither statements nor any other source element self-semicolon-terminates.
;;; The pretty-printer for blocks (and lists of statement) will just slap a semicolon after each
;;; statement minus some exceptions (if, while, for, function declarations, etc.).

;;;; Indentation helpers
(defparameter *indent-step* 2
  "Number of spaces per indentation step")

(defvar *indent* 0
  "Current indentation level, in spaces (not steps)")

(defun fresh-line-indented (s)
  "Start a new, indented line."
  (fresh-line s)
  (dotimes (n *indent*)
    (format s " ")))

(defmacro with-indent (&body body)
  "Execute the contained forms with *indent* set one step deeper."
  `(let ((*indent* (+ *indent* *indent-step*)))
    ,@body))

;; When we print subordinate statements (as for a while or for loop), we want to indent
;; single statements, but not blocks (because blocks will do the indentation for us).
;; In those situations, use pretty-print-subordinate instead of pretty-print; it will
;; indent correctly depending upon the type of source-element that it receives.
;; TODO The semicolon keyword will disappear once we are dealing correctly with semicolon termination
(defgeneric pretty-print-subordinate (elm stream &key semicolon)
  (:documentation
   "pretty-print source element ELM to stream STREAM as a 'subordinate statement'.
    This has differing indentation implications depending upon whether or not ELM is a BLOCK."))

(defmethod pretty-print-subordinate ((elm statement-block) s &key semicolon)
  (declare (ignore semicolon))
  (pretty-print elm s))

(defmethod pretty-print-subordinate (elm s &key semicolon)
  (with-indent
    (fresh-line-indented s)
    (pretty-print elm s)
    (if semicolon
      (format s ";"))))

;;;; General helpers
(defun pretty-print-separated-list (elm-list s &optional (sep-string ", "))
  "Pretty print the elements of ELM-LIST to S separated by SEP-STRING."
  (loop
      for idx upfrom 0
      for elm in elm-list
      do
      (unless (zerop idx)
        (format s sep-string))
      (pretty-print elm s)))

;;;; The pretty-print generic function

(defgeneric pretty-print (elm stream)
  (:documentation
   "Print source element ELM to stream STREAM as parseable and human-readable text."))

(defmethod pretty-print ((elm special-value) s)
  (if (find (special-value-symbol elm) *keyword-symbols*)
    (format s "~A" (string-downcase (special-value-symbol elm)))
    (error "Unknown special value symbol ~S" (special-value-symbol elm))))
   
(defmethod pretty-print ((elm identifier) s)
  (format s "~A" (identifier-name elm)))

(defmethod pretty-print ((elm numeric-literal) s)
  (format s "~D" (numeric-literal-value elm)))

(defmethod pretty-print ((elm string-literal) s)
  (format s "~S" (string-literal-value elm)))

(defmethod pretty-print ((elm array-literal) s)
  (format s "[")
  (pretty-print-separated-list (array-literal-elements elm) s)
  (format s "]"))

(defmethod pretty-print ((elm re-literal) s)
  (format s "/~A/~A" (re-literal-pattern elm) (re-literal-options elm)))

;; TODO May want some extra smarts here for things like class defns
;; ie, add newlines after each property if any of the properties are of type function-expression
(defmethod pretty-print ((elm object-literal) s)
  (format s "{")
  (loop for idx upfrom 0
        for name/value in (object-literal-properties elm)
        do
        (unless (zerop idx)
          (format s ", "))
        (pretty-print (car name/value) s)
        (format s ": ")
        (pretty-print (cdr name/value) s))
  (format s "}"))

(defmethod pretty-print ((elm new-expr) s)
  (cond
    ((null (new-expr-args elm))
     (format s "new ~A" (new-expr-object-name elm)))
    (t
     (format s "new ~A (" (new-expr-object-name elm))
     (pretty-print-separated-list (new-expr-args elm) s))))

(defmethod pretty-print ((elm fn-call) s)
  (pretty-print (fn-call-fn elm) s)
  (format s "(")
  (pretty-print-separated-list (fn-call-args elm) s)
  (format s ")"))

(defun printable-as-dot (string-literal-elm)
  "Return true if STRING-LITERAL-ELM is a valid identifier, and therefore can be used
   in dotted form for accessing properties in Javascript.
   Eg: (printable-as-dot #S(string-literal :value \"value\")) ==> T
       (printable-as-dot #s(string-literal :value \"has spaces\")) ==> NIL
       (printable-as-dot #s(string-literal :value \"has/punctuation\")) ==> NIL"
  (not (null (scan "^\\w+$" (string-literal-value string-literal-elm)))))

(defmethod pretty-print ((elm property-access) s)
  (pretty-print (property-access-target elm) s)
  (cond
    ((printable-as-dot (property-access-field elm))
     (format s ".~A" (string-literal-value (property-access-field elm))))
    (t
     (format s "[")
     (pretty-print (property-access-field elm) s)
     (format s "]"))))

; TODO precedence handling
(defmethod pretty-print ((elm unary-operator) s)
  (let* ((op-symbol (unary-operator-op-symbol elm))
         (op-string (or (gethash op-symbol *symbols-to-tokens*)
                        (if (find op-symbol *keyword-symbols*)
                          (string-downcase (symbol-name op-symbol))))))
  (ecase op-symbol
    ((:post-decr :post-incr)
     (pretty-print (unary-operator-arg elm) s)
     (format s "~A" op-string))
    ((:pre-decr :pre-incr :unary-minus :unary-plus :bitwise-not :logical-not)
     (format s "~A" op-string)
     (pretty-print (unary-operator-arg elm) s))
    ((:delete :void :typeof)
     (format s "~A " op-string)
     (pretty-print (unary-operator-arg elm) s)))))

(defmethod pretty-print ((elm binary-operator) s)
  (let* ((op-symbol (binary-operator-op-symbol elm))
         (op-string (or (gethash op-symbol *symbols-to-tokens*)
                        (if (find op-symbol *keyword-symbols*)
                          (string-downcase (symbol-name op-symbol))))))
    (pretty-print (binary-operator-left-arg elm) s)
    (format s " ~A " op-string)
    (pretty-print (binary-operator-right-arg elm) s)))

(defmethod pretty-print ((elm conditional) s)
  (format s "(")
  (pretty-print (conditional-condition elm) s)
  (format s ") ? (")
  (pretty-print (conditional-true-arg elm) s)
  (format s ") : (")
  (pretty-print (conditional-false-arg elm) s)
  (format s ")"))

(defmethod pretty-print ((elm comma-expr) s)
  (pretty-print-separated-list (comma-expr-exprs elm) s))

(defmethod pretty-print ((elm var-decl-statement) s)
  (format s "var ")
  (pretty-print-separated-list (var-decl-statement-var-decls elm) s))

(defmethod pretty-print ((elm var-decl) s)
  (format s (var-decl-name elm))
  (when (var-decl-initializer elm)
    (format s " = ")
    (pretty-print (var-decl-initializer elm) s)))

;; Pretty-print a list of source elements
(defmethod pretty-print ((elm list) s)
  (loop for statement in elm
        do
        (fresh-line-indented s)
        (pretty-print statement s)
        (format s ";")))
  
(defmethod pretty-print ((elm statement-block) s)
  (fresh-line-indented s)
  (format s "{")
  (with-indent
    (pretty-print (statement-block-statements elm) s))
  (fresh-line-indented s)
  (format s "}"))

(defmethod pretty-print ((elm if-statement) s)
  (format s "if(")
  (pretty-print (if-statement-condition elm) s)
  (format s ")")
  (pretty-print-subordinate (if-statement-then-statement elm) s)
  (when (if-statement-else-statement elm)
    (unless (statement-block-p (if-statement-then-statement elm))
      (format s ";"))
    (fresh-line-indented s)
    (format s "else")
    (pretty-print-subordinate (if-statement-else-statement elm) s)))

(defmethod pretty-print ((elm do-statement) s)
  (format s "do")
  (pretty-print-subordinate (do-statement-body elm) s :semicolon t)
  (fresh-line-indented s)
  (format s "while(")
  (pretty-print (do-statement-condition elm) s)
  (format s ")"))

(defmethod pretty-print ((elm while) s)
  (format s "while(")
  (pretty-print (while-condition elm) s)
  (format s ")")
  (pretty-print-subordinate (while-body elm) s))

(defmethod pretty-print ((elm null) s)
  (declare (ignore elm s)))

(defmethod pretty-print ((elm string) s)
  (format s "~A" elm))

(defmethod pretty-print ((elm for) s)
  (format s "for(")
  (pretty-print (for-initializer elm) s)
  (format s "; ")
  (pretty-print (for-condition elm) s)
  (format s "; ")
  (pretty-print (for-step elm) s)
  (format s ")")
  (pretty-print-subordinate (for-body elm) s))

(defmethod pretty-print ((elm for-in) s)
  (format s "for(")
  (pretty-print (for-in-binding elm) s)
  (format s " in ")
  (pretty-print (for-in-collection elm) s)
  (format s ")")
  (pretty-print-subordinate (for-in-body elm) s))

;; TODO Consolidate break/return/continue/throw into a single struct type?
(defmethod pretty-print ((elm continue-statement) s)
  (format s "continue")
  (when (continue-statement-label elm)
    (format s " ")
    (pretty-print (continue-statement-label elm) s)))

(defmethod pretty-print ((elm break-statement) s)
  (format s "break")
  (when (break-statement-label elm)
    (format s " ")
    (pretty-print (break-statement-label elm) s)))

(defmethod pretty-print ((elm return-statement) s)
  (format s "return")
  (when (return-statement-arg elm)
    (format s " ")
    (pretty-print (return-statement-arg elm) s)))

(defmethod pretty-print ((elm throw-statement) s)
  (format s "throw ")
  (pretty-print (throw-statement-value elm) s))

(defmethod pretty-print ((elm switch) s)
  (format s "switch(")
  (pretty-print (switch-value elm) s)
  (format s ")")
  (fresh-line-indented s)
  (format s "{")
  (loop for clause in (switch-clauses elm)
        do (pretty-print clause s))
  (fresh-line-indented s)
  (format s "}"))

(defmethod pretty-print ((elm case-clause) s)
  (fresh-line-indented s)
  (format s "case ")
  (pretty-print (case-clause-label elm) s)
  (format s ":")
  (with-indent
    (pretty-print (case-clause-body elm) s)))

(defmethod pretty-print ((elm default-clause) s)
  (fresh-line-indented s)
  (format s "default:")
  (with-indent
    (pretty-print (default-clause-body elm) s)))

(defmethod pretty-print ((elm with) s)
  (format s "with(")
  (pretty-print (with-scope-object elm) s)
  (format s ")")
  (pretty-print-subordinate (with-body elm) s))

(defmethod pretty-print ((elm label) s)
  (format s "~A:" (label-name elm))
  (fresh-line-indented s)
  (pretty-print (label-statement elm) s))

(defmethod pretty-print ((elm try) s)
  (format s "try")
  (pretty-print (try-body elm) s)
  (when (try-catch-clause elm)
    (fresh-line-indented s)
    (pretty-print (try-catch-clause elm) s))
  (when (try-finally-clause elm)
    (fresh-line-indented s)
    (pretty-print (try-finally-clause elm) s)))

(defmethod pretty-print ((elm catch-clause) s)
  (format s "catch(~A)" (catch-clause-binding elm))
  (pretty-print (catch-clause-body elm) s))

(defmethod pretty-print ((elm finally-clause) s)
  (format s "finally")
  (pretty-print (finally-clause-body elm) s))

(defmethod pretty-print ((elm function-decl) s)
  (fresh-line-indented s)
  (format s "function ~A(" (function-decl-name elm))
  (pretty-print-separated-list (function-decl-parameters elm) s)
  (format s ")")
  (fresh-line-indented s)
  (format s "{")
  (with-indent
    (pretty-print (function-decl-body elm) s))
  (fresh-line-indented s)
  (format s "}"))

(defmethod pretty-print ((elm function-expression) s)
  (if (function-expression-name elm)
    (format s "function ~A(" (function-expression-name elm))
    (format s "function("))
  (pretty-print-separated-list (function-expression-parameters elm) s)
  (format s ")")

  (cond
    ;; If there's only one statement in the body, try to fit everything onto one line
    ((<= (length (function-expression-body elm)) 1)
     (format s " { ")
     (pretty-print (first (function-expression-body elm)) s)
     (format s "; }"))
    (t
     (fresh-line-indented s)
     (format s "{")
     (with-indent
       (pretty-print (function-expression-body elm) s))
     (fresh-line-indented s)
     (format s "}"))))
