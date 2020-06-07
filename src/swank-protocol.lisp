(in-package :cl-user)
(defpackage swank-protocol
  (:use :cl)
  (:export :connection
           :make-connection
           :connection-hostname
           :connection-port
           :connection-request-count
           :connection-package
           :connection-thread
           :connection-log-p
           :connection-logging-stream)
  (:export :connect
           :read-message-string
           :send-message-string
           :message-waiting-p
           :emacs-rex
           :request-connection-info
           :request-swank-require
           :request-init-presentations
           :request-create-repl
           :request-listener-eval
           :request-invoke-restart
           :request-throw-to-toplevel
           :request-input-string
           :request-input-string-newline
           :read-message
           :read-all-messages)
  (:documentation "Low-level implementation of a client for the Swank protocol."))
(in-package :swank-protocol)

;;; Prevent reader errors

(eval-when (:compile-toplevel :load-toplevel)
  (swank:swank-require '(swank-presentations swank-repl)))

;;; Encoding and decoding messages

(defun encode-integer (integer)
  "Encode an integer to a 0-padded 16-bit hexadecimal string."
  (format nil "~6,'0,X" integer))

(defun decode-integer (string)
  "Decode a string representing a 0-padded 16-bit hex string to an integer."
  (parse-integer string :radix 16))

;; Writing and reading messages to/from streams

(defun write-message-to-stream (stream message)
  "Write a string to a stream, prefixing it with length information for Swank."
  (let* ((length-string (encode-integer (1+ (length message))))
         (msg (concatenate 'string
                           length-string
                           message
                           (string #\Newline))))
    (write-sequence msg stream)))

(defun read-message-from-stream (stream)
  "Read a string from a string.

Parses length information to determine how many characters to read."
  (let ((length-string (make-array 6 :element-type 'character)))
    (read-sequence length-string stream)
    (let* ((length (decode-integer length-string))
             (buffer (make-array length :element-type 'character)))
      (read-sequence buffer stream)
      buffer)))

;;; Data

(defclass connection ()
  ((hostname :reader connection-hostname
             :initarg :hostname
             :type string
             :documentation "The host to connect to.")
   (port :reader connection-port
         :initarg :port
         :type integer
         :documentation "The port to connect to.")
   ;; Internal
   (socket :accessor connection-socket
           :type usocket:stream-usocket
           :documentation "The usocket socket.")
   (request-count :accessor connection-request-count
                  :initform 0
                  :type integer
                  :documentation "A number that is increased and sent along with every request.")
   (read-count :accessor connection-read-count
               :initform 0
               :type integer
               :documentation "Counter of the number of times read is called in the server's REPL.")
   (package :accessor connection-package
            :initform "COMMON-LISP-USER"
            :type string
            :documentation "The name of the connection's package.")
   (thread :accessor connection-thread
           :initform t
           :documentation "The current thread.")
   ;; Logging
   (logp :accessor connection-log-p
         :initarg :logp
         :initform nil
         :type boolean
         :documentation "Whether or not to log connection requests.")
   (logging-stream :accessor connection-logging-stream
                   :initarg :logging-stream
                   :initform *error-output*
                   :type stream
                   :documentation "The stream to log to."))
  (:documentation "A connection to a remote Lisp."))

(defun make-connection (hostname port &key (logp nil))
  "Create a connection to a remote Swank server."
  (make-instance 'connection
                 :hostname hostname
                 :port port
                 :logp logp))

(defmethod connect ((connection connection))
  "Connect to the remote server. Returns t."
  (with-slots (hostname port) connection
    (let ((socket (usocket:socket-connect hostname
                                          port
                                          :element-type 'character)))
      (setf (connection-socket connection) socket)))
  t)

(defun log-message (connection format-string &rest arguments)
  "Log a message."
  (when (connection-log-p connection)
    (apply #'format (cons (connection-logging-stream connection)
                          (cons format-string
                                arguments)))))

(defun read-message-string (connection)
  "Read a message string from a Swank connection.

This function will block until it reads everything. Consider message-waiting-p
to check if input is available."
  (with-slots (socket) connection
    (let ((stream (usocket:socket-stream socket)))
      (when (usocket:wait-for-input socket :timeout 5)
        (let ((msg (read-message-from-stream stream)))
          (log-message connection "~%Read: ~A~%" msg)
          msg)))))

(defun send-message-string (connection message)
  "Send a message string to a Swank connection."
  (with-slots (socket) connection
    (let ((stream (usocket:socket-stream socket)))
      (write-message-to-stream stream message)
      (force-output stream)
      (log-message connection "~%Sent: ~A~%" message)
      message)))

(defun message-waiting-p (connection)
  "t if there's a message in the connection waiting to be read, nil otherwise."
  (if (usocket:wait-for-input (connection-socket connection)
                              :ready-only t
                              :timeout 0)
      t
      nil))

;;; Sending messages

(defmacro with-swank-syntax (() &body body)
  `(with-standard-io-syntax
     (let ((*package* (find-package :swank-io-package))
           (*print-case* :downcase)
           (*print-readably* nil))
       ,@body)))

(defun emacs-rex (connection form)
  "(R)emote (E)xecute S-e(X)p.

Send an S-expression command to Swank to evaluate. The resulting response must
be read with read-response."
  (with-slots (package thread) connection
    (let ((msg (concatenate 'string
                            "(:emacs-rex "
                            (with-swank-syntax ()
                              (prin1-to-string form))
                            " "
                            (prin1-to-string package)
                            " "
                            (if (eq (first form)
                                    'swank-repl:listener-eval)
                                ":repl-thread"
                                (prin1-to-string thread))
                            " "
                            (write-to-string
                             (incf (connection-request-count connection)))
                            ")")))
      (send-message-string connection msg))))

(defun request-connection-info (connection)
  "Request that Swank provide connection information."
  (emacs-rex connection `(swank:connection-info)))

(defun request-swank-require (connection requirements)
  "Request that the Swank server load contrib modules. `requirements` must be a list of symbols, e.g. '(swank-repl swank-media)."
  (emacs-rex connection
             `(swank:swank-require ',(loop for item in requirements collecting
                                       (intern (symbol-name item)
                                               (find-package :swank-io-package))))))

(defun request-init-presentations (connection)
  "Request that Swank initiate presentations."
  (emacs-rex connection `(swank:init-presentations)))

(defun request-create-repl (connection)
  "Request that Swank create a new REPL."
  (prog1
      (emacs-rex connection `(swank-repl:create-repl nil :coding-system "utf-8-unix"))
    (setf (connection-thread connection) 1)))

(defun request-listener-eval (connection string)
  "Request that Swank evaluate a string of code in the REPL."
  (emacs-rex connection `(swank-repl:listener-eval ,string)))

(defun request-invoke-restart (connection debug-level restart-number)
  "Invoke a restart."
  (emacs-rex connection `(swank:invoke-nth-restart-for-emacs ,debug-level
                                                             ,restart-number)))

(defun request-throw-to-toplevel (connection)
  "Leave the debugger."
  (emacs-rex connection `(swank:throw-to-toplevel)))

(defun request-input-string (connection string)
  "Send a string to the server's standard input."
  (with-slots (package thread) connection
    (let ((msg (concatenate 'string
                            "(:emacs-return-string "
                            (prin1-to-string
                             (connection-thread connection))
                            " "
                            (prin1-to-string
                             (incf (connection-read-count connection)))
                            " "
                            (prin1-to-string string)
                            ")")))
      (send-message-string connection msg))))

(defun request-input-string-newline (connection string)
  "Send a string to the server's standard input with a newline at the end."
  (request-input-string connection
                        (concatenate 'string
                                     string
                                     (string #\Newline))))

;;; Reading/parsing messages

(defun read-message (connection)
  "Read an arbitrary message from a connection."
  (with-swank-syntax ()
    (read-from-string (read-message-string connection))))

(defun read-all-messages (connection)
  (loop while (message-waiting-p connection) collecting
    (read-message connection)))
