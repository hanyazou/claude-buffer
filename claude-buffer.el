;;; claude-buffer.el --- Claude Code CLI を普通のバッファでチャットする -*- lexical-binding: t; -*-

;; Author: hanyazou@gmail.com>
;; URL: https://github.com/hanyazou/claude-buffer
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.2"))
;; Keywords: tools, convenience

;;; Commentary:
;; vterm 越しにTUIを操作するのではなく、`claude -p --input-format stream-json
;; --output-format stream-json' をパイプで起動し、標準入出力のJSONLだけで
;; やり取りする。バッファは普通のEmacsバッファなので、移動・検索・コピペは
;; 全部いつも通り。
;;
;; コマンド (claude-custom.el の -new/-new-here/-resume/-resume-here と同じ考え方):
;;   claude-buffer-new      : フォルダに依存しない新規チャット(デフォルト misc)
;;   claude-buffer-new-here : カレントのプロジェクトルートで新規チャット
;;   claude-buffer-resume   : 全プロジェクト横断でセッション一覧から選んで再開
;;   claude-buffer-resume-here : カレントプロジェクトのセッションから選んで再開
;;   claude-buffer-remove-session      : 全プロジェクト横断でセッションを選んで削除
;;   claude-buffer-remove-session-here : カレントプロジェクトのセッションから選んで削除
;;   claude-buffer-rename-session      : 全プロジェクト横断でセッションを選んで改名
;;   claude-buffer-rename-session-here : カレントプロジェクトのセッションから選んで改名
;;   claude-buffer          : カレントディレクトリのまま新規チャット(素の版)
;;
;; resume系は completing-read を使うので、RETで直近セッションを再開、
;; SPC/TABで補完・一覧表示ができる。再開時は過去ログをuser>/claude>形式で
;; バッファ先頭に再現する。
;;
;; キー操作:
;;   C-c C-c  : マーカー以降(入力中のテキスト)をまとめて送信
;;   RET      : 改行(複数行の入力を組み立てる用。C-j / S-RET も同様)
;;
;; Shift+EnterとEnterを打ち分けて送信/改行を切り替える設計は採用していない。
;; Apple Terminal.appやTera Termをはじめ多くのターミナルエミュレータは
;; Shift+Enterを素のEnterと区別して送ってこないため(GUI Emacsや一部の
;; 対応端末を除く)、環境によらず確実に効くC-c C-cを送信キーにしている。
;;
;; 権限は試作用に固定: /tmp相当のファイル作成・変更、bash実行(コンパイル・
;; 実行含む)、Web検索を allowedTools で許可し、それ以外は都度は聞かず
;; acceptEdits で進める。

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
  "claude プロセスを起動するコマンドと引数.")

(defvar-local claude-buffer--process nil
  "このバッファに紐づく claude プロセス.")

(defvar-local claude-buffer--session-id nil
  "このバッファが繋がっているセッションID.
resume時は最初から分かっているので即座にセットされ、新規チャットの場合は
system/init イベント(あるいは他のどのイベントにも載っている session_id)を
受け取った時点でセットされる. resume時に、同じセッションに既に生きている
バッファがないか探すために使う.")

(defvar-local claude-buffer--input-marker nil
  "これより前が確定済みの履歴、これより後が入力中のテキスト.")

(defvar-local claude-buffer--claude-output-marker nil
  "今のターンでclaudeの出力(Thinking...含む)を挿入していく位置.")

(defvar-local claude-buffer--awaiting-first-text nil
  "非nilなら、次のテキストが来たらThinking...を置き換える.")

(defvar-local claude-buffer--pending-output ""
  "JSONLの行区切りが来るまでの断片を溜めておくバッファ.")

(defvar-local claude-buffer--turn-timer nil
  "ターン中の経過秒数をmode-lineに表示し続けるタイマー.")

(defvar-local claude-buffer--turn-start-time nil
  "現在のターンを送信した時刻(float-time). ターン中のみ非nil.")

(defconst claude-buffer--thinking-text "Thinking..."
  "送信直後に表示しておく仮の応答テキスト.")

(defconst claude-buffer--separator "\n-----\n"
  "user>/claude> プロンプトの前に挿入する区切り.")

(defun claude-buffer--append-output (text)
  "TEXT をclaudeの出力として追加する.
このターンで最初のテキストならThinking...を置き換え、
2回目以降ならそのまま継ぎ足す.
ユーザーのポイント位置(入力中/過去ログ閲覧中)は動かさない."
  (save-excursion
    (let ((start (marker-position claude-buffer--claude-output-marker)))
      (when claude-buffer--awaiting-first-text
        (delete-region start (+ start (length claude-buffer--thinking-text)))
        (setq claude-buffer--awaiting-first-text nil))
      (goto-char start)
      (insert text)
      (set-marker claude-buffer--claude-output-marker (point)))))

(defun claude-buffer--finish-if-no-text ()
  "このターンで一度もテキストが来なかった場合、Thinking...を消す."
  (when (and claude-buffer--awaiting-first-text claude-buffer--claude-output-marker)
    (claude-buffer--append-output "(出力なし)")))

(defun claude-buffer--tick-elapsed (buf)
  "BUF のmode-lineに、ターン開始からの経過秒数を反映する.
権限待ちやBashの長時間実行などJSONLの更新が全く来ない間でも、
プロセス(とEmacs側)が生きていて時間が進んでいることが見えるようにする."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (when claude-buffer--turn-start-time
        (setq-local mode-line-process
                    (format " [%ds]" (truncate (- (float-time) claude-buffer--turn-start-time))))
        (force-mode-line-update)))))

(defun claude-buffer--start-turn-timer ()
  "ターン送信時に呼ぶ. claude-buffer--tick-elapsed を1秒ごとに走らせる."
  (claude-buffer--stop-turn-timer)
  (setq claude-buffer--turn-start-time (float-time))
  (setq claude-buffer--turn-timer
        (run-with-timer 1 1 #'claude-buffer--tick-elapsed (current-buffer))))

(defun claude-buffer--stop-turn-timer ()
  "ターン終了(結果受信/プロセス終了/バッファkill)時に呼ぶ.
タイマーを止め、mode-lineの経過秒数表示を消す."
  (when claude-buffer--turn-timer
    (cancel-timer claude-buffer--turn-timer)
    (setq claude-buffer--turn-timer nil))
  (setq claude-buffer--turn-start-time nil)
  (setq-local mode-line-process nil)
  (force-mode-line-update))

(defconst claude-buffer--tool-detail-maxlen 200
  "tool_use の要約に使うパラメータ文字列の最大長.")

(defconst claude-buffer--tool-result-max-lines 10
  "tool_result を表示する際の最大行数(末尾からこの行数だけ表示).")

(defun claude-buffer--truncate-detail (s maxlen)
  "S をMAXLEN文字までに切り詰める. 改行はそのまま残す(複数行コマンドを
1行に潰して読みにくくしないため。バッファ名用の
claude-buffer--sanitize-label とは違い、改行を空白に置換しない)."
  (let ((s (string-trim (or s ""))))
    (if (> (length s) maxlen)
        (concat (substring s 0 maxlen) "…")
      s)))

(defun claude-buffer--tool-use-summary (block)
  "BLOCK (assistantのtool_useブロック)から「→ ツール名: 詳細」の行を作る.
詳細は command/file_path/pattern/url/query/prompt のうち最初に見つかったもの."
  (let* ((name (or (alist-get 'name block) "?"))
         (input (alist-get 'input block))
         (detail (or (alist-get 'command input)
                     (alist-get 'file_path input)
                     (alist-get 'pattern input)
                     (alist-get 'url input)
                     (alist-get 'query input)
                     (alist-get 'prompt input)
                     (and input (format "%S" input)))))
    (format "→ %s: %s\n"
            name
            (claude-buffer--truncate-detail (or detail "") claude-buffer--tool-detail-maxlen))))

(defun claude-buffer--tool-result-text (block)
  "BLOCK (userのtool_resultブロック)の content を文字列として取り出す.
content は文字列の場合と、textブロックの配列の場合がある."
  (let ((content (alist-get 'content block)))
    (cond
     ((stringp content) content)
     ((listp content)
      (mapconcat (lambda (c) (or (alist-get 'text c) "")) content "\n"))
     (t ""))))

(defun claude-buffer--tool-result-summary (block)
  "BLOCK (tool_resultブロック)の結果を、末尾
claude-buffer--tool-result-max-lines 行だけ整形して返す.
is_errorがtなら✗、それ以外は←を各行の頭に付ける."
  (let* ((is-error (eq (alist-get 'is_error block) t))
         (text (string-trim (claude-buffer--tool-result-text block)))
         (lines (unless (string-empty-p text) (split-string text "\n")))
         (total (length lines))
         (tail (last lines claude-buffer--tool-result-max-lines))
         (mark (if is-error "✗" "←")))
    (concat
     (when (> total claude-buffer--tool-result-max-lines)
       (format "%s (%d行省略)\n" mark (- total claude-buffer--tool-result-max-lines)))
     (mapconcat (lambda (l) (format "%s %s\n" mark l)) tail ""))))

(defun claude-buffer--result-summary (data)
  "DATA (resultイベント)から所要時間・コスト・ターン数の1行サマリーを作る."
  (let ((seconds (/ (or (alist-get 'duration_ms data) 0) 1000.0))
        (cost (or (alist-get 'total_cost_usd data) 0))
        (turns (or (alist-get 'num_turns data) 0))
        (err (eq (alist-get 'is_error data) t)))
    (format "[%s: %.1f秒 / $%.4f / %dターン]\n"
            (if err "エラー" "完了") seconds cost turns)))

(defun claude-buffer--handle-json-line (line)
  "LINE (JSONL一行)をパースして、表示すべき部分をバッファに追加する.
assistantのtext/tool_use、userのtool_result、権限拒否、結果サマリーを扱う."
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
                  (claude-buffer--append-output text))))
             ((equal (alist-get 'type block) "tool_use")
              (claude-buffer--append-output (claude-buffer--tool-use-summary block))))))
         ((equal type "user")
          (dolist (block (alist-get 'content (alist-get 'message data)))
            (when (equal (alist-get 'type block) "tool_result")
              (claude-buffer--append-output (claude-buffer--tool-result-summary block)))))
         ((and (equal type "system") (equal (alist-get 'subtype data) "permission_denied"))
          (claude-buffer--append-output
           (format "[権限拒否: %s — %s]\n"
                   (or (alist-get 'tool_name data) "?")
                   (or (alist-get 'decision_reason data) (alist-get 'message data) "?"))))
         ((equal type "result")
          (claude-buffer--finish-if-no-text)
          (claude-buffer--stop-turn-timer)
          (claude-buffer--append-output (concat "\n" (claude-buffer--result-summary data))))))
    (error
     (message "claude-buffer: JSON行のパースに失敗: %s" (error-message-string err)))))

(defun claude-buffer--filter (proc chunk)
  "プロセスフィルタ. CHUNK を溜めて改行ごとにJSON行として処理する."
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
  "プロセス終了などを知らせるセンチネル."
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
  "マーカー以降を1メッセージとしてclaudeへ送信し、
claude> Thinking... と次の user> プロンプトを表示する.
C-c C-c にキーバインドするだけの関数なのでM-xには出さない(interactive無し)."
  (let ((text (string-trim
               (buffer-substring-no-properties
                claude-buffer--input-marker (point-max)))))
    (if (string-empty-p text)
        (message "claude-buffer: 送信する入力がありません")
      (goto-char (point-max))
      (insert claude-buffer--separator)
      (insert (propertize "claude> " 'face 'bold))
      (setq claude-buffer--claude-output-marker (point-marker))
      (insert claude-buffer--thinking-text)
      (insert claude-buffer--separator)
      (insert (propertize "user> " 'face 'bold))
      (setq claude-buffer--input-marker (point-marker))
      (setq claude-buffer--awaiting-first-text t)
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
    ;; claude-buffer--send は名前付きのinteractiveコマンドにせず、
    ;; ここで無名lambdaとしてバインドすることでM-x補完に出てこないようにする.
    ;; RETは特にrebindしない(バッファ標準の改行のまま).
    (define-key map (kbd "C-c C-c") (lambda () (interactive) (claude-buffer--send)))
    map)
  "claude-buffer-mode 用のキーマップ.
送信は C-c C-c で行う. Shift+Enterでの送信/改行切り替えは、多くの
ターミナルエミュレータがShift+Enterを素のEnterと区別できないため
採用していない(詳細はファイル冒頭のCommentary参照).")

(define-derived-mode claude-buffer-mode fundamental-mode "Claude"
  "claude -p --input-format/--output-format stream-json と会話する為の
プレーンなEmacsバッファ. TUIを経由しないので、移動・検索・コピペは
普通のバッファ操作がそのまま使える."
  :interactive nil)

(defun claude-buffer--dir-label (dir)
  "DIR (パス)の表示用ラベル(末尾のディレクトリ名)を返す."
  (file-name-nondirectory (directory-file-name (expand-file-name dir))))

(defun claude-buffer--sanitize-label (s maxlen)
  "S をバッファ名に使える形に整形する(改行・*を除去し、MAXLEN文字に切り詰め)."
  (let ((s (string-trim (replace-regexp-in-string "[\n\r*]" " " (or s "")))))
    (if (> (length s) maxlen)
        (concat (substring s 0 maxlen) "…")
      s)))

(defun claude-buffer--start (&optional resume-id history-file summary)
  "新しいclaudeチャットバッファとプロセスを開始する.
RESUME-ID が非nilなら `--resume RESUME-ID' を付けて再開する.
HISTORY-FILE が非nilなら、そのセッションの過去ログをバッファ先頭に再現する.
SUMMARY はそのセッションの最初の発言など、名前に使う内容ベースのラベル.
プロセスのカレントディレクトリは呼び出し時の `default-directory' を使う.
バッファ名は new なら *claude:フォルダ名*、resume なら
*claude:フォルダ名:内容ラベル* (取れなければセッションID先頭8桁) にする."
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
  "新しいclaudeチャットバッファとプロセスを開始する(カレントディレクトリのまま)."
  (interactive)
  (claude-buffer--start))

(defun claude-buffer--search-git-root (dir)
  "DIR から上へ辿って `.git' があるディレクトリを探して返す(なければnil).
DIR が `~' 配下にある場合、探索は `~' までに限り、それより上の祖先
ディレクトリは見ない(無関係な親ディレクトリのgitリポジトリを誤検出
しないため)."
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
  ".repo ディレクトリがあればそこを、なければ `~' までの範囲でgitルートを、
それでもなければ project.el が分かるプロジェクトルートを、
どれもなければ default-directory を返す
(claude-custom-project-root と同じ考え方)."
  (let ((repo-root (locate-dominating-file default-directory ".repo")))
    (cond
     (repo-root repo-root)
     ((claude-buffer--search-git-root default-directory))
     ((project-current) (project-root (project-current)))
     (t default-directory))))

;;;###autoload
(defun claude-buffer-new ()
  "フォルダに依存しない、その場限りの新規チャットを開始する.
確認なしで ~/claude-chats/misc を使う."
  (interactive)
  (let ((default-directory (expand-file-name "misc" "~/claude-chats")))
    (claude-buffer--start)))

;;;###autoload
(defun claude-buffer-new-here ()
  "カレントフォルダが属するプロジェクトルートで新規チャットを開始する."
  (interactive)
  (let ((default-directory (claude-buffer--project-root)))
    (claude-buffer--start)))

(defvar claude-buffer-projects-dir "~/.claude/projects/"
  "Claude Codeのセッション(JSONL)が保存されているディレクトリ.")

(defun claude-buffer--encode-dir (dir)
  "DIR (絶対パス)をClaude Codeのプロジェクトディレクトリ名に変換する."
  (replace-regexp-in-string "/" "-" (directory-file-name (expand-file-name dir))))

(defun claude-buffer--all-session-files ()
  "全プロジェクトのセッションファイル(.jsonl)を新しい順で返す."
  (let ((root (expand-file-name claude-buffer-projects-dir)))
    (sort
     (cl-loop for dir in (and (file-directory-p root)
                               (directory-files root t "^[^.]"))
              when (file-directory-p dir)
              append (directory-files dir t "\\.jsonl\\'"))
     #'file-newer-than-file-p)))

(defun claude-buffer--session-files-here ()
  "カレントプロジェクトのセッションファイル(.jsonl)だけを新しい順で返す."
  (let ((dir (expand-file-name (claude-buffer--encode-dir (claude-buffer--project-root))
                                claude-buffer-projects-dir)))
    (sort (and (file-directory-p dir) (directory-files dir t "\\.jsonl\\'"))
          #'file-newer-than-file-p)))

(defun claude-buffer--session-title (file)
  "FILE (セッションjsonl)全体から `ai-title' レコード
(claude本体やclaude-buffer-rename-sessionが書き込むもの)を探し、
一番最後に見つかったものを返す(なければnil).
末尾の一部だけを見る実装だと、renameした後も会話が続いて追記され続ける
うちに古いレコードになってしまう(会話中のセッションで実際に起きた)ため、
ファイル全体を対象にする(claude-buffer--render-historyと同じ考え方)."
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
  "FILE (セッションjsonl)から (cwd . preview) を取り出す. 失敗時は(nil . nil).
preview は末尾に ai-title レコード(claude-buffer-rename-sessionで
付けたものを含む)があればそれを優先し、なければ先頭のuserメッセージ
から作る."
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
  "FILES から completing-read 用の候補alistを作る.
値は (id cwd file preview) のリスト."
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
  "CANDIDATES (alist)を、並び順を保ったまま使えるcompletion tableにする.
completing-readの既定UIはラベルをアルファベット順に並べ替えてしまい、
ラベル先頭の日付文字列のせいで古い順になってしまうため、
display-sort-function/cycle-sort-function を identity にして
CANDIDATES(新しい順)の並びをそのまま使わせる."
  (lambda (string pred action)
    (if (eq action 'metadata)
        '(metadata (display-sort-function . identity)
                    (cycle-sort-function . identity))
      (complete-with-action action candidates string pred))))

(defun claude-buffer--read-session (files prompt)
  "FILES から completing-read でセッションを選ばせ、(id cwd file preview) を返す.
デフォルトは一番新しいセッションで、候補一覧も新しい順に並ぶ."
  (let ((candidates (claude-buffer--session-candidates files)))
    (if (null candidates)
        (user-error "claude-buffer: セッションが見つかりません")
      (let* ((default (caar candidates))
             (choice (completing-read (format "%s (default %s): " prompt default)
                                       (claude-buffer--completion-table candidates)
                                       nil t nil nil default)))
        (cdr (assoc choice candidates))))))

(defun claude-buffer--render-history (file)
  "FILE (セッションjsonl)から、userとclaudeのテキストだけを
user>/claude> プロンプト付きの文字列として再構成する."
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
  "SESSION-ID に接続したままの claude-buffer-mode バッファを探す(なければnil).
resumeしようとしたセッションに既にプロセスがぶら下がっている場合、
同じセッションファイルへ二重に書き込んで壊さないようにするため使う."
  (cl-find-if
   (lambda (buf)
     (with-current-buffer buf
       (and (derived-mode-p 'claude-buffer-mode)
            (equal claude-buffer--session-id session-id)
            (process-live-p claude-buffer--process))))
   (buffer-list)))

(defun claude-buffer--resume-session (files)
  "FILES の中からセッションを選ばせ、--resume で再開するバッファを作る.
選んだセッションに既に生きているバッファがあれば、新規に開かず
そのバッファへ切り替えるだけにする(二重接続を防ぐため)."
  (pcase-let ((`(,id ,cwd ,file ,preview) (claude-buffer--read-session files "Session")))
    (let ((live (claude-buffer--find-live-buffer-for-session id)))
      (if live
          (progn
            (message "claude-buffer: 既に開いているバッファに切り替えます")
            (switch-to-buffer live))
        (let ((default-directory (if cwd (expand-file-name cwd) default-directory)))
          (claude-buffer--start id file preview))))))

;;;###autoload
(defun claude-buffer-resume ()
  "全プロジェクト横断で、セッション一覧から選んで再開する."
  (interactive)
  (claude-buffer--resume-session (claude-buffer--all-session-files)))

;;;###autoload
(defun claude-buffer-resume-here ()
  "カレントプロジェクトのセッションだけを対象に、選んで再開する."
  (interactive)
  (claude-buffer--resume-session (claude-buffer--session-files-here)))

(defun claude-buffer--remove-session (files)
  "FILES の中からセッションを選ばせ、そのjsonlファイルを削除する.
生きているバッファ(プロセス)がまだ繋がっているセッションは削除できない."
  (pcase-let ((`(,id ,cwd ,file ,_preview) (claude-buffer--read-session files "Remove session")))
    (when (claude-buffer--find-live-buffer-for-session id)
      (user-error "claude-buffer: このセッションはまだ開いています。先にバッファを閉じてください"))
    (when (yes-or-no-p (format "Delete session %s [%s]? " id (or cwd "?")))
      (delete-file file)
      (message "claude-buffer: セッションを削除しました: %s" id))))

;;;###autoload
(defun claude-buffer-remove-session ()
  "全プロジェクト横断で、セッション一覧から選んで削除する.
生きているバッファ(プロセス)がまだ繋がっているセッションは削除できない."
  (interactive)
  (claude-buffer--remove-session (claude-buffer--all-session-files)))

;;;###autoload
(defun claude-buffer-remove-session-here ()
  "カレントプロジェクトのセッションだけを対象に、選んで削除する."
  (interactive)
  (claude-buffer--remove-session (claude-buffer--session-files-here)))

(defun claude-buffer--rename-live-buffer (session-id title)
  "SESSION-ID に接続したまま生きているバッファがあれば、
TITLE を使ってそのバッファ名も付け直す(なければ何もしない)."
  (let ((buf (claude-buffer--find-live-buffer-for-session session-id)))
    (when buf
      (with-current-buffer buf
        (rename-buffer
         (format "*claude:%s:%s*"
                 (claude-buffer--dir-label default-directory)
                 (claude-buffer--sanitize-label title 20))
         t)))))

(defun claude-buffer--rename-session-file (file)
  "FILE (セッションjsonl)に、ミニバッファで入力させた新しい名前を
`ai-title' レコードとして追記する(claude本体が書き込む形式と同じ).
既存の内容は一切変更・削除しない. このセッションに生きているバッファが
あれば、そのバッファ名も付け直す."
  (let* ((session-id (file-name-base file))
         (current (claude-buffer--session-title file))
         (title (string-trim (read-string "New name: " current))))
    (when (string-empty-p title)
      (user-error "claude-buffer: 名前が空です"))
    (with-temp-buffer
      (insert (json-encode `((type . "ai-title")
                              (aiTitle . ,title)
                              (sessionId . ,session-id)))
              "\n")
      (write-region (point-min) (point-max) file t))
    (claude-buffer--rename-live-buffer session-id title)
    title))

(defun claude-buffer--rename-session (files)
  "FILES の中からセッションを選ばせ、名前を付け直す."
  (pcase-let ((`(,_id ,_cwd ,file ,_preview) (claude-buffer--read-session files "Rename session")))
    (let ((title (claude-buffer--rename-session-file file)))
      (message "claude-buffer: 名前を変更しました: %s" title))))

;;;###autoload
(defun claude-buffer-rename-session ()
  "全プロジェクト横断で、セッション一覧から選んで名前を付け直す.
session jsonl の末尾に `ai-title' レコードを追記するだけで、
既存の内容は一切変更・削除しない(claude本体と同じ仕組みに乗る)."
  (interactive)
  (claude-buffer--rename-session (claude-buffer--all-session-files)))

;;;###autoload
(defun claude-buffer-rename-session-here ()
  "カレントプロジェクトのセッションだけを対象に、選んで名前を付け直す."
  (interactive)
  (claude-buffer--rename-session (claude-buffer--session-files-here)))

(provide 'claude-buffer)
;;; claude-buffer.el ends here
