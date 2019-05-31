;;; jupyter-server.el --- Support for the Jupyter kernel servers -*- lexical-binding: t -*-

;; Copyright (C) 2019 Nathaniel Nicandro

;; Author: Nathaniel Nicandro <nathanielnicandro@gmail.com>
;; Created: 02 Apr 2019
;; Version: 0.8.0

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

;; Overview of implementation
;;
;; A `jupyter-server' communicates with a Jupyter kernel server (either the
;; notebook or a kernel gateway) via the Jupyter REST API. Given the URL and
;; Websocket URL for the server, the `jupyter-server' object can launch kernels
;; using the function `jupyter-server-start-new-kernel'. The kernelspecs
;; available on the server can be accessed by calling
;; `jupyter-server-kernelspecs'.
;;
;; `jupyter-server-start-new-kernel' returns a list (KM KC) where KM is a
;; `jupyter-server-kernel-manager' and KC is a kernel client that can
;; communicate with the kernel managed by KM. `jupyter-server-kernel-manager'
;; sends requests to the server using the `jupyter-server' object to manage the
;; lifetime of the kernel and ensures that a websocket is opened so that kernel
;; clients created using `jupyter-make-client' can communicate with the kernel.
;;
;; Communication with the channels of the kernels that are launched on the
;; `jupyter-server' is established via a `jupyter-server-ioloop' which
;; multiplexes the channels of all the kernel servers. The kernel ID the server
;; associated with a kernel can then be used to filter messages for a
;; particular kernel and to send messages to a kernel through the
;; `jupyter-server-ioloop'.
;;
;; `jupyter-server-kernel-comm' is a `jupyter-comm-layer' that handles the
;; communication of a client with a server kernel. The job of the
;; `jupyter-server-kernel-comm' is to connect to the `jupyter-server's event
;; stream and filter the messages to handle those of a particular kernel
;; identified by kernel ID.
;;
;; Starting REPLs
;;
;; You can launch kernels without connecting clients to them by using
;; `jupyter-server-launch-kernel'. To connect a REPL to a launched kernel use
;; `jupyter-connect-server-repl'. To both launch and connect a REPL use
;; `jupyter-run-server-repl'. All of the previous commands determine the server
;; to use by using the `jupyter-current-server' function, which see.
;;
;; Managing kernels on a server
;;
;; To get an overview of all live kernels on a server you can call
;; `jupyter-server-list-kernels'. From the buffer displayed there are a number
;; of keys bound that enable you to manage the kernels on the server. See
;; `jupyter-server-kernel-list-mode-map'.
;;
;; TODO: Find where it would be appropriate to call `delete-instance' on a
;;`jupyter-server' that does not have any websockets open, clients connected,
;; or HTTP connections open, or is not bound to `jupyter-current-server' in any
;; buffer.
;;
;; TODO: Naming kernels in `jupyter-server-list-kernels' instead of using their
;; ID. The kernel ID is not very useful to quickly identify which kernel does
;; what, it would be more useful to be able to associate a name with a kernel
;; ID.

;;; Code:

(eval-when-compile (require 'subr-x))
(require 'jupyter-repl)
(require 'jupyter-rest-api)
(require 'jupyter-kernel-manager)
(require 'jupyter-ioloop-comm)
(require 'jupyter-server-ioloop)

(defgroup jupyter-server nil
  "Support for the Jupyter kernel gateway"
  :group 'jupyter)

(defvar-local jupyter-current-server nil
  "The `jupyter-server' associated with the current buffer.
Used in, e.g. a `jupyter-server-kernel-list-mode' buffer.")

(put 'jupyter-current-server 'permanent-local t)

;;; Plumbing

(defvar jupyter--servers nil)

(defclass jupyter-server (jupyter-rest-client
                          jupyter-ioloop-comm
                          eieio-instance-tracker)
  ((tracking-symbol :initform 'jupyter--servers)
   (kernelspecs
    :type json-plist
    :initform nil
    :documentation "Kernelspecs for the kernels available behind this gateway.
Access should be done through `jupyter-available-kernelspecs'.")))

;; TODO: When to `delete-instance'? Or define a function so that the user can
;; do so.
(defun jupyter-servers ()
  "Return a list of all `jupyter-server's."
  jupyter--servers)

;; TODO: Add the server as a slot
(defclass jupyter-server-kernel (jupyter-meta-kernel)
  ((id
    :type string
    :initarg :id
    :documentation "The kernel ID.")))

(cl-defmethod jupyter-kernel-alive-p ((kernel jupyter-server-kernel))
  (slot-boundp kernel 'id))

(cl-defmethod jupyter-start-kernel ((kernel jupyter-server-kernel) server &rest _ignore)
  (cl-check-type server jupyter-server)
  (with-slots (spec) kernel
    (jupyter-server--verify-kernelspec server spec)
    (cl-destructuring-bind (&key id &allow-other-keys)
        (jupyter-api-start-kernel server (car spec))
      (oset kernel id id))))

(cl-defmethod jupyter-kill-kernel ((kernel jupyter-server-kernel))
  (cl-call-next-method)
  (slot-makeunbound kernel 'id))

(defclass jupyter-server-kernel-comm (jupyter-comm-layer)
  ((server :type jupyter-server :initarg :server)
   (kernel :type jupyter-server-kernel :initarg :kernel)))

(cl-defmethod jupyter-comm-id ((comm jupyter-server-kernel-comm))
  (format "kid=%s" (truncate-string-to-width
                    (thread-first comm
                      (oref kernel)
                      (oref id))
                    9 nil nil "…")))

;;;; `jupyter-server' events

(cl-defmethod jupyter-event-handler ((comm jupyter-server)
                                     (event (head disconnect-channels)))
  (let ((kernel-id (cadr event)))
    (jupyter-comm-client-loop comm client
      (when (equal kernel-id (oref (oref client kernel) id))
        (jupyter-comm-stop client)))
    (with-slots (ioloop) comm
      (cl-callf2 remove kernel-id
                 (process-get (oref ioloop process) :kernel-ids)))))

(cl-defmethod jupyter-event-handler ((comm jupyter-server)
                                     (event (head connect-channels)))
  (let ((kernel-id (cadr event)))
    (with-slots (ioloop) comm
      (cl-callf append (process-get (oref ioloop process) :kernel-ids)
        (list kernel-id)))))

(cl-defmethod jupyter-event-handler ((comm jupyter-server) event)
  "Send EVENT to all clients connected to COMM.
Each client must have a KERNEL slot which, in turn, must have an
ID slot. The second element of EVENT is expected to be a kernel
ID. Send EVENT, with the kernel ID excluded, to a client whose
kernel has a matching ID."
  (let ((kernel-id (cadr event)))
    (setq event (cons (car event) (cddr event)))
    (jupyter-comm-client-loop comm client
      (when (equal kernel-id (oref (oref client kernel) id))
        ;; TODO: Since the event handlers of CLIENT will eventually call the
        ;; `jupyter-handle-message' of a `jupyter-kernel-client' we really
        ;; don't need to do any filtering based off of a `jupyter-session-id',
        ;; but maybe should? The `jupyter-handle-message' method will only
        ;; handle messages that have a parent ID of a previous request so there
        ;; already is filtering at the kernel client level. I wonder if there
        ;; is any issue with having an empty session ID in the messages sent by
        ;; the `jupyter-server-ioloop', see `jupyter-server--dummy-session'.
        (jupyter-event-handler client event)))))

;;;; `jupyter-server' methods

(cl-defmethod jupyter-comm-start ((comm jupyter-server))
  (unless (and (slot-boundp comm 'ioloop)
               (jupyter-ioloop-alive-p (oref comm ioloop)))
    ;; TODO: Is a write to the cookie file and then a read of the cookie file
    ;; whenever connecting a websocket in a subprocess good enough? If, e.g.
    ;; the notebook is restarted and it clears the login information, there are
    ;; sometimes error due to `jupyter-api-request' trying to ask for login
    ;; information which look like "wrong type argument listp, [http://...]".
    ;; They don't seem to happens with the changes mentioned, but is it enough?
    (url-cookie-write-file)
    (oset comm ioloop (jupyter-server-ioloop
                       :url (oref comm url)
                       :ws-url (oref comm ws-url)
                       :ws-headers (jupyter-api-auth-headers comm)))
    (cl-call-next-method)))

(cl-defmethod jupyter-connect-client ((comm jupyter-server)
                                      (kcomm jupyter-server-kernel-comm))
  (with-slots (id) (oref kcomm kernel)
    (cl-call-next-method)
    (jupyter-send comm 'connect-channels id)
    (unless (jupyter-ioloop-wait-until (oref comm ioloop)
                'connect-channels #'identity)
      (error "Timeout when connecting websocket to kernel id %s" id))))

(cl-defmethod jupyter-server-kernel-connected-p ((comm jupyter-server) id)
  "Return non-nil if COMM has a WebSocket connection to a kernel with ID."
  (and (jupyter-comm-alive-p comm)
       (member id (process-get (oref (oref comm ioloop) process) :kernel-ids))))

(defun jupyter-server--verify-kernelspec (server spec)
  (cl-destructuring-bind (name _ . kspec) spec
    (let ((server-spec (assoc name (jupyter-server-kernelspecs server))))
      (unless server-spec
        (error "No kernelspec matching %s on server @ %s"
               name (oref server url)))
      (when (cl-loop
             with sspec = (cddr server-spec)
             for (k v) on sspec by #'cddr
             thereis (not (equal (plist-get kspec k) v)))
        (error "%s kernelspec doesn't match one on server @ %s"
               name (oref server url))))))

(cl-defmethod jupyter-server-kernelspecs ((server jupyter-server) &optional refresh)
  "Return the kernelspecs on SERVER.
By default the available kernelspecs are cached. To force an
update of the cached kernelspecs, give a non-nil value to
REFRESH.

The kernelspecs are returned in the same form as returned by
`jupyter-available-kernelspecs'."
  (when (or refresh (null (oref server kernelspecs)))
    (let ((specs (jupyter-api-get-kernelspec server)))
      (unless specs
        (error "Can't retrieve kernelspecs from server @ %s" (oref server url)))
      (oset server kernelspecs specs)
      (plist-put (oref server kernelspecs) :kernelspecs
                 (cl-loop
                  with specs = (plist-get specs :kernelspecs)
                  for (_ spec) on specs by #'cddr
                  ;; Uses the same format as `jupyter-available-kernelspecs'
                  ;;     (name dir . spec)
                  collect (cons (plist-get spec :name)
                                (cons nil (plist-get spec :spec)))))))
  (plist-get (oref server kernelspecs) :kernelspecs))

;;;; `jupyter-server-kernel-comm' methods

(cl-defmethod jupyter-comm-start ((comm jupyter-server-kernel-comm) &rest _ignore)
  "Register COMM to receive server events.
If SERVER receives events that have the same kernel ID as the
kernel associated with COMM, then COMM's `jupyter-event-handler'
will receive those events."
  (with-slots (server) comm
    (jupyter-comm-start server)
    (jupyter-connect-client server comm)))

(cl-defmethod jupyter-comm-stop ((comm jupyter-server-kernel-comm) &rest _ignore)
  "Disconnect COMM from receiving server events."
  (jupyter-disconnect-client (oref comm server) comm))

(cl-defmethod jupyter-send ((comm jupyter-server-kernel-comm) event-type &rest event)
  "Use COMM to send an EVENT to the server with type, EVENT-TYPE.
SERVER will direct EVENT to the right kernel based on the kernel
ID of the kernel associated with COMM."
  (with-slots (server kernel) comm
    (apply #'jupyter-send server event-type (oref kernel id) event)))

(cl-defmethod jupyter-comm-alive-p ((comm jupyter-server-kernel-comm))
  "Return non-nil if COMM can receive server events for its associated kernel."
  (and (jupyter-server-kernel-connected-p
        (oref comm server)
        (oref (oref comm kernel) id))
       (catch 'member
         (jupyter-comm-client-loop (oref comm server) client
           (when (eq client comm)
             (throw 'member t))))))

;; TODO: Remove the need for these methods, they are remnants from an older
;; implementation. They will need to be removed from `jupyter-kernel-client'.
(cl-defmethod jupyter-channel-alive-p ((comm jupyter-server-kernel-comm) _channel)
  (jupyter-comm-alive-p comm))

(cl-defmethod jupyter-channels-running-p ((comm jupyter-server-kernel-comm))
  (jupyter-comm-alive-p comm))

;;;; `jupyter-server-kernel-manager'

(defclass jupyter-server-kernel-manager (jupyter-kernel-manager-base)
  ((server :type jupyter-server :initarg :server)
   (kernel :type jupyter-server-kernel :initarg :kernel)
   (comm :type jupyter-server-kernel-comm)))

(cl-defmethod jupyter-kernel-alive-p ((manager jupyter-server-kernel-manager))
  (with-slots (server kernel) manager
    (and (jupyter-kernel-alive-p kernel)
         (ignore-errors (jupyter-api-get-kernel server (oref kernel id))))))

(cl-defmethod jupyter-start-kernel ((manager jupyter-server-kernel-manager) &rest _ignore)
  "Ensure that the gateway can receive events from its kernel."
  (with-slots (server kernel) manager
    (jupyter-start-kernel kernel server)))

(cl-defmethod jupyter-interrupt-kernel ((manager jupyter-server-kernel-manager))
  (with-slots (server kernel) manager
    (jupyter-api-interrupt-kernel server (oref kernel id))))

(cl-defmethod jupyter-kill-kernel ((manager jupyter-server-kernel-manager))
  (jupyter-shutdown-kernel manager))

;; TODO: Figure out if restarting a kernel keeps the kernel ID
(cl-defmethod jupyter-shutdown-kernel ((manager jupyter-server-kernel-manager) &optional restart _timeout)
  (with-slots (server kernel comm) manager
    (if restart (jupyter-api-restart-kernel server (oref kernel id))
      (when (jupyter-comm-alive-p server)
        ;; Stop the communication of a `jupyter-server' with
        ;; `jupyter-server-kernel-comm's that have the associated kernel ID.
        (jupyter-send server 'disconnect-channels (oref kernel id)))
      (when (jupyter-kernel-alive-p manager)
        (jupyter-api-shutdown-kernel server (oref kernel id))))))

(cl-defmethod jupyter-make-client ((manager jupyter-server-kernel-manager) _class &rest _slots)
  (let ((client (cl-call-next-method)))
    (prog1 client
      (unless (slot-boundp manager 'comm)
        (oset manager comm (jupyter-server-kernel-comm
                            :kernel (oref manager kernel)
                            :server (oref manager server)))
        (jupyter-comm-start (oref manager comm)))
      (oset client kcomm (oref manager comm)))))

;;; Finding exisisting kernel managers and servers

(defun jupyter-server-find-manager (server id)
  "Return a kernel manager managing kernel with ID on SERVER.
Return nil if none could be found."
  (cl-loop
   for manager in (jupyter-kernel-managers)
   thereis (and (cl-typep manager 'jupyter-server-kernel-manager)
                (eq (oref manager server) server)
                (jupyter-kernel-alive-p manager)
                (equal (oref (oref manager kernel) id) id)
                manager)))

(defun jupyter-find-server (url &optional ws-url)
  "Return a live `jupyter-server' that lives at URL.
Finds a server that matches both URL and WS-URL. When WS-URL the
default set by `jupyter-rest-client' is used.

Return nil if no `jupyter-server' could be found."
  (with-slots (url ws-url)
      (apply #'make-instance 'jupyter-rest-client
             (append (list :url url)
                     (when ws-url (list :ws-url ws-url))))
    (cl-loop for server in (jupyter-servers)
             thereis (and (equal (oref server url) url)
                          (equal (oref server ws-url) ws-url)
                          server))))

;;; Helpers for commands

(defun jupyter-completing-read-server-kernel (server)
  "Use `completing-read' to select a kernel on SERVER.
A model of the kernel is returned as a property list and has at
least the following keys:

- :id :: The ID used to identify the kernel on the server
- :last_activity :: The last channel activity of the kernel
- :name :: The kernelspec name used to start the kernel
- :execution_state :: The status of the kernel
- :connections :: The number of websocket connections for the kernel"
  (let* ((kernels (jupyter-api-get-kernel server))
         (display-names
          (if (null kernels) (error "No kernels @ %s" (oref server url))
            (mapcar (lambda (k)
                 (cl-destructuring-bind
                     (&key name id last_activity &allow-other-keys) k
                   (concat name " (last activity: " last_activity ", id: " id ")")))
               kernels)))
         (name (completing-read "kernel: " display-names nil t)))
    (when (equal name "")
      (error "No kernel selected"))
    (nth (- (length display-names)
            (length (member name display-names)))
         (append kernels nil))))

(defun jupyter-current-server (&optional ask)
  "Return an existing `jupyter-server' or a new one.
If `jupyter-current-server' is non-nil, return its value.
Otherwise, return the most recently used server.

With a prefix argument, ASK to select one and set the selected
one as the most recently used.

If no servers exist, ask the user to create one and return its
value."
  (interactive "P")
  (let ((read-url-make-server
         (lambda ()
           (let ((url (read-string "Server URL: " "http://localhost:8888"))
                 (ws-url (read-string "Websocket URL: " "ws://localhost:8888")))
             (or (jupyter-find-server url ws-url)
                 (jupyter-server :url url :ws-url ws-url))))))
    (if ask (let ((server (funcall read-url-make-server)))
              (prog1 server
                (setq jupyter--servers
                      (cons server (delq server jupyter--servers)))))
      (or jupyter-current-server
          (and (file-remote-p default-directory)
               (jupyter-tramp-file-name-p default-directory)
               (jupyter-tramp-server-from-file-name default-directory))
          (if (> (length jupyter--servers) 1)
              (let ((server (cdr (completing-read
                                  "Jupyter Server: "
                                  (mapcar (lambda (x) (cons (oref x url) x))
                                     jupyter--servers)))))
                (prog1 server
                  (setq jupyter--servers
                        (cons server (delq server jupyter--servers)))))
            (or (car jupyter--servers)
                (funcall read-url-make-server)))))))

;;; Commands

;;;###autoload
(defun jupyter-server-launch-kernel (server)
  "Start a kernel on SERVER.

With a prefix argument, ask to select a server if there are
mutiple to choose from, otherwise the most recently used server
is used as determined by `jupyter-current-server'."
  (interactive (list (jupyter-current-server current-prefix-arg)))
  (let* ((specs (jupyter-server-kernelspecs server))
         (spec (jupyter-completing-read-kernelspec specs)))
    (jupyter-api-start-kernel server (car spec))))

;;; REPL

;; TODO: When closing the REPL buffer and it is the last connected client as
;; shown by the :connections key of a `jupyter-api-get-kernel' call, ask to
;; also shutdown the kernel.
;;
;; TODO: When calling `jupyter-stop-channels' and there is only one client to a
;; `jupyter-server-kernel-comm', tell the `jupyter-server-ioloop' to disconnect
;; the channels.
(defun jupyter-server-start-new-kernel (server kernel-name &optional client-class)
  "Start a managed Jupyter kernel on SERVER.
KERNEL-NAME is the name of the kernel to start. It can also be
the prefix of a valid kernel name, in which case the first kernel
in ‘jupyter-server-kernelspecs’ that has KERNEL-NAME as a
prefix will be used.

Optional argument CLIENT-CLASS is a subclass
of ‘jupyer-kernel-client’ and will be used to initialize a new
client connected to the kernel. CLIENT-CLASS defaults to the
symbol ‘jupyter-kernel-client’.

Return a list (KM KC) where KM is the kernel manager managing the
lifetime of the kernel on SERVER. KC is a new client connected to
the kernel whose class is CLIENT-CLASS. Note that the client’s
‘manager’ slot will also be set to the kernel manager instance,
see ‘jupyter-make-client’."
  (or client-class (setq client-class 'jupyter-kernel-client))
  (let* ((specs (jupyter-server-kernelspecs server))
         (kernel (jupyter-server-kernel
                  :spec (jupyter-guess-kernelspec kernel-name specs)))
         (manager (jupyter-server-kernel-manager
                   :server server
                   :kernel kernel)))
    ;; Needs to be started before calling `jupyter-make-client' since that
    ;; method will send a request to start a websocket channel to the kernel.
    ;; FIXME: This should be done in a `jupyter-initialize-connection' method,
    ;; but first that method needs to be generalize in `jupyter-client.el'
    (unless (jupyter-kernel-alive-p manager)
      (jupyter-start-kernel manager))
    (let ((client (jupyter-make-client manager client-class)))
      (jupyter-start-channels client)
      (list manager client))))

;;;###autoload
(defun jupyter-run-server-repl
    (server kernel-name &optional repl-name associate-buffer client-class display)
  "On SERVER start a kernel with KERNEL-NAME.

With a prefix argument, ask to select a server if there are
mutiple to choose from, otherwise the most recently used server
is used as determined by `jupyter-current-server'.

REPL-NAME, ASSOCIATE-BUFFER, CLIENT-CLASS, and DISPLAY all have
the same meaning as in `jupyter-run-repl'."
  (interactive
   (let ((server (jupyter-current-server current-prefix-arg)))
     (list server
           (car (jupyter-completing-read-kernelspec
                 (jupyter-server-kernelspecs server)))
           ;; FIXME: Ambiguity with `jupyter-current-server' and
           ;; `current-prefix-arg'
           (when (and current-prefix-arg
                      (y-or-n-p "Name REPL? "))
             (read-string "REPL Name: "))
           t nil t)))
  (or client-class (setq client-class 'jupyter-repl-client))
  (jupyter-error-if-not-client-class-p client-class 'jupyter-repl-client)
  (cl-destructuring-bind (_manager client)
      (jupyter-server-start-new-kernel server kernel-name client-class)
    (jupyter-bootstrap-repl client repl-name associate-buffer display)))

;;;###autoload
(defun jupyter-connect-server-repl
    (server kernel-id &optional repl-name associate-buffer client-class display)
  "On SERVER, connect to the kernel with KERNEL-ID.

With a prefix argument, ask to select a server if there are
mutiple to choose from, otherwise the most recently used server
is used as determined by `jupyter-current-server'.

REPL-NAME, ASSOCIATE-BUFFER, CLIENT-CLASS, and DISPLAY all have
the same meaning as in `jupyter-connect-repl'."
  (interactive
   (let ((server (jupyter-current-server current-prefix-arg)))
     (list server
           (plist-get (jupyter-completing-read-server-kernel server) :id)
           ;; FIXME: Ambiguity with `jupyter-current-server' and
           ;; `current-prefix-arg'
           (when (and current-prefix-arg
                      (y-or-n-p "Name REPL? "))
             (read-string "REPL Name: "))
           t nil t)))
  (or client-class (setq client-class 'jupyter-repl-client))
  (jupyter-error-if-not-client-class-p client-class 'jupyter-repl-client)
  (let* ((specs (jupyter-server-kernelspecs server))
         (manager
          (or (jupyter-server-find-manager server kernel-id)
              (let* ((model (jupyter-api-get-kernel server kernel-id))
                     (kernel (jupyter-server-kernel
                              :id kernel-id
                              :spec (assoc (plist-get model :name) specs))))
                (jupyter-server-kernel-manager
                 :server server
                 :kernel kernel))))
         (client (jupyter-make-client manager client-class)))
    (jupyter-start-channels client)
    (jupyter-bootstrap-repl client repl-name associate-buffer display)))

;;; `jupyter-server-kernel-list'

(defun jupyter-server-kernel-list-do-shutdown ()
  "Shutdown the kernel corresponding to the current entry."
  (interactive)
  (when-let* ((id (tabulated-list-get-id))
              (really (yes-or-no-p
                       (format "Really shutdown %s kernel? "
                               (aref (tabulated-list-get-entry) 0)))))
    (let ((manager (jupyter-server-find-manager jupyter-current-server id)))
      (if manager (jupyter-shutdown-kernel manager)
        (jupyter-api-shutdown-kernel jupyter-current-server id)))
    (tabulated-list-delete-entry)))

(defun jupyter-server-kernel-list-do-restart ()
  "Restart the kernel corresponding to the current entry."
  (interactive)
  (when-let* ((id (tabulated-list-get-id))
              (really (yes-or-no-p "Really restart kernel? ")))
    (let ((manager (jupyter-server-find-manager jupyter-current-server id)))
      (if manager (jupyter-shutdown-kernel manager 'restart)
        (jupyter-api-restart-kernel jupyter-current-server id)))
    (revert-buffer)))

(defun jupyter-server-kernel-list-do-interrupt ()
  "Interrupt the kernel corresponding to the current entry."
  (interactive)
  (when-let* ((id (tabulated-list-get-id)))
    (jupyter-api-interrupt-kernel jupyter-current-server id)
    (revert-buffer)))

(defun jupyter-server-kernel-list-new-repl ()
  "Connect a REPL to the kernel corresponding to the current entry."
  (interactive)
  (when-let* ((id (tabulated-list-get-id)))
    (let ((jupyter-current-client
           (jupyter-connect-server-repl jupyter-current-server id)))
      (revert-buffer)
      (jupyter-repl-pop-to-buffer))))

(defun jupyter-server-kernel-list-launch-kernel ()
  "Launch a new kernel on the server."
  (interactive)
  (jupyter-server-launch-kernel jupyter-current-server)
  (revert-buffer))

(defvar jupyter-server-kernel-list-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-i") #'jupyter-server-kernel-list-do-interrupt)
    (define-key map (kbd "d") #'jupyter-server-kernel-list-do-shutdown)
    (define-key map (kbd "C-c C-d") #'jupyter-server-kernel-list-do-shutdown)
    (define-key map (kbd "C-c C-r") #'jupyter-server-kernel-list-do-restart)
    (define-key map [follow-link] nil) ;; allows mouse-1 to be activated
    (define-key map [mouse-1] #'jupyter-server-kernel-list-new-repl)
    (define-key map (kbd "RET") #'jupyter-server-kernel-list-new-repl)
    (define-key map (kbd "C-RET") #'jupyter-server-kernel-list-launch-kernel)
    (define-key map (kbd "<return>") #'jupyter-server-kernel-list-new-repl)
    (define-key map (kbd "C-<return>") #'jupyter-server-kernel-list-launch-kernel)
    (define-key map "r" #'revert-buffer)
    (define-key map "g" #'revert-buffer)
    map))

(define-derived-mode jupyter-server-kernel-list-mode
  tabulated-list-mode "Jupyter Server Kernels"
  "A list of live kernels on a Jupyter kernel server."
  (tabulated-list-init-header)
  (tabulated-list-print)
  (let ((inhibit-read-only t)
        (url (oref jupyter-current-server url)))
    (overlay-put
     (make-overlay 1 2)
     'before-string
     (concat (propertize url 'face '(fixed-pitch default)) "\n"))))

(defun jupyter-server--kernel-list-format ()
  (let* ((get-time
          (lambda (a)
            (or (get-text-property 0 'jupyter-time a)
                (let ((time (jupyter-decode-time a)))
                  (prog1 time
                    (put-text-property 0 1 'jupyter-time time a))))))
         (time-sort
          (lambda (a b)
            (time-less-p
             (funcall get-time (aref (nth 1 a) 2))
             (funcall get-time (aref (nth 1 b) 2)))))
         (conn-sort
          (lambda (a b)
            (< (string-to-number (aref (nth 1 a) 4))
               (string-to-number (aref (nth 1 b) 4))))))
    `[("Name" 17 t)
      ("ID" 38 nil)
      ("Activity" 20 ,time-sort)
      ("State" 10 nil)
      ("Conns." 6 ,conn-sort)]))

(defun jupyter-server--kernel-list-entries ()
  (cl-loop
   with names = nil
   for kernel across (jupyter-api-get-kernel jupyter-current-server)
   collect
   (cl-destructuring-bind
       (&key name id last_activity execution_state
             connections &allow-other-keys)
       kernel
     (let* ((time (jupyter-decode-time last_activity))
            (name
             (let ((same (cl-remove-if-not
                          (lambda (x) (string-prefix-p name x)) names)))
               (when same (setq name (format "%s<%d>" name (length same))))
               (push name names)
               (propertize name 'face 'font-lock-constant-face)))
            (activity (propertize (format-time-string "%F %T" time)
                                  'face 'font-lock-doc-face))
            (conns (propertize (number-to-string connections)
                               'face 'shadow))
            (state (propertize execution_state
                               'face (pcase execution_state
                                       ("busy" 'warning)
                                       ("idle" 'shadow)
                                       ("starting" 'success)))))
       (list id (vector name id activity state conns))))))

;;;###autoload
(defun jupyter-server-list-kernels (server)
  "Display a list of live kernels on SERVER."
  (interactive (list (jupyter-current-server current-prefix-arg)))
  (if (zerop (length (jupyter-api-get-kernel server)))
      (when (yes-or-no-p (format "No kernels at %s; launch one? "
                                 (oref server url)))
        (jupyter-server-launch-kernel server)
        (jupyter-server-list-kernels server))
    (with-current-buffer
        (jupyter-get-buffer-create (format "kernels[%s]" (oref server url)))
      (setq jupyter-current-server server)
      (if (eq major-mode 'jupyter-server-kernel-list-mode)
          (revert-buffer)
        (setq tabulated-list-format (jupyter-server--kernel-list-format)
              tabulated-list-entries #'jupyter-server--kernel-list-entries)
        (jupyter-server-kernel-list-mode)
        ;; So that `dired-jump' will visit the directory of the kernel server.
        (setq default-directory
              (jupyter-tramp-file-name-from-url (oref server url))))
      (jupyter-display-current-buffer-reuse-window))))

(provide 'jupyter-server)

;;; jupyter-server.el ends here