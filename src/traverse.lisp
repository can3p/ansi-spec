(in-package :cl-user)
(defpackage ansi-spec.traverse
  (:use :cl)
  (:export :traverse
           :traverse-string)
  (:documentation "Traverse a TeX document, ignoring some nodes, extracting info
  from others into an output XML file."))
(in-package :ansi-spec.traverse)

;;; Some utilities

(defun next-n-siblings (child n)
  "Return the next n siblings of this Plump node."
  (let ((results (list))
        (current child))
    (loop for i from 1 to n do
      (let ((sibling (plump:next-sibling current)))
        (setf current sibling)
        (push sibling results)))
    (remove-if #'null (reverse results))))

(defun siblings-until (node test)
  "Find all siblings until a certain element."
  (let ((siblings (plump:children (plump:parent node)))
        (start-pos nil)
        (end-pos nil))
    (loop for i from 0 to (1- (length siblings)) do
      (let ((sibling (elt siblings i)))
        (when (eq node sibling)
          ;; Found the start position
          (setf start-pos i))
        (when (funcall test sibling)
          ;; Found the end node
          (setf end-pos i))))
    (unless end-pos
      ;; If we didn't find the end position, set it to the last element
      (setf end-pos (1- (length siblings))))
    (subseq siblings (1+ start-pos) end-pos)))

(defmacro replace-text (text old new)
  `(ppcre:regex-replace-all ,old ,text ,new))

;;; Output stream

(defvar *stream*)

(defvar *transform-text* t
  "Whether or not to apply text transforms. Disabled when emitting code.")

(defun transform-text (string)
  "Apply some transformations to the TeX text nodes."
  (flet ((left-quote (text)
           (replace-text text "``" "“"))
         (right-quote (text)
           (replace-text text "''" "”"))
         (tilde-to-space (text)
           (replace-text text "~" " "))
         (triple-hyphen-to-mdash (text)
           (replace-text text "---" "—"))
         (double-hyphen-to-ndash (text)
           (replace-text text "--" "–")))
    (double-hyphen-to-ndash ;; Maintain the relative order of these first two
     (triple-hyphen-to-mdash
      (tilde-to-space
       (right-quote
        (left-quote string)))))))

(defun output (string)
  "Write a string to the output stream."
  (write-string (if *transform-text*
                    (transform-text string)
                    string)
                *stream*))

(defun strip-text (text)
  "Remove some text nonsense from some text."
  (ppcre:regex-replace-all "/"
                           (ppcre:regex-replace-all "\\/" text "")
                           ""))

;;; Modes

(defclass mode ()
  ((name :reader mode-name
         :initarg :name
         :type string
         :documentation "The name that triggers the mode.")
   (callbacks :reader mode-callbacks
              :initarg :callbacks
              :type list
              :documentation "A list of functions that take a node as their sole
              argument.")
   (after-callback :reader mode-after-callback
                   :initarg :after-callback
                   :type (or function null)
                   :documentation "A function that takes a node as its argument
                   and is called after all callbacks are processed."))
  (:documentation "A parser mode."))

(defun mode-arity (mode)
  "Return the arity of the mode."
  (length (mode-callbacks mode)))

(defparameter *modes* (make-hash-table :test #'equal)
  "A map of node names to mode objects.")

(defun get-mode (tag-name)
  "Find a node by tag-name. Return NIL if none is found."
  (gethash tag-name *modes*))

(defparameter *node-callbacks* (make-hash-table :test #'eq)
  "A map of Plump nodes to functions.")

(defparameter *after-callbacks* (make-hash-table :test #'eq)
  "A map of Plump nodes to functions.")

(defun attach-callback (store node callback)
  "Attach a callback to a Plump node."
  (unless callback
    (break))
  (setf (gethash node store) callback))

(defun detach-callback (store node)
  "Remove a callback from a Plump node."
  (remhash node store))

(defun try-callback (store node)
  "If this mode has an associated callback, call it, and detach the callback."
  (multiple-value-bind (callback found)
      (gethash node store)
    (when found
      (funcall callback node)
      (detach-callback store node))))

(defmacro define-mode ((tag-name) &key callbacks after)
  "Define a mode."
  (flet ((process-function (form)
           (destructuring-bind (arglist &rest body)
               form
             (if arglist
                 ;; Uses the node argument
                 `(lambda (,(first arglist))
                    ,@body)
                 ;; Ignores the node
                 (let ((node (gensym)))
                   `(lambda (,node)
                      (declare (ignore ,node))
                      ,@body))))))
    (let ((tag (gensym)))
      `(let ((,tag ,tag-name))
         (setf (gethash ,tag *modes*)
               (make-instance 'mode
                              :name ,tag
                              :callbacks
                              (list ,@(mapcar #'process-function callbacks))
                              :after-callback ,(if after
                                                   (process-function after)
                                                   nil)))))))

(defun on-node (node)
  "Dispatch a node."
  ;; If it has a tag, see if there's a corresponding mode.
  (when (plump:element-p node)
    (let ((tag (plump:tag-name node)))
      (if (get-mode tag)
          ;; Trigger the mode
          (let* ((mode (get-mode tag))
                 (arity (mode-arity mode)))
            (when (> arity 0)
              ;; Find the next `arity-1` siblings, and attach all but the first
              ;; callbacks to them. The first callback is called immediately
              ;; with the current node
              (funcall (first (mode-callbacks mode)) node)
              (let ((siblings (next-n-siblings node (1- arity))))
                (loop for i from 0 to (1- (length siblings)) do
                  (let ((callback (nth i (rest (mode-callbacks mode)))))
                    (when callback
                      (attach-callback *node-callbacks*
                                       (nth i siblings)
                                       callback))))
                ;; Attach the last sibling to the after callback
                (when (mode-after-callback mode)
                  (if siblings
                      (attach-callback *after-callbacks*
                                       (first (last siblings))
                                       (mode-after-callback mode))
                      (attach-callback *after-callbacks*
                                       node
                                       (mode-after-callback mode)))))))
          ;; Warn the user
          (warn "Tag ~S has no corresponding mode" tag))))
  ;; Try to call this node's callback
  (try-callback *node-callbacks* node)
  ;; If the node is a text node, write it to the output stream
  (when (plump:text-node-p node)
    (output (plump:text node))))

;;; Traversal

(defgeneric tree-traverse (node function)
  (:documentation "Depth-first tree traversal. Plump has a function to do this,
  but it doesn't quite meet my needs. Sigh.")

  (:method ((node plump:node) function)
    (funcall function node)
    node)

  (:method ((node plump:nesting-node) function)
    (call-next-method)
    (loop for child across (plump:children node) do
      (tree-traverse child function))
    ;; Do we have an after callback?
    (try-callback *after-callbacks* node)
    node))

;;; Interface

(defun traverse-node (node)
  (ansi-spec.file:with-output-file (*stream*)
    (tree-traverse node #'on-node)))

(defun traverse-string (string)
  (with-output-to-string (*stream*)
    (tree-traverse (plump-tex:parse string) #'on-node)))

(defun traverse (pathname)
  "Traverse the document in pathname."
  (format t "~&Traversing '~A.tex'" (pathname-name pathname))
  (traverse-node (plump-tex:parse
                  (ansi-spec.preprocess:preprocess
                   (uiop:read-file-string pathname)))))
