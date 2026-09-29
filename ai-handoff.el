;;; ai-handoff.el --- Drive the `handoff' script from Emacs -*- lexical-binding: t -*-

;;; Commentary:

;; `ai/handoff' hands the current file off via the `handoff' script, applies
;; the result once Emacs has been idle for a while, and reverts affected
;; buffers.  `ai/handoff-diff' shows the diff of the latest handoff of the
;; current file.

;;; Code:

(require 'project)
(require 'ring)
(require 'subr-x)

(defgroup ai-handoff nil
  "Drive the `handoff' script."
  :group 'tools
  :prefix "ai/handoff-")

(defcustom ai/handoff-directory nil
  "Directory shared with the sandbox, passed as `--directory' to `handoff'."
  :type '(choice (const :tag "Unset" nil) directory))

(defcustom ai/handoff-program nil
  "Path to the `handoff' script.  If nil, look for `handoff' above `ai/handoff-directory', or on `exec-path'."
  :type '(choice (const :tag "Search exec-path" nil) file))

(defcustom ai/handoff-idle-seconds 5
  "Seconds of idle time to wait for before applying a ready handoff."
  :type 'number)

(defcustom ai/handoff-ring-size 32
  "Number of completed handoffs remembered for `ai/handoff-diff'."
  :type 'natnum)

(defcustom ai/handoff-ack-timeout-ms nil
  "Passed as `--ack-timeout-ms' to `handoff'.  If nil, use its default."
  :type '(choice (const :tag "Script default" nil) natnum))

(defcustom ai/handoff-answer-timeout-ms nil
  "Passed as `--answer-timeout-ms' to `handoff'.  If nil, use its default."
  :type '(choice (const :tag "Script default" nil) natnum))

(defvar ai/handoff--ring nil
  "Ring of completed handoffs, each a plist with :file, :op-id and :rev.")

(defvar ai/handoff--process nil
  "The currently running `handoff' process, if any.")

(defun ai/handoff--modified-file-buffers ()
  (seq-filter (lambda (b) (and (buffer-file-name b) (buffer-modified-p b)))
              (buffer-list)))

(defun ai/handoff--save-buffers (buffers)
  (dolist (b buffers)
    (with-current-buffer b (save-buffer))))

(defun ai/handoff--program ()
  (or ai/handoff-program
      (let ((candidate (expand-file-name "../handoff" ai/handoff-directory)))
        (and (file-executable-p candidate) candidate))
      (executable-find "handoff")
      (user-error "Could not find `handoff'; set `ai/handoff-program'")))

(defun ai/handoff--relative (file root)
  (if root (file-relative-name file root) file))

(defun ai/handoff--revert (files)
  (dolist (file (delete-dups files))
    (when-let* ((buf (find-buffer-visiting file)))
      (with-current-buffer buf
        (if (buffer-modified-p)
            (display-warning 'ai-handoff
                             (format "Not reverting modified buffer %s" (buffer-name)))
          (revert-buffer t t t))))))

(defun ai/handoff--summary (result root)
  (let* ((found (alist-get 'todos_found result))
         (fixed (alist-get 'todos_fixed result))
         (run (alist-get 'tests_run result))
         (pass (alist-get 'tests_pass result))
         (info (alist-get 'info result))
         (extra (alist-get 'extraFiles result))
         (conflicts (alist-get 'conflictFiles result))
         (rel (lambda (fs) (mapconcat (lambda (f) (ai/handoff--relative f root)) fs ", ")))
         (todos (if (eql found 0) "no TODOs found" (format "%s/%s TODOs" fixed found)))
         (tests (if (eql run 0) "no tests configured" (format "%s/%s tests passed" pass run))))
    (concat "Handoff complete"
            (if conflicts
                (propertize (format " WITH CONFLICTS in %s;" (funcall rel conflicts))
                            'face 'error)
              ",")
            (format " %s, %s." todos tests)
            (when extra
              (format " %d additional file%s edited: %s"
                      (length extra) (if (cdr extra) "s" "") (funcall rel extra)))
            (unless (string-empty-p (or info ""))
              (concat "\n" info)))))

(defun ai/handoff--apply (proc)
  (when (process-live-p proc)
    (ai/handoff--save-buffers (ai/handoff--modified-file-buffers))
    (process-send-string proc "y\n")))

(defun ai/handoff--filter (proc string)
  (with-current-buffer (process-buffer proc)
    (goto-char (point-max))
    (insert string)
    (when (and (not (process-get proc 'ready))
               (save-excursion
                 (goto-char (point-min))
                 (re-search-forward "^Edit ready\\.$" nil t)))
      (process-put proc 'ready t)
      (message "Handoff ready, will apply when idle.")
      (run-with-idle-timer ai/handoff-idle-seconds nil #'ai/handoff--apply proc))))

(defun ai/handoff--sentinel (proc _event)
  (unless (process-live-p proc)
    (let ((out (process-buffer proc))
          (err (process-get proc 'stderr))
          (file (process-get proc 'file))
          (root (process-get proc 'root)))
      ;; The stderr pipe is read separately, so it may still hold output.
      (let ((errproc (get-buffer-process err)))
        (while (and errproc (accept-process-output errproc 0.1))))
      (setq ai/handoff--process nil)
      (unwind-protect
          (if (not (and (eq (process-status proc) 'exit)
                        (zerop (process-exit-status proc))))
              (message "Handoff failed (exit %s): %s"
                       (process-exit-status proc)
                       (string-trim (with-current-buffer err (buffer-string))))
            (let* ((json (with-current-buffer out
                           (goto-char (point-max))
                           (skip-chars-backward "\n")
                           (buffer-substring (line-beginning-position) (point))))
                   (result (json-parse-string json :object-type 'alist
                                              :array-type 'list)))
              (ai/handoff--revert (append (list file)
                                          (alist-get 'extraFiles result)
                                          (alist-get 'conflictFiles result)))
              (unless ai/handoff--ring
                (setq ai/handoff--ring (make-ring ai/handoff-ring-size)))
              (ring-insert ai/handoff--ring
                           (list :file file
                                 :op-id (alist-get 'opId result)
                                 :rev (alist-get 'rev result)))
              (message "%s" (ai/handoff--summary result root))))
        (kill-buffer out)
        (kill-buffer err)))))

;;;###autoload
(defun ai/handoff ()
  "Hand the current buffer's file off via `handoff', applying the result when idle."
  (interactive)
  (let ((file (buffer-file-name)))
    (unless file
      (user-error "Buffer is not visiting a file"))
    (unless ai/handoff-directory
      (user-error "Set `ai/handoff-directory' first"))
    (when (process-live-p ai/handoff--process)
      (user-error "A handoff is already in progress for %s"
                  (process-get ai/handoff--process 'file)))
    (let ((program (ai/handoff--program))
          (modified (ai/handoff--modified-file-buffers)))
      (when modified
        (if (y-or-n-p (format "Save modified buffers (%s) before handoff? "
                              (mapconcat #'buffer-name modified ", ")))
            (ai/handoff--save-buffers modified)
          (user-error "Handoff aborted")))
      (let* ((file (file-truename file))
             (root (when-let* ((project (project-current nil)))
                     (expand-file-name (project-root project))))
             (err (generate-new-buffer " *handoff-stderr*"))
             (errproc (make-pipe-process :name "handoff-stderr" :buffer err
                                         :noquery t :sentinel #'ignore))
             (proc (make-process
                    :name "handoff"
                    :buffer (generate-new-buffer " *handoff-stdout*")
                    :stderr errproc
                    :connection-type 'pipe
                    :noquery t
                    :command `(,program
                               "--directory" ,(expand-file-name ai/handoff-directory)
                               ,@(when ai/handoff-ack-timeout-ms
                                   (list "--ack-timeout-ms"
                                         (number-to-string ai/handoff-ack-timeout-ms)))
                               ,@(when ai/handoff-answer-timeout-ms
                                   (list "--answer-timeout-ms"
                                         (number-to-string ai/handoff-answer-timeout-ms)))
                               ,file)
                    :filter #'ai/handoff--filter
                    :sentinel #'ai/handoff--sentinel)))
        (process-put proc 'file file)
        (process-put proc 'root root)
        (process-put proc 'stderr err)
        (setq ai/handoff--process proc)
        (message "Handoff started for %s" (ai/handoff--relative file root))))))

;;;###autoload
(defun ai/handoff-diff ()
  "Show the diff of the most recent handoff of the current buffer's file."
  (interactive)
  (let* ((file (or (buffer-file-name) (user-error "Buffer is not visiting a file")))
         (file (file-truename file))
         (entry (and ai/handoff--ring
                     (seq-find (lambda (e) (equal (plist-get e :file) file))
                               (ring-elements ai/handoff--ring))))
         (buf (get-buffer-create "*handoff-diff*")))
    (unless entry
      (user-error "No handoff recorded for %s" file))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        ;; Paths in the diff are relative to the jj root.
        (setq default-directory (file-name-directory file))
        (let ((root (string-trim (shell-command-to-string "jj root 2>/dev/null"))))
          (unless (string-empty-p root)
            (setq default-directory (file-name-as-directory root))))
        (erase-buffer)
        (unless (zerop (call-process "jj" nil t nil "show" "--git" "--template" ""
                                     "--at-operation" (plist-get entry :op-id)
                                     (plist-get entry :rev)))
          (user-error "jj show failed: %s" (string-trim (buffer-string)))))
      (goto-char (point-min))
      (diff-mode)
      (setq buffer-read-only t))
    (display-buffer buf)))

(provide 'ai-handoff)
;;; ai-handoff.el ends here
