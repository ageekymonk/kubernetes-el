;;; kubernetes-pods-list.el --- Displays pods.  -*- lexical-binding: t; -*-
;;; Commentary:
;;; Code:

(require 'dash)

(require 'kubernetes-ast)
(require 'kubernetes-config)
(require 'kubernetes-state)
(require 'kubernetes-yaml)


;; Helper functions

(defun kubernetes-pods-list--parse-utc-timestamp (timestamp)
  "Parse TIMESTAMP string from the API into the representation used by Emacs."
  (let ((parsed (parse-time-string
                 (->> timestamp
                      (replace-regexp-in-string ":" "")
                      (replace-regexp-in-string "T" " " )
                      (replace-regexp-in-string "+" " +")))))
    (--map (or it 0) parsed)))

(defun kubernetes-pods-list--time-diff-string (start now)
  "Find the interval between START and NOW, and return a string of the coarsest unit."
  (let ((diff (time-to-seconds (time-subtract now start))))
    (car (split-string (format-seconds "%yy,%dd,%hh,%mm,%ss%z" diff) ","))))

(defun kubernetes-pods-list-display-pod (pod-name)
  "Show the pod with string POD-NAME at point in a pop-up buffer."
  (interactive (list (get-text-property (point) 'kubernetes-pod-name)))
  (unless pod-name
    (user-error "No pod name at point"))

  (-if-let ((&hash (intern pod-name) pod) (kubernetes-state-pods))
      (when-let (win (display-buffer (kubernetes-yaml-make-buffer pod-name pod)))
        (select-window win))
    (user-error "Pod %s not found and may have been deleted" pod-name)))

(defun kubernetes-pods-list--sorted-keys (ht)
  (-sort (lambda (l r) (string< (symbol-name l) (symbol-name r)))
         (hash-table-keys ht)))


;; Keymaps

(defconst kubernetes-pod-name-map
  (let ((keymap (make-sparse-keymap)))
    (define-key keymap (kbd "RET") #'kubernetes-pods-list-display-pod)
    (define-key keymap [mouse-1] #'kubernetes-pods-list-display-pod)
    keymap))


;; Components

(kubernetes-ast-define-component pod-container (container-spec container-status)
  (-let* (((&alist 'name name 'image image) container-spec)
          ((&alist 'state (state &as &alist
                                 'running running
                                 'terminated (terminated &as &alist 'exitCode code)
                                 'waiting waiting)
                   'restartCount restart-count)
           container-status)
          (started-at
           (car (--map (alist-get 'startedAt it)
                       (list running terminated waiting))))
          (time-diff
           (when started-at
             (concat (kubernetes-pods-list--time-diff-string (apply #'encode-time (kubernetes-pods-list--parse-utc-timestamp started-at))
                                         (current-time))
                     " ago")))
          (state
           (cond
            ((null container-status)
             (propertize "Pending" 'face 'font-lock-comment-face))
            (running
             (propertize "Running" 'face 'success))
            ((and terminated (zerop code))
             (propertize (alist-get 'reason terminated) 'face 'success))
            (terminated
             (propertize (alist-get 'reason terminated) 'face 'error))
            (waiting
             (propertize (alist-get 'reason waiting) 'face 'warning))
            (t
             (message "Unknown state: %s" (prin1-to-string state))
             (propertize "Warn" 'face 'warning))))

          (section-name (intern (format "pod-container-%s" name))))

    `(section (,section-name)
              (heading (copy-prop ,name ,(concat state " " name)))
              (key-value 12 "Image" ,image)
              (key-value 12 "Restarts" ,(when restart-count (number-to-string restart-count)))
              (key-value 12 "Started" ,(when started-at `(propertize (display ,time-diff) ,started-at))))))

(kubernetes-ast-define-component pod-container-list (containers container-statuses)
  (when-let ((entries
              (--map (-let* (((&alist 'name name) it)
                             (status (-find (-lambda ((&alist 'name status-name))
                                              (equal name status-name))
                                            (append container-statuses nil))))
                       `(pod-container ,it ,status))
                     (append containers nil))))
    `(section (containers)
              (heading "Containers")
              (list ,@entries))))

(kubernetes-ast-define-component pod-name (pod-name)
  `(propertize (keymap ,kubernetes-pod-name-map kubernetes-pod-name ,pod-name)
               (copy-prop ,pod-name ,pod-name)))

(kubernetes-ast-define-component pod (pod)
  (-let* (((&alist 'metadata (&alist 'name name
                                     'namespace namespace
                                     'labels labels)
                   'spec (&alist 'containers containers)
                   'status (&alist 'containerStatuses container-statuses))
           pod)
          ((_ . label) (--first (equal "name" (car it)) labels))
          ((_ . job-name) (--first (equal "job-name" (car it)) labels))
          (section-name (intern (format "pod-entry-%s" name))))

    `(section (,section-name t)
              (heading (pod-name ,name))
              (indent
               (section (label) (key-value 12 "Label" ,label))
               (section (job-name) (key-value 12 "Job Name" ,job-name))
               (section (namespace) (key-value 12 "Namespace" (namespace ,namespace)))
               (padding)
               (pod-container-list ,containers ,container-statuses))
              (padding))))

(kubernetes-ast-define-component loading-indicator ()
  `(propertize (face kubernetes-loading) "Loading..."))

(kubernetes-ast-define-component empty-pods-indicator ()
  `(propertize (face kubernetes-dimmed) "None."))

(kubernetes-ast-define-component pods-list (state)
  (let ((updated-p (kubernetes-state-data-received-p state))
        (pods (kubernetes-state-pods state)))
    `(section (pods-list nil)
              (heading "Pods")
              (indent
               ,(if updated-p
                    (or (--map `(pod ,(gethash it pods)) (kubernetes-pods-list--sorted-keys pods))
                        `(empty-pods-indicator))
                  `(loading-indicator)))
              (padding))))


(provide 'kubernetes-pods-list)

;;; kubernetes-pods-list.el ends here
