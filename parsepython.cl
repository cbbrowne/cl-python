;;; Parsing Python

(in-package :python)

(declaim (optimize (debug 3)))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :yacc)
  (use-package :yacc))

(defvar *reserved-words*
    ;; A few of these are not actually reserved words in CPython yet,
    ;; because of backward compatilibity reasons, but they will be in
    ;; the future (`as' is an example).
    '(def class return yield lambda
      and or not for in is
      print import from as assert break continue global del exec pass
      try except finally raise
      if elif else while clpy))

(defgrammar python-grammar (grammar)
  ()
  (:left-associative or)
  (:left-associative and)
  (:left-associative not)
  (:left-associative in) ;; and "not in"
  (:left-associative is) ;; and "is not"
  (:left-associative < <= > >= <> != ==)
  (:left-associative |\|| )
  (:left-associative ^)
  (:left-associative &)
  (:left-associative << >> )
  (:left-associative + -)
  (:left-associative * / % //)
  (:left-associative unary-plusmin)
  (:left-associative ~)
  (:right-associative **)
  (:non-associative high-prec)
  (:lexemes identifier number string newline indent dedent
	    ;; punctuation:
	    = [ ] |(| |)| < > { } |.| |,| |:| |\|| ^ % + - * / ~ & |`|
            &= // << >>  <> != += -= *= /= //= %= ** <= >= ^= |\|=| ==
	    **= <<= >>= |...|
	    |;|   ;; multiple statements same line
	    @     ;; decorator
	    ;; keywords:
	    def class return yield lambda
	    and or not for in is
	    print import from as assert break continue global del exec pass
	    try except finally raise
	    if elif else while clpy)
  )

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun generate-python-rule (name)
    (check-type name symbol)
    (let* ((name (intern name #.*package*))
	   (str (symbol-name name))
	   (len (length str))
	   (item (intern (subseq str 0 (- len 1)) #.*package*))
	   ;;(name-2 (intern (concatenate 'string str "2") #.*package*))
	   (dp 'defproduction))
      (ecase (aref str (1- len))

	(#\+ `((,dp (,name python-grammar) (,item) ($1))
	       (,dp (,name python-grammar) (,name |,| ,item) ((append $1 (list $3))))))

	(#\* `((,dp (,name python-grammar) ())
	       (,dp (,name python-grammar) (,name ,item) ((append $1 (list $2))))))

	(#\? `((,dp (,name python-grammar) ())
	       (,dp (,name python-grammar) (,item) ($1))))))))

(defmacro python-prods (&rest prodrules)
  (let ((res ()))
    (loop for (name . rest) in prodrules
	if (keywordp name)
	do (assert (null rest))
	   (dolist (rule (generate-python-rule name))
	     (push rule res))
	else if (eq (car rest) ':or)
	do (dolist (x (cdr rest))
	     (push `(defproduction (,name python-grammar)
			,(if (symbolp x) (list x) (car x))
		      ,(if (symbolp x) '($1) (cdr x)))
		   res))
	else
	do  (push `(defproduction (,name python-grammar) ,@rest)
		  res))
    `(progn ,@(nreverse res))))


(python-prods

 ;; Rules (including their names) are taken from the CPython grammar
 ;; file from CPython CVS, file Python/Grammar/Grammar, 20040827.

 ;; The start symbol: regular python files
 (python-grammar (file-input) ((list 'file-input (nreverse $1))))

 (file-input () ())
 (file-input (file-input newline) ($1))
 (file-input (file-input stmt) ((cons $2 $1)))

 (decorator (@ dotted-name newline) ((list 'decorator $1 $2)))
 (decorator (@ dotted-name |(| arglist |)| newline) ((list 'decorator $2 $4)))
 (:decorator+)
 (:decorator+?)

 ;; XXX for now: ignore decorators above function definition
 (funcdef (decorator+? def identifier parameters |:| suite) ((list 'funcdef $3 $4 $6)))

 (parameters ( |(| |)| ) ((list nil nil nil)))
 (parameters ( |(| parameter-list5 |)| ) ($2))

 (parameter-list5 (defparameter+)                        ((list $1 nil nil)))
 (parameter-list5 (defparameter+ ni-*-ident ni-**-ident) ((list $1 $2 $3)))
 (parameter-list5 (defparameter+ ni-*-ident            ) ((list $1 $2 nil)))
 (parameter-list5 (defparameter+            ni-**-ident) ((list $1 nil $2)))
 (parameter-list5 (              *-ident    ni-**-ident) ((list nil $1 $2)))
 (parameter-list5 (              *-ident               ) ((list nil $1 nil)))
 (parameter-list5 (                         **-ident   ) ((list nil nil $1)))

 (defparameter+ (defparameter) ((list $1)))
 (defparameter+ (defparameter+ |,| defparameter) ((append $1 (list $3))))

 (ni-*-ident  ( |,| *-ident ) ($2))
 (*-ident ( * identifier ) ($2))

 (ni-**-ident ( |,| **-ident) ($2))
 (**-ident ( ** identifier ) ($2))

 (defparameter (fpdef) ($1))
 (defparameter (fpdef = test) ((cons $1 $3)))
 
 (fpdef :or
	((identifier) . ($1))
	((|(| fplist |)|) . (`(list ,$2)))) ;; WWW or just $2

 (fplist (fpdef comma--fpdef* comma?) ((cons $1 $2)))
 (:comma--fpdef*)
 (comma--fpdef (|,| fpdef) ($2))

 (:comma?)
 (comma (|,|) ((list $1)))

 (stmt :or simple-stmt compound-stmt)
 (simple-stmt (small-stmt semi--small-stmt* semi? newline) ((if $2 (list 'suite (cons $1 $2))
							      $1)))

 (semi--small-stmt (|;| small-stmt) ($2))
 (:semi--small-stmt*)
 (:semi?)
 (semi (|;|))

 (small-stmt :or expr-stmt print-stmt del-stmt pass-stmt flow-stmt
	     import-stmt global-stmt exec-stmt assert-stmt)

 (expr-stmt (testlist expr-stmt2) ((cond ((and $2 (eq (car $2) '=)) 
					  `(assign-expr (,$1 ,@(second $2))))
					 ($2
					  (list 'augassign-expr (car $2) (car $1) (cdr $2)))
					 (t
					  $1))))

 (expr-stmt2 (augassign testlist) ((cons $1 $2)))
 (expr-stmt2 (=--testlist*) ((list '= $1)))
 (:=--testlist*)
 (=--testlist (= testlist) ($2))

 (augassign :or += -= *= /= %= &= |\|=| ^= <<= >>= **= //= )

 (print-stmt :or
	     ((print) . (`(print nil nil)))
	     ((print test |,--test*| comma?) . ((list 'print (cons $2 $3) (if $4 t nil))))
	     ((print >> test |,--test*| comma?) . ((list 'print->> $3 $4 (if $5 t nil)))))
 (:|,--test*|)
 (|,--test| (|,| test) ($2))

 (del-stmt (del exprlist) ((list $1 $2)))
 (pass-stmt (pass) ((list $1)))
 (flow-stmt :or break-stmt continue-stmt return-stmt raise-stmt yield-stmt)

 (break-stmt (break) ((list $1)))
 (continue-stmt (continue) ((list $1)))
 (return-stmt (return testlist?) ((list $1 $2)))
 (:testlist?)
 (yield-stmt (yield testlist?) ((list $1 $2)))

 (raise-stmt (raise) ((list $1 nil nil nil)))
 (raise-stmt (raise test) ((list $1 $2 nil nil)))
 (raise-stmt (raise test |,| test) ((list $1 $2 $4 nil)))
 (raise-stmt (raise test |,| test |,| test) ((list $1 $2 $4 $6)))

 ;; "import" module ["as" name] ( "," module ["as" name] )*
 (import-stmt :or import-normal import-from)
 (import-normal (import dotted-as-name comma--dotted-as-name*) (`(import (,$2 ,@$3))))
 (:comma--dotted-as-name*)
 (comma--dotted-as-name ( |,| dotted-as-name) ($2))
 (import-from (from dotted-name import import-from-2) (`(import ((from ,$2 ,$4)))))
 (import-from-2 :or
		*
		((import-as-name comma--import-as-name*) . ((cons $1 $2))))
 (:comma--import-as-name*)
 (comma--import-as-name (|,| import-as-name) ($2))
 (import-as-name (identifier) ($1))
 (import-as-name (identifier as identifier) ((list 'as $1 $3)))
 (dotted-as-name (dotted-name) ($1))
 (dotted-as-name (dotted-name as identifier) ((list 'as $1 $3)))
 (dotted-name (identifier dot--name*) ((if $2
					   `(dotted ,$1 ,@(if (eq (first $2) 'dotted)
							      (second $2)
							    $2))
					 $1)))
 (:dot--name*)
 (dot--name (|.| identifier) ($2))

 (global-stmt (global identifier comma--identifier*)
	      (`(global ,(if $3 (cons $2 $3) (list $2)))))
 (:comma--identifier*)
 (comma--identifier (|,| identifier) ($2))
 (exec-stmt (exec expr) ((list $1 $2)))
 (exec-stmt (exec expr in test) ((list $1 $2 $4)))
 (exec-stmt (exec expr in test |,| test) ((list $1 $2 $4 $6)))
 (assert-stmt (assert test comma--test?) ((list $1 $2 $3)))
 (:comma--test?)
 (comma--test (|,| test) ($2))

 (compound-stmt :or if-stmt while-stmt for-stmt try-stmt funcdef classdef)
 (if-stmt (if test |:| suite elif--test--suite* else--suite)
	  (`(if ((,$2 ,$4) ,@$5) ,$6)))
 (if-stmt (if test |:| suite elif--test--suite*)
	  (`(if ((,$2 ,$4) ,@$5) nil)))
 (:elif--test--suite*)
 (elif--test--suite (elif test |:| suite) ((list $2 $4)))
 (else--suite (else |:| suite) ($3))
 (while-stmt (while test |:| suite else--suite?) ((list $1 $2 $4 $5)))
 (:else--suite?)
 (for-stmt (for exprlist in testlist |:| suite else--suite?)
	   ((list 'for-in $2 $4 $6 $7))
	   (:precedence high-prec))
 (try-stmt :or
	   ((try |:| suite except--suite+ else--suite?) . ((list 'try-except $3 $4 $5)))
	   ((try |:| suite finally |:| suite)  	        . ((list 'try-finally $3 $6))))

 (except--suite (except |:| suite) (`((nil nil) ,$3)))
 (except--suite (except test |:| suite) (`((,$2 nil) ,$4)))
 (except--suite (except test |,| test |:| suite) (`((,$2 ,$4) ,$6)))

 (except--suite+ (except--suite) ((list $1)))
 (except--suite+ (except--suite+ except--suite) ((append $1 (list $2))))

 (suite :or
	((simple-stmt) . ((list 'suite (list $1))))
	((newline indent stmt+ dedent) . ((list 'suite $3))))

 (stmt+ (stmt) ((list $1)))
 (stmt+ (stmt+ stmt) ((append $1 (list $2))))

 (expr (binop2-expr) ($1))

 (test :or
       lambdef
       binop-expr)

 (binop-expr :or
	     ((binop-expr and binop-expr) . ((list 'binary $2 $1 $3)))
	     ((binop-expr or  binop-expr) . ((list 'binary $2 $1 $3)))
	     ((not binop-expr)            . ((list 'unary $1 $2)))
	     ((binop-expr <  binop-expr)  .  ((list 'comparison $2 $1 $3)))
	     ((binop-expr <= binop-expr)  . ((list 'comparison $2 $1 $3)))
	     ((binop-expr >  binop-expr)  .  ((list 'comparison $2 $1 $3)))
	     ((binop-expr >= binop-expr)  . ((list 'comparison $2 $1 $3)))
	     ((binop-expr != binop-expr)  . ((list 'comparison $2 $1 $3)))
	     ((binop-expr <> binop-expr)  . ((list 'comparison '!= $1 $3))) ;; <> is same as !=
	     ((binop-expr == binop-expr)  . ((list 'comparison $2 $1 $3)))
	     ((binop-expr in binop-expr)  . ((list 'binary $2 $1 $3)))
	     ((binop-expr is binop-expr)  . ((list 'binary $2 $1 $3))))
 (binop-expr (binop2-expr) ($1) (:precedence or))

 (binop2-expr :or
	      atom
	      ((atom trailer+) . ((parse-trailers (list 'trailers $1 $2))))
	      ((binop2-expr +  binop2-expr) . ((list 'binary $2 $1 $3)))
	      ((binop2-expr -  binop2-expr) . ((list 'binary $2 $1 $3)))
	      ((binop2-expr *  binop2-expr) . ((list 'binary $2 $1 $3)))
	      ((binop2-expr /  binop2-expr) . ((list 'binary $2 $1 $3)))
	      ((binop2-expr ** binop2-expr) . ((list 'binary $2 $1 $3)))
	      ((binop2-expr // binop2-expr) . ((list 'binary $2 $1 $3)))

	      ((binop2-expr << binop2-expr) . ((list 'binary $2 $1 $3)))
	      ((binop2-expr >> binop2-expr) . ((list 'binary $2 $1 $3)))
	      ((binop2-expr &  binop2-expr) . ((list 'binary $2 $1 $3)))
	      ((binop2-expr ^  binop2-expr) . ((list 'binary $2 $1 $3)))
	      ((binop2-expr \| binop2-expr) . ((list 'binary $2 $1 $3)))
	      ((binop2-expr ~  binop2-expr) . ((list 'binary $2 $1 $3)))
	      ((binop2-expr %  binop2-expr) . ((list 'binary $2 $1 $3)))
	      )
 
 ;; some with explicit precedences
 (binop-expr (binop-expr not in binop-expr) ((list 'binary 'not-in $1 $4)) (:precedence in)) ;; was binop2
 (binop-expr (binop-expr is not binop-expr) ((list 'binary 'is-not $1 $4)) (:precedence is)) ;; was binop2
 (binop2-expr (+ binop2-expr) ((list 'unary $1 $2))   (:precedence unary-plusmin))
 (binop2-expr (- binop2-expr) ((list 'unary $1 $2))   (:precedence unary-plusmin))

 (atom :or
       ((|(| comma? |)|) . ((list 'testlist nil (if $2 t nil))))
       ((|(| testlist-gexp |)|) . ((cons 'testlist $2)))

       ((|[| |]|) . ((list 'list nil)))
       ((|[| listmaker |]|) . ((list 'list $2)))
       ((|{| |}|) . ((list 'dict nil)))
       ((|{| dictmaker |}|) . ((list 'dict $2)))
       ((|`| testlist1 |`|) . ((list 'backticks $2)))
       ((identifier) . ((list 'identifier $1)))
       ((number) . ($1))
       ((string+) . ($1))
       ((clpy-expr) . ($1)))

 (clpy-expr (clpy) (`(inline-lisp ,$1)))
   
 (string+ (string) ($1))
 (string+ (string+ string) ((concatenate 'string $1 $2)))

 (listmaker (test list-for) ((list $1 $2)))
 (listmaker (test comma--test* comma?) ((cons $1 $2)))
 (:comma--test*)


 (testlist-gexp (test gen-for) ((list $1 $2)))
 (testlist-gexp (test comma--test* comma?) ((list (cons $1 $2) (if $3 t nil))))

 (lambdef (lambda parameter-list5 |:| test) ((list $1 $2 $4)))
 (lambdef (lambda                 |:| test) ((list $1 nil $3)))

 (trailer+ :or
	   ((|(| arglist? |)|) . ((list (list 'call $2))))
	   ((|[| subscriptlist |]|) . ((list (list 'subscription $2))))
	   ((|.| identifier) . (`((attributeref (identifier ,$2)))))
	   ((trailer+ |(| arglist? |)|) . ((append $1 (list (list 'call $3)))))
	   ((trailer+ |[| subscriptlist |]|) . ((append $1 (list (list 'subscription $3)))))
	   ((trailer+ |.| identifier) . ((append $1 `((attributeref (identifier ,$3)))))))


 (:arglist?)
 (subscriptlist (subscript comma--subscript* comma?) ((list (append (list $1) $2)
							    (if $3 t nil))))
 (:comma--subscript*)
 (comma--subscript (|,| subscript) ($2))
 (subscript :or
	    |...|
	    test
	    ((test? |:| test? sliceop?) . (`(slice ,$1 ,$3 ,$4))))
 (:sliceop?)
 (sliceop (|:| test?) ($2))
 (:test?)

 (exprlist (expr exprlist2) ((list 'exprlist
				   (cons $1 (butlast $2))
				   (car (last $2)))))
 (exprlist2 :or
	    (() . (nil))
	    ((|,|) . ((list t)))
	    ((|,| expr exprlist2) . ((list $2 $3))))

 (testlist (test testlist2) ((list 'testlist
				   (cons $1 (butlast $2))
				   (car (last $2)))))
 (testlist2 :or
	    (() . ((list nil)))
	    ((|,|) . ((list t)))
	    ((|,| test testlist2) . ((cons $2 $3))))


 (testlist-safe :or
		((test) . ($1))
		((test comma--test+ comma?) . ((list $1 $2))))
 (:comma--test+)

 (dictmaker :or
	    ;;((test |:| test comma?) . ((cons $1 $3)))
	    ((test |:| test comma--test--\:--test* comma?) . ((cons (cons $1 $3) $4))))
 (:comma--test--\:--test*)
 (comma--test--\:--test (|,| test |:| test) ((cons $2 $4)))
 
 (classdef (class identifier OB--testlist--CB? |:| suite)
	   ((list $1 $2 $3 $5)))
 (:OB--testlist--CB?)
 (OB--testlist--CB (|(| testlist |)|) ($2))

 (arglist (argument--comma* arglist-2) ((append $1 $2)))

 (arglist-2 :or
	    ;; optional comma is semantically meaningless
	    ((argument comma?) . ((list $1)))
	    ((|*| test comma--**--test?) . ((append (list (list $1 $2))
						    $3
						    nil)))
	    ((|**| test) . ((list (list $1 $2)))))
 (:argument--comma*)
 (argument--comma (argument |,|) ($1))
 (:comma--**--test?)
 (comma--**--test (|,| ** test) ((list (list $2 $3))))

 (argument (test) ((list 'pos $1)))
 
 #+(or) ;; kw = val: kw must be identifier
 (argument (test = test) ((list 'key $1 $3)))
 
 (argument (identifier = test) ((list 'key $1 $3)))
 (argument (test gen-for) ((list 'gen-for $1 $2)))

 (list-iter :or list-for list-if)
 (list-for (for exprlist in testlist-safe list-iter?) (`((list-for-in ,$2 ,$4) . ,$5)))
 (:list-iter?)
 (list-if (if test list-iter?) (`((list-if ,$2) . ,$3)))
 (gen-iter :or gen-for gen-if)
 (gen-for (for exprlist in test gen-iter?))
 (gen-if (if test gen-iter?) ((list $1 $2 $3)))
 (:gen-iter?)
 (testlist1 (test |,--test*|) (`(,$1 ,@(when $2 $2)))))



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; AST manipulating

(defun parse-trailers (ast)
  ;; foo[x].a => (trailers (id foo) ((subscription (id x)) (attributeref (id a))))
  ;;          => (attributeref (subscription (id foo) (id x)) (id a))
  (assert (eq (car ast) 'trailers))
  (destructuring-bind (primary trailers)
      (cdr ast)
    (loop for tr in trailers
	with res = primary
	do (setf res `(,(car tr) ,res ,@(cdr tr)))
	finally (return res))))

#+(or) ;; test
(parse-trailers '(trailers (id foo) ((subscription (id x)) (attributeref (id a)))))

#|
  1 char:  =[]()<>{}.,:|^%+-*/~@
  2 chars: != // << >>  <> != ==
               += -= *= /= //= %=  ^= |=  **= <<= >>=
  3 chars: **= <<= >>=  "
|#


(defvar *tab-width-spaces* 8)

(defmacro read-char-nil ()
  "Returns a character, or NIL on eof"
  `(read-char *standard-input* nil nil t))


(defmacro identifier-char1-p (c)
  "Says whether C is a valid character to start an identifier with. ~@
   C must be either a character or nil."
  `(and ,c
       (or (alpha-char-p ,c)
	   (eql ,c #\_))))

(defmacro identifier-char2-p (c)
  "Says whether C is a valid character to occur in an identifier as ~@
   second or later character. C must be either a character or nil."
  `(and ,c
       (or (alphanumericp ,c)
	   (eql ,c #\_))))

(defun read-identifier (first-char)
  "Returns the identifier read as string. ~@
   Identifiers start start with an underscore or alphabetic character; ~@
   second and further characters must be alphanumeric or underscore."
  (assert (identifier-char1-p first-char))
  (let ((res (make-array 6
			 :element-type 'character
			 :adjustable t
			 :fill-pointer 0)))
    (vector-push-extend first-char res)
    (let ((c (read-char-nil)))
      (loop while (identifier-char2-p c)
	  do (vector-push-extend c res)
	     (setf c (read-char-nil)))
      (unless (null c)
	(unread-char c)))
    (intern res #.*package*)))


;;; STRINGS

(defun read-char-error ()
  (or (read-char-nil)
      (error "Unexpected end of file")))

(defun read-string (first-char)
  "Returns string as a string"
  (assert (member first-char '(#\' #\") :test 'eql))
  
  (let ((second (read-char-error))
	(third (read-char-nil)))

    (cond 
       
     ;; "" ('') but not """ (''') --> empty string
     ((and (char= first-char second)
	   (or (null third)
	       (char/= first-char third)))
	
      (when third
	(unread-char third))
      (return-from read-string ""))
       
       
     ;; """ or ''': a long? multi-line? string
     ((char= first-char second third)
	
      (let* ((res (make-array 50
			      :element-type 'character
			      :adjustable t
			      :fill-pointer 0))
	     (x (read-char-error))
	     (y (read-char-error))
	     (z (read-char-error)))
	  
	(loop until (char= first-char x y z)
	    do (vector-push-extend
		(shiftf x y z (read-char-error))
		res))
	(return-from read-string res)))
      

     ;; non-empty string with one starting quote
     ;; Quotes can be escaped with a backslash.
     (t 
	
      (unless third
	(py-raise 'SyntaxError "Quoted string not finished"))
	
      (let ((res (make-array 30
			     :element-type 'character
			     :adjustable t
			     :fill-pointer 0)))
	  
	(unless (char= second #\\)
	  (vector-push-extend second res))
	  
	(let ((c third)
	      (prev-backslash (char= second #\\)))
	    
	  (loop 
	    (cond
	     ;; Rules: <http://meta.kabel.utwente.nl/specs/Python-Docs-2.3.3/ref/strings.html>
	    
	     (prev-backslash
	      (case c
		(#\Newline) ;; ignore: quoted string continues on next line
		(#\\ (vector-push-extend #\\ res))        (#\' (vector-push-extend #\' res))
		(#\" (vector-push-extend #\" res))        (#\a (vector-push-extend #\Bell res))
		(#\b (vector-push-extend #\Backspace res))(#\f (vector-push-extend #\Page res))
		(#\n (vector-push-extend #\Newline res))
		((#\N #\u #\U) (error "TODO: unicode support in strings"))
		(#\r (vector-push-extend #\Return res)) (#\t (vector-push-extend #\Tab res))
		(#\u (error "TODO: unicode support"))   (#\v (vector-push-extend #\VT  res))
		  
		((#\0 #\1 #\2 #\3 #\4 #\5 #\6 #\7) ;; char code: up to three octal digits
		 (let ((char-code
			(loop with res = (digit-char-p c 8)
			    with x = c
			    for num from 1
			    while (and (<= num 2) (digit-char-p x 8))
			    do (setf res (+ (* res 8) (digit-char-p x 8))
				     x (read-char-error))
			    finally (unread-char x)
				    (return res))))
		   (vector-push-extend (code-char char-code) res)))
		  
		(#\x (let* ((a (read-char-error)) ;; char code: up to two hex digits
			    (b (read-char-error)))
		       (unless (digit-char-p a 16)
			 (py-raise 'SyntaxError
				   "Invalid hex in string literal:  \ x ~A" a))
		       (vector-push-extend
			(code-char (if (digit-char-p b 16)
				       (+ (* 16 (digit-char-p a 16))
					  (digit-char-p b 16))
				     (progn (unread-char b)
					    (digit-char-p a 16)))) res)))
		  
		(t 
		 ;; Backslash is not used for escaping: collect both
		 ;; the backslash itself and the character just
		 ;; read.
		 (vector-push-extend #\\ res)
		 (vector-push-extend c res)))
		
	      (setf prev-backslash nil))
	       
	     ((char= c #\\)
	      (setf prev-backslash t))
	       
	     ((char= c first-char) ;; end quote of literal string
	      (return-from read-string res))
	       
	     (t 
	      (vector-push-extend c res)))
	      
	    (setf c (read-char-error)))))))))


;; integers:     input  -> base-10 val  system used
;;                 11           11         10 (decimal)
;;                011            9          8 (octal)
;;               0x11           17         16 (hexadecimal)
;;
;; integers with exponent:
;;       11e3 = 011e3 = 11E3 = 11e+3 == 11E+3 = 11000.0 (a float)
;;       11e-3 = 0.011 (approx)
;;       0x11e3 = regular hex 4579
;;
;; floats:       input  -> base-10 val  system used
;;                11.3         11.3        10
;;               011.3         11.3        10    ! (exp: error)
;;              0x11.3           *syntax error*
;;
;; floats with exponent:
;;        011.3e3 = 11.3e3 = 011.3e+3 = 11.3e+3 = 11300
;;        011.3e-3 = 11.3e-3 = 11300
;;
;; imag ints:    input  -> base-10 val  system used
;;                11j          11j         10
;;               011j          11j         10    ! (exp: 9j)
;;              0x11j           *syntax error*   ! (exp: 17j)
;;
;; imag ints with exponent:
;;         1e3j = 1000j etc.
;;
;; imag floats:  input  -> base-10 val  system used
;;               11.3j         11.3j       10
;;              011.3j         11.3j       10   ! (exp: error)
;;             0x11.3j          *syntax error*
;;
;; imag floats with exp:
;;    1.0e-3j -> 0.001j etc.
;;
;; Integers (dec, oct, hex) may have the suffix `l' or `L', meaning
;; `long', though the difference between regular and long integers
;; has mostly ceased to exist (operations on regular integers that
;; return an integer in the range of long integers, implicitly
;; convert the result to a long). We ignore any difference between
;; regular and long integers.

(defun read-number (&optional (first-char (read-char-error)))
  (assert (digit-char-p first-char 10))
  (let ((base 10)
	(res 0))
	
    (flet ((read-int (&optional (res 0))
	     (loop with ch = (read-char-nil)
		 while (and ch (digit-char-p ch base))
		 do (setf res (+ (* res base) (digit-char-p ch base))
			  ch (read-char-nil))
		 finally (when ch 
			   (unread-char ch))
			 (return res))))
	  
      (if (char= first-char #\0)

	  (let ((second (read-char-nil)))
	    (setf res (cond ((null second) 0) ;; eof
			     
			    ((member second '(#\x #\X))
			     (setf base 16)
			     (read-int))
			    
			    ((digit-char-p second 8)
			     (setf base 8)
			     (read-int (digit-char-p second 8)))
			    
			    ((char= second #\.)
			     (unread-char second)
			     0)
			    
			    ((digit-char-p second 10) 
			     (read-int (digit-char-p second 10)))
			    
			    ((member second '(#\j #\J))  #(0 0))
			    ((member second '(#\l #\L))  0)
			    (t (unread-char second)
			       0)))) ;; non-number, like `]' in `x[0]'
	
	(setf res (read-int (digit-char-p first-char 10))))
      
      (let ((has-frac nil) (has-exp nil))
	
	(when (= base 10)
	  (let ((dot? (read-char-nil)))
	    (if (eql dot? #\.)
		
		(progn
		  (setf has-frac t)
		  (incf res
			(loop
			    with ch = (read-char-nil)
			    with lst = ()
			    while (and ch (digit-char-p ch 10))
			    do (push ch lst)
			       (setf ch (read-char-nil))
			       
			    finally (setf lst (nreverse lst))
				    (push #\. lst)
				    (push #\0 lst)
				    (unread-char ch)
				    (return (read-from-string
					     (make-array (length lst)
							 :initial-contents lst
							 :element-type 'character))))))
		      
	      (when dot? (unread-char dot?)))))
	
	;; exponent marker
	(when (= base 10)
	  (let ((ch (read-char-nil)))
	    (if (member ch '(#\e #\E))
		
		(progn
		  (setf has-exp t)
		  (let ((ch2 (read-char-error))
			(exp 0)
			(minus nil)
			(got-num nil))
		  
		    (cond
		      ((char= ch2 #\+))
		      ((char= ch2 #\-)       (setf minus t))
		      ((digit-char-p ch2 10) (setf exp (digit-char-p ch2 10)
						   got-num t))
		      (t (py-raise 'SyntaxError
				   "Exponent for literal number invalid: ~A ~A" ch ch2)))
		  
		    (unless got-num
		      (let ((ch3 (read-char-error)))
			(if (digit-char-p ch3 10)
			    (setf exp (+ (* 10 exp) (digit-char-p ch3 10)))
			  (py-raise 'SyntaxError
				    "Exponent for literal number invalid: ~A ~A ~A"
				    ch ch2 ch3))))
		  
		    (loop with ch
			while (and (setf ch (read-char-nil))
				   (digit-char-p ch 10))
			do (setf exp (+ (* 10 exp) (digit-char-p ch 10)))
			finally (when ch (unread-char ch)))
		  
		    (when minus
		      (setf exp (* -1 exp)))
		  
		    (setf res (* res (expt 10 exp)))))
	      
	      (when ch
		(unread-char ch))))

	  ;; suffix `L' for `long integer'
	  (unless (or has-frac has-exp)
	    (let ((ch (read-char-nil)))
	      (if (and (not (member ch '(#\l #\L)))
		       ch)
		  (unread-char ch))))
		
	  ;; suffix `j' means imaginary
	  (let ((ch (read-char-nil)))
	    (if (member ch '(#\j #\J))
		(setf res (complex 0 res))
	      (when ch (unread-char ch)))))
		
	res))))
		
		
		
#+(or)
(defun read-number (first-char)
  (assert (digit-char-p first-char 10))
  (let* ((res (digit-char-p first-char 10))
	 (base 10))

    (when (char= first-char #\0)
      (let ((second (read-char-nil)))
	(cond
	 ((not second)
	  (return-from read-number 0))

	 ((member second '(#\x #\X) :test #'char=)
	  (setf base 16))

	 ((digit-char-p second 8)
	  (setf base 8)
	  (setf res (digit-char-p second 8)))

	 ((char= second #\.) ;; <digit>.<something> like 1.2 or 1.23 or 1.234 etc
	  (unread-char second)) ;; and continue

	 ((member second '(#\j #\J))
	  (return-from read-number #C(0 0)))
	 
	 ((member second '(#\L #\l)) ;; it's a "long" integer -- suffix ignored here
	  (return-from read-number 0))
	 
	 ((alphanumericp second)
	  (error "Invalid number (got: '0~A'" second))
	 
	 (t ;; non-number stuff after a zero, like `]' in `x[0]'
	  (unread-char second)
	  (return-from read-number 0)))))

    (let* ((c (read-char-nil))
	   (d (and c (digit-char-p c base))))
      (loop while d do
	    (setf res (+ (* res base) d)
		  c (read-char-nil)
		  d (and c (digit-char-p c base))))

      ;; only decimal numbers may have a fraction
      (if (and c
	       (= base 10)
	       (char= c #\.))

	  ;; let's collect all digits and call the Lisp reader on it
	  (let ((fraction-v (make-array 4
					:element-type 'character
					:adjustable t
					:fill-pointer 0)))
	    (vector-push #\0 fraction-v)
	    (vector-push #\. fraction-v)
	    (let ((c (read-char-nil)))

	      (loop while (and c (digit-char-p c 10))
		  do (vector-push-extend c fraction-v)
		     (setf c (read-char-nil)))

	      (incf res (read-from-string fraction-v))

	      (when (and c
			 (not (digit-char-p c 10)))
		(unread-char c))))

	(when c
	  (cond ((member c '(#\L #\l)) )       ;; Suffix for `long' integers: ignored
		((member c '(#\C #\c)) (setf res (complex 0 res))) ;; imaginary number -- XXX check next char
		(t (unread-char c))))))
    res))


;;; punctuation

(defmacro punct-char1-p (c)
  `(and ,c
	(find ,c "`=[]()<>{}.,:|^&%+-*/~;@")))

(defmacro punct-char-not-punct-char1-p (c)
  "Punctuation  !  may only occur in the form  !=  "
  `(and ,c
	(char= ,c #\!)))

(defmacro punct-char2-p (c1 c2)
  "Recognizes: // << >>  <> !=  <= >=
               == += -= *= /= %=  ^= |= &= ** **= <<= >>= "
  `(and ,c1 ,c2
	(or (and (char= ,c2 #\= )
		 (member ,c1 '( #\+ #\- #\* #\/ #\%  #\^ #\&
			       #\| #\! #\= #\< #\> )))
	    (and (char= ,c1 ,c2)
		 (member ,c1 '( #\* #\< #\> #\/ #\< #\> )))
	    (and (char= ,c1 #\< )
		 (char= ,c2 #\> )))))

(defmacro punct-char3-p (c1 c2 c3)
  "Recognizes:  **= <<= >>= //="
  `(and ,c1 ,c2 ,c3
	(char= ,c3 #\= )
	(char= ,c1 ,c2)
	(member ,c1 '( #\* #\< #\> #\/ ))))

(defun read-punctuation (c1)
  "Returns puncutation as a string."
  (assert (or (punct-char1-p c1)
	      (punct-char-not-punct-char1-p c1)))
  (let ((c2 (read-char-nil)))
    (if (punct-char2-p c1 c2)
	(let ((c3 (read-char-nil)))
	  (if (punct-char3-p c1 c2 c3)
	      ;; 3 chars
	      (make-array 3 :element-type 'character
			  :initial-contents (list c1 c2 c3))
	    ;; 2 chars
	    (progn (when c3 (unread-char c3))
		   (make-array 2 :element-type 'character
			       :initial-contents (list c1 c2)))))
      ;; 1 char, or two of three dots
      (if (and c2 (char= #\. c1 c2))
	  (let ((c3 (read-char-nil)))
	    (if (and c3 (char= c3 #\.))
		"..."
	      (error "Characters `..' may only occur as in `...'")))

	(if (punct-char1-p c1)
	    (progn (when c2 (unread-char c2))
		   (string c1))
	  (error
	   "Character `!' may only occur as in `!=', not standalone"))))))

(defun punctuation->token (punc-str)
  " Punctuation
      1 char:  =[]()<>{}.,:|^%+-*/~  and also: ;
      2 chars: != // << >>  <> !=
               += -= *= /= %=  ^= |=  **= <<= >>=
      3 chars: **= <<= >>=  "
  (intern punc-str))


(defun read-whitespace ()
  "Reads all whitespace and comments, until first non-whitespace ~@
   character.

   If Newline was found inside whitespace, values returned are (t N) ~@
   where N is the amount of whitespace after the Newline (N >= 0) ~@
   before the first non-whitespace character (in other words, the ~@
   indentation of the first non-whitespace character) measured in ~@
   spaces, where each Tab is equivalent to *tab-width-spaces* spaces. ~@

   If no Newline was encountered, returns NIL. ~@
   If EOF encountered, NIL is returned."

  (let ((found-newline nil)
	(c (read-char-nil))
	(n 0))
    (loop
      (cond ((not c) (return-from read-whitespace
		       (if found-newline (values t n) nil)))
	    ((char= c #\Newline) (setf found-newline t
				       n 0))
	    ((char= c #\Space) (incf n))
	    ((char= c #\Tab) (incf n *tab-width-spaces*))
	    ((char= c #\#) (read-comment-line c)
			   (setf found-newline t
				 n 0))
	    (t (unread-char c)
	       (return-from read-whitespace
		 (if found-newline (values t n) nil))))
      (setf c (read-char-nil)))))

(defun read-comment-line (c)
  "Read until the end of the line, excluding the Newline."
  (assert (char= c #\#))
  (let ((c (read-char-nil)))
    (loop while (and c (char/= c #\Newline))
	do (setf c (read-char-nil)))
    (unread-char c)))

#+(or)
(defun test-prog ()
"if a == 2:
   if b > 3:
      pass
   else:
      pass
 else:
   pass")

#+(or)
(defun test-prog ()
"if a == 2:
   b = 24
   if b > 3:
      pass
   else:
      pass
 else:
   pass")

#+(or)
(defun test-prog ()
"def foo(a, b):
   if a == 1:
      a = 2
      if b > 3:
         3 + 23
         b
      else:
         6 + 23
         a = 5
         return a
   elif a == 6:
      pass71
      pass72
   elif a == 8:
      b = 9
   else:
      pass10
      pass11")

#+(or)
(defun test-prog ()
"def foo(a, b):
   if a == 2:
      a = 4
      if b > 3:
         return a + b
      else:
         return 'bazzz'
   else:
      return 42")


;;; tests


(defparameter *lex-debug* nil)

;; XXX take a function that gives characters
(defun make-py-lexer (&optional (*standard-input* *standard-input*))
  (let ((tokens-todo (list))
	(indentation-stack (list 0))
	(open-lists ()))
    
    (lambda (grammar &optional op)
      (declare (ignore grammar op))
      (block lexer

	(when tokens-todo
	  (when *lex-debug*
	    (format t "lexer returns ~s  (from TODO)~%" (car tokens-todo)))
	  (return-from lexer (apply #'values (pop tokens-todo))))

	(with-terminal-codes (python-grammar)
	  (macrolet ((lex-todo (val1 val2)
		       `(progn (when *lex-debug*
				 (format t "lexer-todo: ~s~%" ',val1 ',val2))
			       (push (list (tcode ,val1) ,val2) tokens-todo)))
		     (lex-return (val1 val2)
		       `(let ((v2 ,val2))
			  (when *lex-debug*
			    (format t "lexer returning: ~s ~s~%" ',val1 v2))
			  (return-from lexer (values (tcode ,val1) v2))))
		     (char-member (c list)
		       `(member ,c ',list :test #'char=)))

	    (tagbody next-char
	      (let ((c (read-char-nil)))

		(cond

		 ((not c)

		  ;; Before returning EOF, return NEWLINE followed by
		  ;; a DEDENT for every currently active indent.
		  ;;
		  ;; Returning NEWLINE is not needed when last line
		  ;; in file was already NEWLINE, but for simplicity
		  ;; just return it always here.

		  (if (> (car indentation-stack) 0)

		      (progn
			(lex-todo eof 'eof)
			(lex-todo newline 'newline) ;; needed?

			(loop while (> (car indentation-stack) 0)
			    do (pop indentation-stack)
			       (lex-todo dedent 'dedent))

			(lex-return newline 'newline))

		    (progn (lex-todo eof 'eof)
			   (lex-return newline 'newline))))

		 ((digit-char-p c 10) (lex-return number (read-number c)))

		 ((identifier-char1-p c)
		  (let* ((read-id (read-identifier c))
			 (token (intern read-id)))
		    		    
		    (cond ((eq token 'clpy) ;; allows mixing Lisp code in Python files clpy(3) -> 3
			   (let ((lisp-form (read)))
			     (when *lex-debug*
			       (format t "lexer returning Lisp form: ~s~%" lisp-form))
			     (return-from lexer (values (tcode-1 (find-class 'python-grammar) 'clpy)
							lisp-form))))
			  
			  ((member token *reserved-words* :test #'eq)
			   (when *lex-debug*
			     (format t "lexer returning reserved word: ~s~%" token))
			   (return-from lexer
			     (values (tcode-1 (find-class 'python-grammar) token)
				     token)))
			  
			  (t
			   (when *lex-debug*
			     (format t "lexer returning identifier: ~s~%" read-id))
			   (return-from lexer
			     (values (tcode identifier)
				     read-id))))))

		 ((or (char= c #\')
		      (char= c #\")) (lex-return string (read-string c)))

		 ((or (punct-char1-p c)
		      (punct-char-not-punct-char1-p c))
		  (let* ((punct (read-punctuation c))
			 (token (punctuation->token punct)))
		    
		    ;; Keep track of whether we are in a bracketed
		    ;; expression, because in that case newlines are
		    ;; ignored.
		    
		    (case token
		      (( [ { \( ) (push token open-lists))
		      (( ] } \) ) (pop open-lists)))
		    
		    (when *lex-debug*
		      (format t "lexer returning punctuation token: ~s  ~s~%" token punct))
		    (return-from lexer (values (tcode-1 (find-class 'python-grammar) token)
					       token))))

		 ((char-member c (#\Space #\Tab #\Newline))
		  (unread-char c)
		  (multiple-value-bind (newline new-indent)
		      (read-whitespace)
		    
		    (when (or (not newline)
			      open-lists)
		      (go next-char))
		    
		    ;; Return Newline now, but also determine if
		    ;; there are any indents or dedents to be
		    ;; returned in next calls.
		      
		    (cond
		     ((= (car indentation-stack) new-indent)) ;; same indentation

		     ((< (car indentation-stack) new-indent) ; one indent
		      (push new-indent indentation-stack)
		      (lex-todo indent 'indent))

		     ((> (car indentation-stack) new-indent) ; dedent(s)
		      (loop while (> (car indentation-stack) new-indent)
			  do (pop indentation-stack)
			     (lex-todo dedent 'dedent))
		      (unless (= (car indentation-stack) new-indent)
			(error "Dedent didn't arrive at a previous indentation ~
                                level (indent level after dedent: ~A spaces)"
			       new-indent))))

		    (lex-return newline 'newline)))

		 ;;((char= c #\;) ;; equivalent to Newline (used for >1 stms on same line)
		 ;; (lex-return Newline))

		 ((char= c #\#) ;; comment to end-of-line
		  (read-comment-line c)
		  (go next-char))

		 ((char= c #\\) ;; next line is continuation of this one
		  (let ((c2 (read-char-nil)))
		    (if (and c2 (char= c2 #\Newline))
			(go next-char)
		      (error "Syntax error: continuation character \\ ~
                              must be followed by Newline, but got ~S" c2))))

		 (t (error "Unexpected character: ~A" c)))))))))))

(defun parse-python (&optional (*standard-input* *standard-input*))
  (let* ((lexer (make-py-lexer))
	 (grammar (make-instance 'python-grammar :lexer lexer))
	 (*print-level* nil)
	 (*print-pretty* t))
    (parse grammar)))

(defun parse-python-string (string)
  (with-input-from-string (stream string)
    (parse-python stream)))



(build-grammar python-grammar t t)
