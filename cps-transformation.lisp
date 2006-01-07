;;;; cps-transformation.lisp
;;;
;;; Define the cps transformation and supporting functionality.
(in-package :jwacs)

;;;; CPS transformation
;;; Initial, naive version does the following:
;;; - All function calls transformed to fn-calls in continuation-passing style
;;; - All assignments transformed to new continuations
;;; - All returns transformed to returns of the arg passed to the current continuation
;;;
;;;; Preconditions
;;; The CPS transform assumes the following:
;;; 1. Scope analysis transformation has been performed (and therefore all identifiers are unique)
;;; 2. Explicitization transformation has been performed (and therefore all result values are unique)

;; These elements should have been removed by LOOP-TO-FUNCTION
(forbid-transformation-elements cps (while do-statement for for-in))

(defun assignment-operator-p (elm)
  "Returns non-NIL if ELM represents an operation with an assignment side-effect"
  (and
   (binary-operator-p elm)
   (member (binary-operator-op-symbol elm)
           '(:assign :plus-equals :minus-equals :times-equals :divide-equals
             :lshift-equals :rshift-equals :urshift-equals
             :and-equals :or-equals :xor-equals))))

(defparameter *cont-name* "$k"
  "The name of the standard continuation parameter.  See SBCL-DEFPARAMETER-NOTE")

(defparameter *cont-id* (make-identifier :name *cont-name*)
  "An identifier whose name is *cont-name*.  See SBCL-DEFPARAMETER-NOTE")

(defparameter *id-name* "$id"
  "The name of the standard identity function")

;;;; Runtime parameters 
;;; When we refer to runtime functions, we indirect through parameters to make it easy to
;;; factor the runtime (and also to save having to contantly type (MAKE-STRING-LITERAL ...))

(defparameter *call-style-prop* (make-string-literal :value "$callStyle")
  "The name of the callStyle property")

(defparameter *cps-call-style* (make-string-literal :value "cps")
  "The value of the `*call-style-prop*` property for CPS functions")

(defparameter *call-fn* (make-identifier :name "$call")
  "Identifier of the $call function in the runtime")

(defparameter *cps-lambda-fn* (make-identifier :name "$cpsLambda")
  "Runtime function that accepts a function-expression and returns the same function with
   the $callStyle property set to 'cps'.")

;;;; Scope tracking 

(defparameter *function-decls-in-scope* nil
  "A list of names of currently-visible function-decls.  We can use this to
   determine which calls need to be indirected through $call, and which can
   be 'inlined' as unchecked CPS calls.")

(defparameter *in-local-scope* nil
  "T when the lexical scope is currently inside a function decl, NIL when the
   lexical scope is currently the global scope")

(defmacro in-local-scope (&body body)
  "Execute BODY with *IN-LOCAL-SCOPE* bound to T"
  `(let ((*in-local-scope* t))
    ,@body))

(defun function-in-scope-p (name)
  "Return non-NIL if a function-decl with name NAME is currently visible in scope"
  (member name *function-decls-in-scope* :test 'equal))

;;;; Statement tails 
;;;
;;; A "statement tail" is a list of the statements that follow the current
;;; statement in the current scope.  Note that this can include statements
;;; from an enclosing scope as well.  For example, in the following code:
;;;
;;;     function foo(opt)
;;;     {
;;;       if(opt)
;;;       {
;;;         foo(x);
;;;         bar(x);
;;;         baz(opt);
;;;       }
;;;       else
;;;       {
;;;         bar(0);
;;;       } 
;;;
;;;       quux();
;;;       quuux();
;;;     }
;;;
;;;     doThis();
;;;     doThat();
;;;
;;; the statement-tail of the `foo(x)` call is (`bar(x)`, `baz(opt)`, `quux()`, `quuux()`).
;;; Note that `quux()` and `quuux()` are in the statement-tail, but `dothis()` and `dothat()`
;;; are not.  The statement-tail will never extend past the end of the innermost enclosing
;;; function declaration.
;;;
;;; Basically, the statement-tail contains all of the statements that should go into a continuation,
;;; should we need to generate a continuation at this point.
;;;
;;;; Statement tail protocol 
;;;
;;; The `*statement-tail*` special variable holds the current state of the statement-tail.
;;; The macro `with-statement-tail` adds new statements to the current statement-tail (eg,
;;; when entering a new block scope) by prepending them to the current tail.
;;;
;;; The macro `consume-statement-tail` grabs the current statement-tail and sets it to null
;;; to indicate that it has been "used up", and therefore the statements in the tail needn't
;;; be processed, because they will have already been processed as part of generating a
;;; continuation at an innermore scope.
;;;
;;; When we're processing return statements, we don't want to include the current tail in
;;; any function calls that might be part of the return value.  The `without-statement-tail`
;;; macro will suppress the current statement tail (by temporarily binding it to null).

(defparameter *statement-tail* nil
  "Statements following the current statement in the current scope.")

(defmacro with-statement-tail ((new-statements) &body body)
  "Execute BODY with NEW-STATEMENTS prepended to the current statement-tail"
  `(let ((*statement-tail* (append ,new-statements *statement-tail*)))
    ,@body))

(defmacro consume-statement-tail ((tail-symbol) &body body)
  "Set the current statement tail to NIL (signalling that it has been consumed), and
   the execute BODY with TAIL-SYMBOL bound to the original value of *statement-tail*."
  `(let ((,tail-symbol *statement-tail*))
    (setf *statement-tail* nil)
    ,@body))

(defmacro without-statement-tail (&body body)
  "Execute BODY with *STATEMENT-TAIL* bound to NIL"
  `(let ((*statement-tail* nil))
    ,@body))

;;;; Explicit-return-p generic function

(defgeneric explicit-return-p (elm)
  (:documentation "Returns non-NIL if ELM explicitly returns (or throws) via all control paths"))

;;; Unless otherwise specified, a source element does not explicitly return
(defmethod explicit-return-p (elm)
  nil)

;;; Base cases
(defmethod explicit-return-p ((elm return-statement))
  t)

(defmethod explicit-return-p ((elm throw-statement))
  t)

;;; Sequences
(defmethod explicit-return-p ((elm-list list))
  (unless (null elm-list)
    (or (explicit-return-p (car elm-list))
        (explicit-return-p (cdr elm-list)))))

;;; Branches
(defmethod explicit-return-p ((elm if-statement))
  (and (explicit-return-p (if-statement-then-statement elm))
       (explicit-return-p (if-statement-else-statement elm))))

(defmethod explicit-return-p ((elm switch))
  (reduce (lambda (x y)
            (and x y))
          (switch-clauses elm)
          :key 'explicit-return-p))

(defmethod explicit-return-p ((elm try))
  (with-slots (body catch-clause finally-clause) elm
    (or (explicit-return-p finally-clause)
        (if (null catch-clause)
          (explicit-return-p body)
          (and (explicit-return-p body)
               (explicit-return-p catch-clause))))))
      
;;; Simple recursion
(defmethod explicit-return-p ((elm statement-block))
  (explicit-return-p (statement-block-statements elm)))

(defmethod explicit-return-p ((elm case-clause))
  (explicit-return-p (case-clause-body elm)))

(defmethod explicit-return-p ((elm default-clause))
  (explicit-return-p (default-clause-body elm)))

(defmethod explicit-return-p ((elm do-statement))
  (explicit-return-p (do-statement-body elm)))

(defmethod explicit-return-p ((elm while))
  (explicit-return-p (while-body elm)))

(defmethod explicit-return-p ((elm for))
  (explicit-return-p (for-body elm)))

(defmethod explicit-return-p ((elm for-in))
  (explicit-return-p (for-in-body elm)))

(defmethod explicit-return-p ((elm with))
  (explicit-return-p (with-body elm)))

(defmethod explicit-return-p ((elm label))
  (explicit-return-p (label-statement elm)))

(defmethod explicit-return-p ((elm catch-clause))
  (explicit-return-p (catch-clause-body elm)))

(defmethod explicit-return-p ((elm finally-clause))
  (explicit-return-p (finally-clause-body elm)))

;;;; CPS transform methods 

(defmethod transform ((xform (eql 'cps)) (elm function-decl))
  ;; The body has an empty return statement appended if not every control path
  ;; has an explicit return.
  (let ((body (if (explicit-return-p (function-decl-body elm))
                (function-decl-body elm)
                (append (function-decl-body elm) (list #s(return-statement))))))
    (without-statement-tail             ; Each function starts with a fresh statement-tail
      (list
       (make-function-decl :name (function-decl-name elm)
                           :parameters (cons *cont-name* (function-decl-parameters elm))
                           :body (in-local-scope
                                   (transform 'cps body)))
       (make-binary-operator :op-symbol :assign
                             :left-arg (make-property-access :field *call-style-prop*
                                                             :target (make-identifier :name (function-decl-name elm)))
                             :right-arg *cps-call-style*)))))

(defun make-call-style-guard (fn-name parameters)
  "Builds an if statement that checks whether the incoming continuation argument is a function value;
   if it isn't, then (on the assumption that a direct-style call has been mistakenly made) re-calls
   this function (whose name is FN-NAME) with a default continuation parameter (`$id`) followed by
   the original incoming parameters."
  (make-if-statement
   :condition
   (make-binary-operator :op-symbol :not-equals
                         :left-arg (make-unary-operator :op-symbol :typeof
                                                        :arg *cont-id*)
                         :right-arg (make-string-literal :value "function"))
   :then-statement
   (make-return-statement :arg (make-fn-call :fn (make-identifier :name fn-name)
                                             :args (mapcar (lambda (p) (make-identifier :name p))
                                                           (cons *id-name* parameters))))))

(defmethod transform ((xform (eql 'cps)) (elm function-expression))
  ;; 1. Every function expression that is cps-transformed is given a name, to ensure
  ;;    that we can add the "guard" expression for callers from the outside.
  ;; 2. The body has an empty return statement appended if not every control path
  ;;    has an explicit return.
  (let ((fn-name (if (function-expression-name elm)
                                      (function-expression-name elm)
                                      (genvar)))
        (new-parameters (cons *cont-name* (function-expression-parameters elm)))
        (body (if (explicit-return-p (function-expression-body elm))
                (function-expression-body elm)
                (append (function-expression-body elm) (list #s(return-statement))))))
    (without-statement-tail             ; Each function starts with a fresh statement-tail
      (make-fn-call :fn *cps-lambda-fn*
                    :args (list
                           (make-function-expression :name fn-name
                                                     :parameters new-parameters
                                                     :body (in-local-scope
                                                             (cons
                                                              (make-call-style-guard fn-name new-parameters)
                                                              (transform 'cps body)))))))))


(defun inlineable-cps-call-p (elm)
  "Return non-NIL if it is definitely safe for ELM to be used as the target
   of an inline cps call"
  (and (identifier-p elm)
       (function-in-scope-p (identifier-name elm))))

(defmethod transform ((xform (eql 'cps)) (elm return-statement))
  (with-slots (arg) elm
    (let ((new-fn-call
           (cond
             ;; Inlined tail call (pass continuation to function)
             ((and (fn-call-p arg)
                   (inlineable-cps-call-p (fn-call-fn arg)))
              (without-statement-tail
                (make-fn-call :fn (fn-call-fn arg)
                              :args (cons *cont-id*
                                          (mapcar (lambda (item)
                                                    (transform 'cps item))
                                                  (fn-call-args arg))))))

             ;; Indirected tail call (pass continuation to $call)
             ((fn-call-p arg)
              (without-statement-tail
                (make-fn-call :fn *call-fn*
                              :args (list (fn-call-fn arg)
                                          *cont-id*
                                          (make-special-value :symbol :this)
                                          (make-array-literal :elements
                                                              (mapcar (lambda (item)
                                                                        (transform 'cps item))
                                                                      (fn-call-args arg)))))))

             ;; Simple return (call continuation directly)
              (t
               (without-statement-tail
                 (make-fn-call :fn *cont-id*
                               :args (unless (null (return-statement-arg elm))
                                       (list (transform 'cps (return-statement-arg elm))))))))))

      (make-return-statement :arg new-fn-call))))

(defun make-void-continuation (current-cont)
  "Returns a function expression that accepts an argument (which it ignores),
   and then calls CURRENT-CONT with no arguments.  This allows us to preserve
   the behaviour of functions that return no value."
  (make-function-expression
   :parameters (list (genvar "dummy"))
   :body (list (make-return-statement :arg
                                      (make-fn-call :fn current-cont
                                                    :args nil)))))

;;; This method only handles function calls where the return value is ignored.
;;;
;;; Function calls that are the initializers for variable declarations are handled
;;; in (METHOD TRANSFORM ((EQL 'CPS) VAR-DECL-STATEMENT)).  Function calls that are
;;; assigned to existing variables or used as intermediate values in calculations are
;;; transformed to variable-decl initializers in the EXPLICITIZE transformation.
;;; Tail calls (ie, those that are the argument to a return statement) are handled
;;; in (METHOD TRANSFORM ((EQL 'CPS) RETURN-STATEMENT)).
(defmethod transform ((xform (eql 'cps)) (elm fn-call))
  (let ((new-fn-call
         (cond
           ;; "Inlined" tailless call
           ((and (null *statement-tail*)
                 (inlineable-cps-call-p (fn-call-fn elm)))
            (make-fn-call
             :fn (fn-call-fn elm)
             :args (cons (make-void-continuation *cont-id*)
                         (mapcar (lambda (item)
                                   (transform 'cps item))
                                 (fn-call-args elm)))))

           ;; "Inlined" call w/statement-tail
           ((and (identifier-p (fn-call-fn elm))
                 (inlineable-cps-call-p (fn-call-fn elm)))
            (make-fn-call
             :fn (fn-call-fn elm)
             :args (consume-statement-tail (statement-tail)
                     (cons (make-function-expression :parameters (list (genvar "dummy"))
                                                     :body (transform 'cps statement-tail))
                           (mapcar (lambda (item)
                                     (transform 'cps item))
                                   (fn-call-args elm))))))

           ;; Indirected tailless call
           ((null *statement-tail*)
            (make-fn-call :fn *call-fn*
                          :args (list (fn-call-fn elm)
                                      (make-void-continuation *cont-id*)
                                      (make-special-value :symbol :this)
                                      (make-array-literal :elements (fn-call-args elm)))))

           ;; Indirected call w/statement-tail
           (t
            (make-fn-call :fn *call-fn*
                          :args
                          (consume-statement-tail (statement-tail)
                            (list (fn-call-fn elm)
                                  (make-function-expression :parameters (list (genvar "dummy"))
                                                            :body (transform 'cps statement-tail))
                                  (make-special-value :symbol :this)
                                  (make-array-literal :elements (fn-call-args elm)))))))))
    (if *in-local-scope*
      (make-return-statement :arg new-fn-call)
      new-fn-call)))
            
(defmethod transform :around ((xform (eql 'cps)) (elm-list list))
  (let ((*function-decls-in-scope* (append (mapcar 'function-decl-name
                                                   (collect-in-scope elm-list 'function-decl))
                                           *function-decls-in-scope*)))
    (call-next-method)))
  
(defmethod transform ((xform (eql 'cps)) (elm-list list))
  (unless (null elm-list)
    (let ((statements-consumed nil)
          (head nil))

      ;; Transform the first source element with the rest prepended to the statement tail.
      ;; We keep track of whether this new statement-tail gets consumed (by being set to NIL)
      ;; in a separate flag, because we need to propogate this consumedness (by setting our
      ;; original statement-tail to NIL) /after/ the new statement tail is no longer bound.
      (with-statement-tail ((cdr elm-list))
        (setf head (transform 'cps (car elm-list)))
        (when (null *statement-tail*)
          (setf statements-consumed t)))
      
      ;; Guarantee that HEAD is a list
      (unless (listp head)
        (setf head (list head)))

      ;; If the new statement tail was consumed, then it will be incorporated into the
      ;; transformed version of HEAD, so we shouldn't recurse.
      (if statements-consumed
        (progn
          (setf *statement-tail* nil)
          head)
        (append head (transform 'cps (cdr elm-list)))))))

(defmethod transform ((xform (eql 'cps)) (elm var-decl-statement))
  ;; Assuming one decl per statment because that is one of the results of explicitization
  (with-slots (var-decls) elm
    (assert (<= (length var-decls) 1))
    (let ((name (var-decl-name (car var-decls)))
          (initializer (var-decl-initializer (car var-decls))))
      (cond
        ((fn-call-p initializer)
         (consume-statement-tail (statement-tail)
           (let ((new-call  (make-fn-call :fn (fn-call-fn initializer)
                                          :args (cons
                                                 (make-function-expression :parameters (list name)
                                                                           :body (transform 'cps statement-tail))
                                                 (fn-call-args initializer)))))
             (make-return-statement :arg new-call))))
        (t
         (make-var-decl-statement :var-decls
                                  (mapcar (lambda (item) (transform 'cps item))
                                          var-decls)))))))
  
(defmethod transform ((xform (eql 'cps)) (elm if-statement))
  (let ((saved-statement-tail *statement-tail*)
        condition
        then-statement post-then-tail
        else-statement)
    
    ;; TODO There must be a nicer way to do this.  Think about refactoring
    ;; after we've done switch statements.
    ;; Specifically, the statement-tail that follows the if statement should
    ;; be assigned to a named continuation function expression and referenced
    ;; that way rather than just being slurped into the continuations for both
    ;; branches of the if.  This isn't lambda-calculus; we don't have to put up
    ;; with exponentially-expanding programs to get a usable CPS form.
    (setf condition (transform 'cps (if-statement-condition elm)))

    (setf *statement-tail* saved-statement-tail)
    (setf then-statement (transform 'cps (if-statement-then-statement elm)))
    (setf post-then-tail *statement-tail*)

    (setf *statement-tail* saved-statement-tail)
    (setf else-statement (transform 'cps (if-statement-else-statement elm)))

    (setf *statement-tail* (or post-then-tail *statement-tail*))
    (make-if-statement :condition condition
                       :then-statement then-statement
                       :else-statement else-statement)))

;;; The CPS transformation is where we convert `suspend` and `resume` statements
;;; into standard Javascript (because `suspend` needs to capture statement-tails).
;;TODO We no longer capture statement-tails for `suspend`, but CPS transform is still
;; the right place to do the transformation, so that `suspend` can be guaranteed to turn
;; into a `return` that doesn't tail-call the current continuation.
(defmethod transform ((xform (eql 'cps)) (elm suspend-statement))
  (consume-statement-tail (statement-tail)
    (let* ((k-name (genvar))
           (k-id (make-identifier :name k-name))
           (k-expr (make-function-expression :body (transform 'cps statement-tail))))
      (make-statement-block
       :statements (list
                    (make-var-decl-statement :var-decls
                                             (list (make-var-decl :name k-name
                                                                  :initializer k-expr)))
                    (make-binary-operator :op-symbol :assign
                                          :left-arg (suspend-statement-arg elm)
                                          :right-arg k-id)
                    (make-fn-call :fn k-id))))))

(defmethod transform ((xform (eql 'cps)) (elm resume-statement))
  (make-return-statement :arg (make-fn-call :fn (transform 'cps (resume-statement-arg elm)))))
