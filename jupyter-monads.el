;;; jupyter-monads.el --- Monadic Jupyter I/O -*- lexical-binding: t -*-

;; Copyright (C) 2020 Nathaniel Nicandro

;; Author: Nathaniel Nicandro <nathanielnicandro@gmail.com>
;; Created: 11 May 2020

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 3, or (at
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

;; 

;;; Code:

(defgroup jupyter-monads nil
  "Monadic Jupyter I/O"
  :group 'jupyter)

(cl-defstruct jupyter-delayed value)

(defun jupyter-scalar-p (x)
  (or (symbolp x) (numberp x) (stringp x)
      (and (listp x)
           (memq (car x) '(quote function closure)))))

(defconst jupyter-io-nil (make-jupyter-delayed :value (lambda () nil)))

;; TODO: Any monadic value is really a kind of delayed value in some
;; sense, since it represents some staged computation to be evaluated
;; later.  Change the name to `jupyter-return-io' and also change
;; `jupyter-delayed' to `jupyter-io'.
(defun jupyter-return-delayed (value)
  "Return an I/O value that evaluates BODY in the I/O context.
The result of BODY is the unboxed value of the I/O value.  BODY
is evaluated only once."
  (declare (indent 0) (debug (&rest form)))
  (make-jupyter-delayed :value (lambda () value)))

(defvar jupyter-current-io
  (lambda (content)
    (error "Unhandled I/O: %s" content)))

;; TODO: How to incorporate `make-thread', `thread-join'?
(defun jupyter-bind-delayed (io-value io-fn)
  "Bind IO-VALUE to IO-FN.
Binding causes the evaluation of a delayed value, IO-VALUE (a
closure), in the current I/O context.  The unwrapped
value (result of evaluating the closure) is then passed to IO-FN
which returns another delayed value.  Thus binding involves
unwrapping a value by evaluating a closure and giving the result
to IO-FN which returns another delayed value to be bound at some
future time.  Before, between, and after the two calls to
IO-VALUE and IO-FN, the I/O context is maintained."
  (declare (indent 1))
  (pcase (funcall (jupyter-delayed-value io-value))
	((and req (cl-struct jupyter-request client))
     (let ((jupyter-current-client client))
	   (funcall io-fn req)))
	(`(timeout ,(and req (cl-struct jupyter-request)))
	 (error "Timed out: %s" (cl-prin1-to-string req)))
	(`,value (funcall io-fn value))))

(defmacro jupyter-mlet* (varlist &rest body)
  "Bind the I/O values in VARLIST, evaluate BODY.
Return the result of evaluating BODY, which should be another I/O
value."
  (declare (indent 1) ((&rest (symbolp form)) body))
  (letrec ((value (make-symbol "value"))
           (binder
            (lambda (vars)
              (if (zerop (length vars))
                  (if (zerop (length body)) 'jupyter-io-nil
                    `(progn ,@body))
                (pcase-let ((`(,name ,io-value) (car vars)))
                  `(jupyter-bind-delayed ,io-value
                     (lambda (,value)
                       ,(if (eq name '_)
                            ;; FIXME: Avoid this.
                            `(ignore ,value)
                          `(setq ,name ,value))
                       ,(funcall binder (cdr vars)))))))))
    `(let (,@(delq '_ (mapcar #'car varlist)))
       ,(funcall binder varlist))))

(defmacro jupyter-with-io (io &rest body)
  "Return an I/O action evaluating BODY in IO's I/O context.
The result of the returned action is the result of the I/O action
BODY evaluates to."
  (declare (indent 1) (debug (form body)))
  `(make-jupyter-delayed
    :value (lambda ()
             (let ((jupyter-current-io ,io))
               (jupyter-mlet* ((result (progn ,@body)))
                 result)))))

(defmacro jupyter-run-with-io (io &rest body)
  "Return the result of evaluating the I/O value BODY evaluates to.
The result is return as an I/O value.  All I/O operations are
done in the context of IO."
  (declare (indent 1) (debug (form body)))
  `(jupyter-mlet* ((result (jupyter-with-io ,io
                             ,@body)))
     result))

;; do (for the IO monad) takes IO actions, functions of one argument
;; that return IO values (values with type `jupyter-delayed'), and
;; returns the actions composed.  In the IO monad, composition is
;; equivalent to performing one IO action after the other.  The result
;; of one action being bound to the next.  The initial action is bound
;; to nil.
;;
;; Based on explanations at
;; https://wiki.haskell.org/Introduction_to_Haskell_IO/Actions
(defmacro jupyter-do (&rest io-actions)
  "Return an I/O action that performs all actions in IO-ACTIONS.
The actions are evaluated in the order given.  The result of the
returned action is the result of the last action in IO-ACTIONS."
  (declare (indent 0))
  (if (zerop (length io-actions)) 'jupyter-io-nil
    (letrec ((before
              (lambda (io-actions)
                (if (= (length io-actions) 1) (car io-actions)
                  `(jupyter-then ,(funcall before (cdr io-actions))
                     ,(car io-actions))))))
      (funcall before (reverse io-actions)))))

(defun jupyter-then (io-a io-b)
  "Return an I/O action that performs IO-A then IO-B.
The result of the returned action is the result of IO-B."
  (declare (indent 1))
  (make-jupyter-delayed
   :value (lambda ()
            (jupyter-mlet* ((_ io-a)
                            (result io-b))
              result))))

;;; Kernel
;;
;; I/O actions that manage a kernel's lifetime.

;; TODO: Swap definitions with `jupyter-launch', same for the others.
;; (jupyter-launch :kernel "python")
;; (jupyter-launch :spec "python")
(defun jupyter-kernel-launch (&rest args)
  (make-jupyter-delayed
   :value (lambda ()
            (let ((kernel (apply #'jupyter-kernel args)))
              (jupyter-launch kernel)
              kernel))))

(defun jupyter-kernel-interrupt (kernel)
  (make-jupyter-delayed
   :value (lambda ()
            (jupyter-interrupt kernel)
            kernel)))

(defun jupyter-kernel-shutdown (kernel)
  (make-jupyter-delayed
   :value (lambda ()
            (jupyter-shutdown kernel)
            kernel)))

;;; Publisher/subscriber
;;
;; TODO: Wrap the subscriber functions in a struct
;; (cl-defstruct jupyter-subscriber id io ...)
;;
;; TODO: Verify monadic laws.

(define-error 'jupyter-subscribed-subscriber
  "A subscriber cannot be subscribed to.")

(defun jupyter-subscriber (fn)
  "Return a subscriber evaluating FN for side-effects on published content."
  (declare (indent 0))
  (lambda (sub-content)
    ;; TODO: fn -> fun
    (pcase sub-content
      (`(content ,content) (funcall fn content))
      (`(subscribe ,_) (signal 'jupyter-subscribed-subscriber nil))
      (_ (error "Unhandled content: %s" sub-content)))))

(defun jupyter-send-content (value)
  "Arrange for VALUE to be sent to subscribers of a publisher."
  (list 'content value))

(defsubst jupyter-unsubscribe ()
  "Arrange for the current subscription to be canceled.
A subscriber (or publisher with a subscription) can return the
result of this function to cancel its subscription with the
publisher providing content."
  (list 'unsubscribe))

;; I/O actions return I/O values (values wrapped by
;; `jupyter-return-delayed').  Subscribers return the status of their
;; subscription.  Publishers return content for their subscribers.
;; Monadic functions are those functions that take a value and return
;; boxed values that are interpreted by the associated context.

;; Deliver the content to the subscriber, subscribers consume content
;; without returning any new content to the publisher.
(defun jupyter--deliver (sub-content sub)
  "Bind SUB-CONTENT to SUB, a (re-)publisher or subscriber.
Binding content to a subscriber returns the subscriber if the
subscription should be kept and nil if it should not.

A subscriber function (a function passed to `jupyter-subscriber'
or `jupyter-publisher') can return the result of evaluating
`jupyter-unsubscribe' to cancel a subscription."
  (condition-case error
      ;; This recursion may be a problem if there is a lot of content
      ;; filtering (by subscribing publishers to publishers).
      (pcase (funcall sub sub-content)
        ('(unsubscribe) nil)
        (_ sub))
    (error
     (message "Jupyter: I/O subscriber error: %S"
              (error-message-string error))
     ;; Keep the subscription on error.
     sub)))

;; In the context external to a publisher, i.e. in the context where a
;; message was published, the content is built up and then published.
;; In the context of a publisher, that content is filtered through
;; PUB-FN before being passed along to subscribers.  So PUB-FN is a
;; filter of content.  Subscribers receive filtered content or no
;; content at all depending on if a value wrapped by
;; `jupyter-send-content' is returned by PUB-FN or not.
(defun jupyter-publisher (&optional pub-fn)
  "Return a publisher that publishes content to subscribers.
PUB-FN is a function that takes a normal value and produces
content to send to the publisher's subscribers (by returning the
result of `jupyter-send-content' on a value).  If no content is
sent by PUB-FN, no content is sent to subscribers.  The default
for PUB-FN is `jupyter-send-content'.

Ex. Publish the value 1 regardless of what is given to PUB-FN.

    (jupyter-publisher
      (lambda (_)
        (jupyter-send-content 1)))

Ex. Publish 'app if 'app is given to a publisher, nothing is sent
    to subscribers otherwise.  In this case, a publisher is a
    filter of the value given to it for publishing.

    (jupyter-publisher
      (lambda (value)
        (if (eq value 'app)
          (jupyter-send-content value))))"
  (declare (indent 0))
  ;; Publishing functions take normal values and return content to
  ;; send.  Publishers publish that content to subscribers.  A
  ;; publisher's context is its subscribers, the list is maintained
  ;; outside of the normal, functional, context.
  (let ((subs '())
        (pub-fn (or pub-fn #'jupyter-send-content)))
    ;; A publisher value is either a value representing a subscriber
    ;; or a value representing content to send to subscribers.
    (lambda (pub-value)
      (pcase pub-value
        ;; Unbox the content given to a publisher.  If the result of
        ;; evaluating PUB-FN on the content is also content, deliver
        ;; it to the subscribers.
        (`(content ,content)
         (let ((sub-content (funcall pub-fn content)))
           ;; Only published content is sent to subscribers.  So
           ;; SUB-CONTENT may be content.
           (when (eq (car-safe sub-content) 'content)
             (setq subs
                   (delq nil (mapcar
                              (lambda (sub)
                                (jupyter--deliver sub-content sub))
                              subs))))))
        (`(subscribe ,sub) (cl-pushnew sub subs))
        (_ (error "Unhandled publisher value: %s" pub-value)))
      nil)))
;; In the publisher context, subscriber content is the monadic value
;; and the monadic functions are those functions that return content
;; to send to subscribers.  A publishing function like PUB-FN is
;; actually not monadic since it does not always return content
;; (because content can be filtered).
(defun jupyter-filter-content (pub pub-fn)
  "Return a publisher subscribed to PUB's content.
The returned publisher filters content to its subscribers through
PUB-FN."
  (declare (indent 1))
  (let ((sub (jupyter-publisher pub-fn)))
    (jupyter-run-with-io pub
      (jupyter-subscribe sub))
    sub))

(defun jupyter-consume-content (pub sub-fn)
  "Return a subscriber subscribed to PUB's content.
The subscriber evaluates SUB-FN on the published content."
  (declare (indent 1))
  (let ((sub (jupyter-subscriber sub-fn)))
    (jupyter-run-with-io pub
      (jupyter-subscribe sub))
    sub))

(defsubst jupyter--subscribe (sub)
  (list 'subscribe sub))

(defun jupyter-subscribe (sub)
  "Return an I/O action that subscribes SUB to published content.
If a subscriber (or a publisher with a subscription to another
publisher) returns the result of `jupyter-unsubscribe', its
subscription is canceled.

Ex. Subscribe to a publisher and unsubscribe after receiving two
    messages.

    (let* ((msgs '())
           (pub (jupyter-publisher))
           (sub (jupyter-subscriber
                  (lambda (n)
                    (if (> n 2) (jupyter-unsubscribe)
                      (push n msgs))))))
      (jupyter-run-with-io pub
        (jupyter-subscribe sub))
      (cl-loop
       for x in '(1 2 3)
       do (jupyter-run-with-io pub
            (jupyter-publish x)))
      (reverse msgs)) ; => '(1 2)"
  (declare (indent 0))
  (make-jupyter-delayed
   :value (lambda ()
            (funcall jupyter-current-io (jupyter--subscribe sub))
            nil)))

(defun jupyter-publish (value)
  "Return an I/O action that publishes VALUE as content.
The content will be sent to the subscribers of the publisher in
whatever I/O context the action is evaluated in."
  (declare (indent 0))
  (make-jupyter-delayed
   :value (lambda ()
            (funcall jupyter-current-io (jupyter-send-content value))
            nil)))

;;; IO Event

(defun jupyter-channel-io (session)
  (let* ((channels '(:shell :iopub :stdin))
         (ch-group
          (cl-loop
           with endpoints = (jupyter-session-endpoints session)
           for ch in channels
           collect ch
           collect (list 'endpoint (plist-get endpoints ch)
                         'alive-p nil))))
    (cl-macrolet ((continue-after
                   (cond on-timeout)
                   `(jupyter-with-timeout
                        (nil jupyter-default-timeout ,on-timeout)
                      ,cond)))
      (cl-labels
          ((ch-put
            (ch prop value)
            (plist-put (plist-get ch-group ch) prop value))
           (ch-get
            (ch prop)
            (plist-get (plist-get ch-group ch) prop))
           (ch-alive-p
            (ch)
            (ch-get ch 'alive-p))
           (ch-start
            (ch)
            (unless (ch-alive-p ch)
              ;; FIXME: Bring in ioloop?  See `jupyter-kernel-process'.
              (jupyter-run-with-io ioloop
                (jupyter-do
                  (jupyter-publish
                    'start-channel ch (ch-get ch 'endpoint)
                    ;; TODO: Make this actually work. Send a
                    ;; start-channel event and pass it an IO
                    ;; context that sets the alive-p flag for
                    ;; the channel in this current IO context.
                    ;; The ioloop will send a notification to
                    ;; this I/O context if the channel dies.
                    (jupyter-subscriber
                      (lambda (alive-p)
                        (ch-put ch 'alive-p alive-p))))
                  (jupyter-return-delayed
                    (continue-after
                     (ch-alive-p ch)
                     (error "Channel not started: %s" ch)))))))
           (ch-stop
            (ch)
            (when (ch-alive-p ch)
              (jupyter-run-with-io ioloop
                (jupyter-do
                  (jupyter-publish 'stop-channel ch)
                  (jupyter-return-delayed
                    (continue-after
                     (not (ch-alive-p ch))
                     (error "Channel not stopped: %s" ch))))))))
        (list
         (jupyter-subscriber
           (lambda (msg)
             (pcase msg
               ('start
                (cl-loop
                 for ch in channels
                 do (ch-start ch)))
               ('stop
                (cl-loop
                 for ch in channels
                 do (ch-stop ch))
                (and hb (jupyter-hb-pause hb))
                (setq hb nil)))))
         (jupyter-publisher
           (lambda (_status)
             (unless hb
               (setq hb
                     (make-instance
                      'jupyter-hb-channel
                      :session session
                      :endpoint (plist-get endpoints :hb))))
             (jupyter-send-content
              (append (list :hb hb)
                      (cl-loop
                       for ch in channels
                       collect ch and collect (ch-alive-p ch)))))))))))

;;; Websocket IO

(defun jupyter--websocket-io (kernel)
  (let ((msg-pub (jupyter-publisher))
        (status-pub (jupyter-publisher)))
    (pcase-let*
        (((cl-struct jupyter-server-kernel server id) kernel)
         (ws (jupyter-api-kernel-websocket
              server id
              :custom-header-alist (jupyter-api-auth-headers server)
              :on-message
              (lambda (_ws frame)
                (pcase (websocket-frame-opcode frame)
                  ((or 'text 'binary)
                   (let* ((msg (jupyter-read-plist-from-string
                                (websocket-frame-payload frame)))
                          ;; TODO: Get rid of some of these
                          ;; explicit/implicit `intern' calls
                          (channel (intern (concat ":" (plist-get msg :channel))))
                          (msg-type (jupyter-message-type-as-keyword
                                     (jupyter-message-type msg)))
                          (parent-header (plist-get msg :parent_header)))
                     (plist-put msg :msg_type msg-type)
                     (plist-put parent-header :msg_type msg-type)
                     (jupyter-run-with-io msg-pub
                       (jupyter-publish channel msg))))
                  (_
                   (jupyter-run-with-io status-pub
                     (jupyter-publish
                       'error (websocket-frame-opcode frame)))))))))
      (list
       ;; The websocket action subscriber.
       (jupyter-subscriber
         (lambda (msg)
           (pcase msg
             (`('send ,channel ,msg-type ,content ,msg-id)
              (websocket-send-text
               ws (jupyter-encode-raw-message
                      (plist-get (websocket-client-data ws) :session) msg-type
                    :channel (substring (symbol-name channel) 1)
                    :msg-id msg-id
                    :content content)))
             ('start (websocket-ensure-connected ws))
             ('stop (websocket-close ws)))))
       ;; The websocket message publisher.
       msg-pub
       ;; The websocket status publisher.
       status-pub))))

(defun jupyter-return-websocket-io (kernel)
  "Return a list of three elements representing an I/O connection to kernel.
The returned list looks like (ACTION-SUB MSG-PUB STATUS-PUB)
where

ACTION-SUB is a subscriber of websocket actions to start, stop,
or send a Jupyter message on the websocket.

MSG-PUB is a publisher of Jupyter messages received from the
websocket.

STATUS-PUB is a publisher of status changes to the websocket.

TODO The form of content each sends/consumes."
  (cl-assert (cl-typep kernel 'jupyter-server-kernel))
  (jupyter-mlet* ((value (jupyter-do
                           (jupyter-kernel-launch kernel)
                           (jupyter--websocket kernel))))
    (pcase-let ((`(,ws ,msg-pub ,status-pub) value))
      ;; Make sure the websocket is cleaned up when it is garbage
      ;; collected.
      (plist-put (websocket-client-data ws)
                 :finalizer (make-finalizer (lambda () (websocket-close ws))))
      (jupyter-return-delayed
        (list
         ;; The websocket action subscriber.
         (jupyter-subscriber
           (lambda (msg)
             (pcase msg
               (`(send ,channel ,msg-type ,content ,msg-id)
                (websocket-send-text
                 ws (jupyter-encode-raw-message
                        (plist-get (websocket-client-data ws) :session) msg-type
                      :channel channel
                      :msg-id msg-id
                      :content content)))
               ('start (websocket-ensure-connected ws))
               ('stop (websocket-close ws)))))
         ;; The websocket message publisher.
         msg-pub
         ;; The websocket status publisher.
         status-pub)))))

;;; Request

(defun jupyter-timeout (req)
  (list 'timeout req))

(defun jupyter-idle (io-req)
  (jupyter-then io-req
    (lambda (req)
      (jupyter-return-delayed
        (if (jupyter-wait-until-idle req) req
          (jupyter-timeout req))))))
(defun jupyter-request (type &rest content)
  "Return an IO action that sends a `jupyter-request'.
TYPE is the message type of the message that CONTENT, a property
list, represents.

See `jupyter-io' for more information on IO actions."
  (declare (indent 1))
  (setq type (intern (format ":%s-request"
                             (replace-regexp-in-string "_" "-" type))))
  (jupyter-return-delayed
    (let* ((req (make-jupyter-request
                 ;; TODO: `jupyter-with-client' similar to
                 ;; `jupyter-with-io' but on a functional client.
                 :client jupyter-current-client
                 :type type
                 :content content))
           ;; TODO: Figure out if the subscribers are garbage
           ;; collected when the subscription is cancelled.
           (req-msgs-pub
            (jupyter-publisher
              (lambda (event)
                (when (jupyter-request-idle-p req)
                  (jupyter-cancel-subscription))
                (pcase (car event)
                  ((and 'message (let `(,channel . ,msg) (cdr event))
                        ;; TODO: `jupyter-message-parent-id' -> `jupyter-parent-id'
                        ;; and the like.
                        (guard (string= id (jupyter-message-parent-id msg))))
                   (cl-callf nconc (jupyter-request-messages req)
                     (list msg))
                   (when (jupyter--message-completes-request-p msg)
                     (setf (jupyter-request-idle-p req) t))
                   (jupyter-send-content msg))))))
           (ch (if (memq type '(:input-reply :input-request))
                   :stdin
                 :shell))
           (id (jupyter-request-id req)))
      (jupyter-do
        (jupyter-subscribe req-msgs-pub)
        (jupyter-publish 'send ch type content id))
      (list req req-msgs-pub))))

(provide 'jupyter-monads)

;;; jupyter-monads.el ends here

