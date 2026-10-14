;;; claude-buffer.el --- Chat with the Claude Code CLI in a plain Emacs buffer -*- lexical-binding: t; -*-

;; Author: hanyazou@gmail.com>
;; URL: https://github.com/hanyazou/claude-buffer
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.2"))
;; Keywords: tools, convenience

;;; Commentary:
;; Instead of driving the TUI through vterm, this pipes `claude -p
;; --input-format stream-json --output-format stream-json' and talks to it
;; purely through JSONL on stdin/stdout. The buffer is a plain Emacs buffer,
;; so navigation, search, and copy/paste all work as usual.
;;
;; Commands (same idea as -new/-new-here/-resume/-resume-here in claude-custom.el):
;;   claude-buffer-new      : folder-independent new chat (defaults to misc)
;;   claude-buffer-new-here : new chat rooted at the current project root
;;   claude-buffer-resume   : pick a session to resume across all projects
;;   claude-buffer-resume-here : pick a session to resume within the current project
;;   claude-buffer-remove-session      : pick a session to delete across all projects
;;   claude-buffer-remove-session-here : pick a session to delete within the current project
;;   claude-buffer-rename-session      : pick a session to rename across all projects
;;   claude-buffer-rename-session-here : pick a session to rename within the current project
;;   claude-buffer          : new chat in the current directory (plain version)
;;
;; The resume commands use completing-read, so RET resumes the most recent
;; session, and SPC/TAB complete/list candidates. Resuming replays the past
;; log at the top of the buffer in user>/claude> form.
;;
;; Key bindings:
;;   C-c C-c  : send everything after the marker (the text being typed) as one message
;;   RET      : newline (for composing multi-line input; C-j / S-RET do the same)
;;
;; There is no Shift+Enter-vs-Enter distinction for send/newline. Most
;; terminal emulators, including Apple Terminal.app and Tera Term, don't
;; report Shift+Enter differently from plain Enter (except GUI Emacs and a
;; few capable terminals), so C-c C-c is used for send since it works
;; reliably regardless of environment.
;;
;; Permissions are fixed for prototyping: allowedTools grants file
;; creation/editing (roughly /tmp-equivalent), bash execution (including
;; compiling/running), and web search, and everything else proceeds under
;; acceptEdits without asking each time.

;;; Code:

(require 'json)
(require 'cl-lib)
(require 'pcase)
(require 'project)

(defvar claude-buffer-command
  '("claude" "-p"
    "--input-format" "stream-json"
    "--output-format" "stream-json"
    "--verbose"
    "--permission-mode" "acceptEdits"
    "--allowedTools" "Write Edit Bash WebSearch")
  "Command and arguments used to launch the claude process.")

(defvar-local claude-buffer--process nil
  "The claude process associated with this buffer.")

(defvar-local claude-buffer--session-id nil
  "The session ID this buffer is connected to.
Known upfront and set immediately when resuming; for a new chat it gets
set once the system/init event (or the session_id carried on any other
event) arrives. Used when resuming to check whether a buffer is already
alive for the same session.")

(defvar-local claude-buffer--input-marker nil
  "Everything before this is committed history; everything after is the
text currently being typed.")

(defvar-local claude-buffer--claude-output-marker nil
  "Position where claude's output for the current turn (including
Thinking...) is inserted.")

(defvar-local claude-buffer--awaiting-first-text nil
  "When non-nil, the next text received will replace Thinking....")

(defvar-local claude-buffer--pending-tool-output nil
  "Non-nil means the previous output was a tool_use/tool_result.
Used so that the next text block is preceded by a \"claude> \" separator.")

(defvar-local claude-buffer--pending-output ""
  "Buffer that accumulates fragments until a JSONL line break arrives.")

(defvar-local claude-buffer--turn-timer nil
  "Timer that keeps showing elapsed seconds for the current turn in the
mode-line.")

(defvar-local claude-buffer--turn-start-time nil
  "Time (float-time) the current turn was sent. Non-nil only during a turn.")

(defconst claude-buffer--thinking-text "Thinking..."
  "Placeholder response text shown right after sending.")

(defconst claude-buffer--separator "\n-----\n"
  "Separator inserted before the user>/claude> prompts.")

(defun claude-buffer--append-output (text)
  "Append TEXT as claude's output.
Replaces Thinking... if this is the first text of the turn, otherwise
just appends it. Does not move the user's point (whether typing or
browsing history)."
  (save-excursion
    (let ((start (marker-position claude-buffer--claude-output-marker)))
      (when claude-buffer--awaiting-first-text
        (delete-region start (+ start (length claude-buffer--thinking-text)))
        (setq claude-buffer--awaiting-first-text nil))
      (goto-char start)
      (insert text)
      (set-marker claude-buffer--claude-output-marker (point)))))

(defun claude-buffer--finish-if-no-text ()
  "Clear Thinking... if no text arrived at all during this turn."
  (when (and claude-buffer--awaiting-first-text claude-buffer--claude-output-marker)
    (claude-buffer--append-output "(no output)")))

(defun claude-buffer--tick-elapsed (buf)
  "Reflect the elapsed seconds since the turn started in BUF's mode-line.
Makes it visible that the process (and Emacs) is alive and time is
passing even while waiting on a permission prompt or a long-running Bash
command, during which no JSONL updates arrive at all."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (when claude-buffer--turn-start-time
        (setq-local mode-line-process
                    (format " [%ds]" (truncate (- (float-time) claude-buffer--turn-start-time))))
        (force-mode-line-update)))))

(defun claude-buffer--start-turn-timer ()
  "Call when a turn is sent. Runs claude-buffer--tick-elapsed once a second."
  (claude-buffer--stop-turn-timer)
  (setq claude-buffer--turn-start-time (float-time))
  (setq claude-buffer--turn-timer
        (run-with-timer 1 1 #'claude-buffer--tick-elapsed (current-buffer))))

(defun claude-buffer--stop-turn-timer ()
  "Call when a turn ends (result received / process exited / buffer killed).
Stops the timer and clears the elapsed-seconds display in the mode-line."
  (when claude-buffer--turn-timer
    (cancel-timer claude-buffer--turn-timer)
    (setq claude-buffer--turn-timer nil))
  (setq claude-buffer--turn-start-time nil)
  (setq-local mode-line-process nil)
  (force-mode-line-update))

(defconst claude-buffer--tool-detail-maxlen 200
  "Max length of the parameter string used in the tool_use summary.")

(defconst claude-buffer--tool-result-max-lines 10
  "Max number of lines shown for a tool_result (only this many lines from
the tail are shown).")

(defun claude-buffer--truncate-detail (s maxlen)
  "Truncate S to MAXLEN characters. Newlines are kept as-is (so a
multi-line command isn't squashed into an unreadable single line; unlike
claude-buffer--sanitize-label, which is for buffer names, newlines are
not replaced with spaces)."
  (let ((s (string-trim (or s ""))))
    (if (> (length s) maxlen)
        (concat (substring s 0 maxlen) "…")
      s)))

(defun claude-buffer--tool-use-summary (block)
  "Build a \"tool name: detail\" line from BLOCK (an assistant tool_use
block). The detail is whichever of command/file_path/pattern/url/query/
prompt is found first."
  (let* ((name (or (alist-get 'name block) "?"))
         (input (alist-get 'input block))
         (detail (or (alist-get 'command input)
                     (alist-get 'file_path input)
                     (alist-get 'pattern input)
                     (alist-get 'url input)
                     (alist-get 'query input)
                     (alist-get 'prompt input)
                     (and input (format "%S" input)))))
    (format "%s: %s\n"
            name
            (claude-buffer--truncate-detail (or detail "") claude-buffer--tool-detail-maxlen))))

(defun claude-buffer--tool-result-text (block)
  "Extract the content of BLOCK (a user tool_result block) as a string.
content may be either a string or an array of text blocks."
  (let ((content (alist-get 'content block)))
    (cond
     ((stringp content) content)
     ((listp content)
      (mapconcat (lambda (c) (or (alist-get 'text c) "")) content "\n"))
     (t ""))))

(defun claude-buffer--tool-result-summary (block)
  "Format the result of BLOCK (a tool_result block), keeping only the
last claude-buffer--tool-result-max-lines lines.
Prefixes each line with ✗ when is_error is t, otherwise with a 4-space
indent."
  (let* ((is-error (eq (alist-get 'is_error block) t))
         (text (string-trim (claude-buffer--tool-result-text block)))
         (lines (unless (string-empty-p text) (split-string text "\n")))
         (total (length lines))
         (tail (last lines claude-buffer--tool-result-max-lines))
         (prefix (if is-error "✗ " "    ")))
    (concat
     (when (> total claude-buffer--tool-result-max-lines)
       (format "%s(%d lines omitted)\n" prefix (- total claude-buffer--tool-result-max-lines)))
     (mapconcat (lambda (l) (format "%s%s\n" prefix l)) tail ""))))

(defun claude-buffer--result-summary (data)
  "Build a one-line summary of duration, cost, and turn count from DATA
(a result event)."
  (let ((seconds (/ (or (alist-get 'duration_ms data) 0) 1000.0))
        (cost (or (alist-get 'total_cost_usd data) 0))
        (turns (or (alist-get 'num_turns data) 0))
        (err (eq (alist-get 'is_error data) t)))
    (format "[%s: %.1fs / $%.4f / %d turns]\n"
            (if err "Error" "Done") seconds cost turns)))

(defun claude-buffer--append-text (text)
  "Append TEXT (an assistant text block) to the buffer.
If the previous output was a tool_use/tool_result, first emit a
\"claude> \" separator (to visually set the answer apart from the tool
execution log)."
  (when claude-buffer--pending-tool-output
    (claude-buffer--append-output (concat "\n" (propertize "claude> " 'face 'bold)))
    (setq claude-buffer--pending-tool-output nil))
  (claude-buffer--append-output text))

(defun claude-buffer--append-tool-output (text)
  "Append TEXT (a tool_use/tool_result summary) to the buffer and set a
flag so a separator can be emitted if a text block follows immediately
after."
  (claude-buffer--append-output text)
  (setq claude-buffer--pending-tool-output t))

(defun claude-buffer--handle-json-line (line)
  "Parse LINE (one JSONL line) and append the parts worth displaying to
the buffer. Handles assistant text/tool_use, user tool_result,
permission denials, and the result summary."
  (condition-case err
      (let* ((json-object-type 'alist)
             (json-array-type 'list)
             (data (json-read-from-string line))
             (type (alist-get 'type data)))
        (let ((session-id (alist-get 'session_id data)))
          (when session-id
            (setq claude-buffer--session-id session-id)))
        (cond
         ((equal type "assistant")
          (dolist (block (alist-get 'content (alist-get 'message data)))
            (cond
             ((equal (alist-get 'type block) "text")
              (let ((text (alist-get 'text block)))
                (when (and text (> (length text) 0))
                  (claude-buffer--append-text text))))
             ((equal (alist-get 'type block) "tool_use")
              (claude-buffer--append-tool-output (claude-buffer--tool-use-summary block))))))
         ((equal type "user")
          (dolist (block (alist-get 'content (alist-get 'message data)))
            (when (equal (alist-get 'type block) "tool_result")
              (claude-buffer--append-tool-output (claude-buffer--tool-result-summary block)))))
         ((and (equal type "system") (equal (alist-get 'subtype data) "permission_denied"))
          (claude-buffer--append-output
           (format "[Permission denied: %s — %s]\n"
                   (or (alist-get 'tool_name data) "?")
                   (or (alist-get 'decision_reason data) (alist-get 'message data) "?"))))
         ((equal type "result")
          (claude-buffer--finish-if-no-text)
          (claude-buffer--stop-turn-timer)
          (claude-buffer--append-output (concat "\n" (claude-buffer--result-summary data))))))
    (error
     (message "claude-buffer: failed to parse JSON line: %s" (error-message-string err)))))

(defun claude-buffer--filter (proc chunk)
  "Process filter. Accumulates CHUNK and processes it as JSON lines split
on newlines."
  (let ((buf (process-buffer proc)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (setq claude-buffer--pending-output
              (concat claude-buffer--pending-output chunk))
        (let (line)
          (while (string-match "\n" claude-buffer--pending-output)
            (setq line (substring claude-buffer--pending-output 0 (match-beginning 0)))
            (setq claude-buffer--pending-output
                  (substring claude-buffer--pending-output (match-end 0)))
            (unless (string-empty-p line)
              (claude-buffer--handle-json-line line))))))))

(defun claude-buffer--sentinel (proc event)
  "Sentinel that reports process termination and similar events."
  (let ((buf (process-buffer proc)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (claude-buffer--stop-turn-timer)
        (claude-buffer--finish-if-no-text)
        (save-excursion
          (goto-char (point-max))
          (insert claude-buffer--separator)
          (insert (format "[claude process %s]\n" (string-trim event))))))))

(defun claude-buffer--send ()
  "Send everything after the marker to claude as one message, and display
claude> Thinking... followed by the next user> prompt.
Only meant to be bound to C-c C-c, so it's left without interactive to
keep it out of M-x."
  (let ((text (string-trim
               (buffer-substring-no-properties
                claude-buffer--input-marker (point-max)))))
    (if (string-empty-p text)
        (message "claude-buffer: nothing to send")
      (goto-char (point-max))
      (insert claude-buffer--separator)
      (insert (propertize "claude> " 'face 'bold))
      (setq claude-buffer--claude-output-marker (point-marker))
      (insert claude-buffer--thinking-text)
      (insert claude-buffer--separator)
      (insert (propertize "user> " 'face 'bold))
      (setq claude-buffer--input-marker (point-marker))
      (setq claude-buffer--awaiting-first-text t)
      (setq claude-buffer--pending-tool-output nil)
      (claude-buffer--start-turn-timer)
      (goto-char (point-max))
      (process-send-string
       claude-buffer--process
       (concat (json-encode `((type . "user")
                               (message . ((role . "user")
                                           (content . ,text)))))
               "\n")))))

(defvar claude-buffer-mode-map
  (let ((map (make-sparse-keymap)))
    ;; claude-buffer--send is bound here as an anonymous lambda instead of a
    ;; named interactive command so it doesn't show up in M-x completion.
    ;; RET is deliberately left unbound (the buffer's default newline behavior).
    (define-key map (kbd "C-c C-c") (lambda () (interactive) (claude-buffer--send)))
    map)
  "Keymap for claude-buffer-mode.
Send with C-c C-c. Switching send/newline based on Shift+Enter isn't used
because most terminal emulators can't distinguish Shift+Enter from plain
Enter (see the Commentary at the top of the file for details).")

(define-derived-mode claude-buffer-mode fundamental-mode "Claude"
  "A plain Emacs buffer for talking to claude -p
--input-format/--output-format stream-json. Since it doesn't go through a
TUI, ordinary buffer operations — navigation, search, copy/paste — all
just work."
  :interactive nil)

(defun claude-buffer--dir-label (dir)
  "Return a display label for DIR (a path): its trailing directory name."
  (file-name-nondirectory (directory-file-name (expand-file-name dir))))

(defun claude-buffer--sanitize-label (s maxlen)
  "Sanitize S for use in a buffer name (strip newlines/*, truncate to
MAXLEN characters)."
  (let ((s (string-trim (replace-regexp-in-string "[\n\r*]" " " (or s "")))))
    (if (> (length s) maxlen)
        (concat (substring s 0 maxlen) "…")
      s)))

(defun claude-buffer--start (&optional resume-id history-file summary)
  "Start a new claude chat buffer and process.
If RESUME-ID is non-nil, resumes with `--resume RESUME-ID'.
If HISTORY-FILE is non-nil, replays that session's past log at the top of
the buffer.
SUMMARY is a content-based label for naming, such as the session's first
message.
The process's current directory is the caller's `default-directory'.
The buffer name is *claude:folder-name* when new, or
*claude:folder-name:content-label* when resuming (falling back to the
first 8 characters of the session ID if no label is available)."
  (let* ((dir default-directory)
         (base (if resume-id
                   (format "%s:%s" (claude-buffer--dir-label dir)
                           (let ((label (claude-buffer--sanitize-label summary 20)))
                             (if (string-empty-p label)
                                 (substring resume-id 0 8)
                               label)))
                 (claude-buffer--dir-label dir)))
         (name (generate-new-buffer-name (format "*claude:%s*" base)))
         (buf (get-buffer-create name))
         (command (if resume-id
                      (append claude-buffer-command (list "--resume" resume-id))
                    claude-buffer-command)))
    (with-current-buffer buf
      (claude-buffer-mode)
      (setq default-directory dir)
      (setq claude-buffer--session-id resume-id)
      (when history-file
        (let ((history (claude-buffer--render-history history-file)))
          (unless (string-empty-p history)
            (insert history)
            (insert claude-buffer--separator))))
      (insert (propertize "user> " 'face 'bold))
      (setq claude-buffer--input-marker (point-marker))
      (setq claude-buffer--process
            (make-process
             :name name
             :buffer buf
             :command command
             :connection-type 'pipe
             :coding 'utf-8
             :noquery t
             :filter #'claude-buffer--filter
             :sentinel #'claude-buffer--sentinel))
      (add-hook 'kill-buffer-hook
                (lambda ()
                  (claude-buffer--stop-turn-timer)
                  (when (process-live-p claude-buffer--process)
                    (delete-process claude-buffer--process)))
                nil t))
    (switch-to-buffer buf)))

;;;###autoload
(defun claude-buffer ()
  "Start a new claude chat buffer and process (staying in the current
directory)."
  (interactive)
  (claude-buffer--start))

(defun claude-buffer--search-git-root (dir)
  "Walk up from DIR looking for a directory containing `.git' and return
it (nil if none). When DIR is under `~', the search is bounded by `~'
and doesn't look at ancestor directories above it, to avoid mistakenly
picking up an unrelated parent directory's git repository."
  (let* ((home (file-name-as-directory (expand-file-name "~")))
         (cur (file-name-as-directory (expand-file-name dir)))
         (bounded (string-prefix-p home cur)))
    (catch 'done
      (while t
        (when (file-exists-p (expand-file-name ".git" cur))
          (throw 'done cur))
        (when (and bounded (equal cur home))
          (throw 'done nil))
        (let ((parent (file-name-directory (directory-file-name cur))))
          (when (equal parent cur)
            (throw 'done nil))
          (setq cur parent))))))

(defun claude-buffer--project-root ()
  "Return the `.repo' directory if one exists; otherwise the git root
within `~'; otherwise whatever project root project.el can find;
otherwise default-directory (same idea as claude-custom-project-root)."
  (let ((repo-root (locate-dominating-file default-directory ".repo")))
    (cond
     (repo-root repo-root)
     ((claude-buffer--search-git-root default-directory))
     ((project-current) (project-root (project-current)))
     (t default-directory))))

;;;###autoload
(defun claude-buffer-new ()
  "Start a folder-independent, throwaway new chat.
Uses ~/claude-chats/misc without asking."
  (interactive)
  (let ((default-directory (expand-file-name "misc" "~/claude-chats")))
    (claude-buffer--start)))

;;;###autoload
(defun claude-buffer-new-here ()
  "Start a new chat rooted at the project the current folder belongs to."
  (interactive)
  (let ((default-directory (claude-buffer--project-root)))
    (claude-buffer--start)))

(defvar claude-buffer-projects-dir "~/.claude/projects/"
  "Directory where Claude Code stores session JSONL files.")

(defun claude-buffer--encode-dir (dir)
  "Convert DIR (an absolute path) to Claude Code's project directory name."
  (replace-regexp-in-string "[^a-zA-Z0-9]" "-" (directory-file-name (expand-file-name dir))))

(defun claude-buffer--all-session-files ()
  "Return every project's session files (.jsonl), newest first."
  (let ((root (expand-file-name claude-buffer-projects-dir)))
    (sort
     (cl-loop for dir in (and (file-directory-p root)
                               (directory-files root t "^[^.]"))
              when (file-directory-p dir)
              append (directory-files dir t "\\.jsonl\\'"))
     #'file-newer-than-file-p)))

(defun claude-buffer--session-files-here ()
  "Return only the current project's session files (.jsonl), newest first."
  (let ((dir (expand-file-name (claude-buffer--encode-dir (claude-buffer--project-root))
                                claude-buffer-projects-dir)))
    (sort (and (file-directory-p dir) (directory-files dir t "\\.jsonl\\'"))
          #'file-newer-than-file-p)))

(defun claude-buffer--session-title (file)
  "Search all of FILE (a session jsonl) for `ai-title' records (written
by claude itself, or by claude-buffer-rename-session) and return the
last one found (nil if none).
Scanning only a tail window would go stale once the conversation keeps
appending after a rename (this actually happened on a live session), so
the whole file is scanned instead (same idea as
claude-buffer--render-history)."
  (condition-case nil
      (with-temp-buffer
        (insert-file-contents file)
        (let ((json-object-type 'alist) (json-array-type 'list)
              (title nil))
          (goto-char (point-min))
          (while (not (eobp))
            (let ((line (buffer-substring-no-properties
                         (line-beginning-position) (line-end-position))))
              (when (> (length line) 0)
                (condition-case nil
                    (let ((data (json-read-from-string line)))
                      (when (equal (alist-get 'type data) "ai-title")
                        (setq title (alist-get 'aiTitle data))))
                  (error nil))))
            (forward-line 1))
          title))
    (error nil)))

(defun claude-buffer--session-info (file)
  "Extract (cwd . preview) from FILE (a session jsonl). Returns
(nil . nil) on failure.
preview prefers an ai-title record (including one set by
claude-buffer-rename-session) if present, otherwise it's built from the
first user message."
  (condition-case nil
      (with-temp-buffer
        (insert-file-contents file nil 0 4096)
        (let ((json-object-type 'alist) (json-array-type 'list)
              (cwd nil) (preview nil))
          (goto-char (point-min))
          (while (and (not preview) (not (eobp)))
            (let ((line (buffer-substring-no-properties
                         (line-beginning-position) (line-end-position))))
              (when (> (length line) 0)
                (condition-case nil
                    (let* ((data (json-read-from-string line))
                           (type (alist-get 'type data)))
                      (unless cwd
                        (setq cwd (alist-get 'cwd data)))
                      (when (equal type "user")
                        (let ((content (alist-get 'content (alist-get 'message data))))
                          (when (stringp content)
                            (setq preview (substring content 0 (min 40 (length content))))))))
                  (error nil))))
            (forward-line 1))
          (cons cwd (or (claude-buffer--session-title file) preview))))
    (error (cons nil nil))))

(defun claude-buffer--session-candidates (files)
  "Build a completing-read candidate alist from FILES.
Values are lists of (id cwd file preview)."
  (cl-loop for file in files
           for id = (file-name-base file)
           for info = (claude-buffer--session-info file)
           for cwd = (car info)
           for preview = (or (cdr info) "")
           collect (cons (format "%s  [%s]  %s"
                                  (format-time-string
                                   "%Y/%m/%d %H:%M"
                                   (file-attribute-modification-time (file-attributes file)))
                                  (if cwd (file-name-nondirectory (directory-file-name cwd)) "?")
                                  preview)
                         (list id cwd file preview))))

(defun claude-buffer--completion-table (candidates)
  "Turn CANDIDATES (an alist) into a completion table that preserves
order. completing-read's default UI alphabetizes labels, which sorts
oldest-first because of the date string at the start of each label, so
display-sort-function/cycle-sort-function are set to identity to keep
CANDIDATES' (newest-first) order as-is."
  (lambda (string pred action)
    (if (eq action 'metadata)
        '(metadata (display-sort-function . identity)
                    (cycle-sort-function . identity))
      (complete-with-action action candidates string pred))))

(defun claude-buffer--read-session (files prompt)
  "Let the user pick a session from FILES via completing-read and return
(id cwd file preview).
The default is the most recent session, and the candidate list is also
ordered newest-first."
  (let ((candidates (claude-buffer--session-candidates files)))
    (if (null candidates)
        (user-error "claude-buffer: no sessions found")
      (let* ((default (caar candidates))
             (choice (completing-read (format "%s (default %s): " prompt default)
                                       (claude-buffer--completion-table candidates)
                                       nil t nil nil default)))
        (cdr (assoc choice candidates))))))

(defun claude-buffer--render-history (file)
  "Reconstruct just the user and claude text from FILE (a session jsonl)
as a string with user>/claude> prompts."
  (let (parts)
    (with-temp-buffer
      (insert-file-contents file)
      (let ((json-object-type 'alist) (json-array-type 'list))
        (goto-char (point-min))
        (while (not (eobp))
          (let ((line (buffer-substring-no-properties
                       (line-beginning-position) (line-end-position))))
            (when (> (length line) 0)
              (condition-case nil
                  (let* ((data (json-read-from-string line))
                         (type (alist-get 'type data))
                         (message (alist-get 'message data)))
                    (cond
                     ((equal type "user")
                      (let ((content (alist-get 'content message)))
                        (when (stringp content)
                          (push (concat (propertize "user> " 'face 'bold) content) parts))))
                     ((equal type "assistant")
                      (dolist (block (alist-get 'content message))
                        (when (equal (alist-get 'type block) "text")
                          (let ((text (alist-get 'text block)))
                            (when (and text (> (length text) 0))
                              (push (concat (propertize "claude> " 'face 'bold) text) parts))))))))
                (error nil))))
          (forward-line 1))))
    (mapconcat #'identity (nreverse parts) claude-buffer--separator)))

(defun claude-buffer--find-live-buffer-for-session (session-id)
  "Find a claude-buffer-mode buffer still connected to SESSION-ID (nil if
none). Used when resuming to avoid corrupting the session file by
writing to it twice, in case a process is already attached to the
session being resumed."
  (cl-find-if
   (lambda (buf)
     (with-current-buffer buf
       (and (derived-mode-p 'claude-buffer-mode)
            (equal claude-buffer--session-id session-id)
            (process-live-p claude-buffer--process))))
   (buffer-list)))

(defun claude-buffer--resume-session (files)
  "Let the user pick a session from FILES and create a buffer that
resumes it with --resume. If a live buffer already exists for the
chosen session, just switch to it instead of opening a new one (to
avoid a double connection)."
  (pcase-let ((`(,id ,cwd ,file ,preview) (claude-buffer--read-session files "Session")))
    (let ((live (claude-buffer--find-live-buffer-for-session id)))
      (if live
          (progn
            (message "claude-buffer: switching to the already-open buffer")
            (switch-to-buffer live))
        (let ((default-directory (if cwd (expand-file-name cwd) default-directory)))
          (claude-buffer--start id file preview))))))

;;;###autoload
(defun claude-buffer-resume ()
  "Pick a session to resume from the list across all projects."
  (interactive)
  (claude-buffer--resume-session (claude-buffer--all-session-files)))

;;;###autoload
(defun claude-buffer-resume-here ()
  "Pick a session to resume, limited to the current project."
  (interactive)
  (claude-buffer--resume-session (claude-buffer--session-files-here)))

(defun claude-buffer--remove-session (files)
  "Let the user pick a session from FILES and delete its jsonl file.
A session that still has a live buffer (process) attached can't be
deleted."
  (pcase-let ((`(,id ,cwd ,file ,_preview) (claude-buffer--read-session files "Remove session")))
    (when (claude-buffer--find-live-buffer-for-session id)
      (user-error "claude-buffer: this session is still open; close its buffer first"))
    (when (yes-or-no-p (format "Delete session %s [%s]? " id (or cwd "?")))
      (delete-file file)
      (message "claude-buffer: removed session: %s" id))))

;;;###autoload
(defun claude-buffer-remove-session ()
  "Pick a session to delete from the list across all projects.
A session that still has a live buffer (process) attached can't be
deleted."
  (interactive)
  (claude-buffer--remove-session (claude-buffer--all-session-files)))

;;;###autoload
(defun claude-buffer-remove-session-here ()
  "Pick a session to delete, limited to the current project."
  (interactive)
  (claude-buffer--remove-session (claude-buffer--session-files-here)))

(defun claude-buffer--rename-live-buffer (session-id title)
  "If a buffer is still live and connected to SESSION-ID, rename it too
using TITLE (does nothing if there is none)."
  (let ((buf (claude-buffer--find-live-buffer-for-session session-id)))
    (when buf
      (with-current-buffer buf
        (rename-buffer
         (format "*claude:%s:%s*"
                 (claude-buffer--dir-label default-directory)
                 (claude-buffer--sanitize-label title 20))
         t)))))

(defun claude-buffer--rename-session-file (file)
  "Append a new name, entered in the minibuffer, to FILE (a session
jsonl) as an `ai-title' record (the same format claude itself writes).
Never modifies or deletes existing content. If this session has a live
buffer, its name is updated to match too."
  (let* ((session-id (file-name-base file))
         (current (claude-buffer--session-title file))
         (title (string-trim (read-string "New name: " current))))
    (when (string-empty-p title)
      (user-error "claude-buffer: name is empty"))
    (with-temp-buffer
      (insert (json-encode `((type . "ai-title")
                              (aiTitle . ,title)
                              (sessionId . ,session-id)))
              "\n")
      (write-region (point-min) (point-max) file t))
    (claude-buffer--rename-live-buffer session-id title)
    title))

(defun claude-buffer--rename-session (files)
  "Let the user pick a session from FILES and rename it."
  (pcase-let ((`(,_id ,_cwd ,file ,_preview) (claude-buffer--read-session files "Rename session")))
    (let ((title (claude-buffer--rename-session-file file)))
      (message "claude-buffer: renamed session: %s" title))))

;;;###autoload
(defun claude-buffer-rename-session ()
  "Pick a session to rename from the list across all projects.
Just appends an `ai-title' record to the end of the session jsonl and
never modifies or deletes existing content (uses the same mechanism as
claude itself)."
  (interactive)
  (claude-buffer--rename-session (claude-buffer--all-session-files)))

;;;###autoload
(defun claude-buffer-rename-session-here ()
  "Pick a session to rename, limited to the current project."
  (interactive)
  (claude-buffer--rename-session (claude-buffer--session-files-here)))

(provide 'claude-buffer)
;;; claude-buffer.el ends here
