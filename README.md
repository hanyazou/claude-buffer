# claude-buffer.el

`claude -p --input-format stream-json --output-format stream-json` をパイプで起動し、
標準入出力の JSONL だけで Claude Code CLI とやり取りする Emacs パッケージです。
vterm 越しに TUI を操作するのではなく、普通の Emacs バッファとしてチャットするので、
移動・検索・コピペがいつも通り使えます。

## インストール

`claude-buffer.el` を `load-path` の通ったディレクトリに置いて:

```elisp
(require 'claude-buffer)
```

## コマンド

- `claude-buffer` : カレントディレクトリのまま新規チャットを開始する(素の版)
- `claude-buffer-new` : フォルダに依存しない新規チャット(デフォルト `~/claude-chats/misc`)
- `claude-buffer-new-here` : カレントのプロジェクトルートで新規チャットを開始する
- `claude-buffer-resume` : 全プロジェクト横断でセッション一覧から選んで再開する
- `claude-buffer-resume-here` : カレントプロジェクトのセッションから選んで再開する

## キー操作

- `C-c C-c` : マーカー以降(入力中のテキスト)をまとめて送信する
- `RET` : 改行する(複数行の入力を組み立てる用。`C-j` も同じ)

## 権限まわりについて

現状は試作用の固定設定です。`/tmp` 相当のファイル作成・変更、bash 実行(コンパイル・
実行含む)、Web 検索を `allowedTools` で許可し、それ以外は都度確認せず
`acceptEdits` で進めます。利用環境に合わせて `claude-buffer-command` を調整してください。

## Docker コンテナ内の claude を使う

claude を Docker コンテナの中だけで動かし、ホストの Emacs からラッパースクリプト
経由で使うための構成例を [contrib/docker/](contrib/docker/) に置いています。
パッケージ本体の動作には不要な、任意の補助ファイルです。

## ステータス

基本的な機能は一応動作します。
