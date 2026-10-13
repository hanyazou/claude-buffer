# Docker コンテナ内の claude を claude-buffer から使う

Claude Code CLI を Docker コンテナ (Ubuntu) の中だけで動かし、ホストの Emacs の
`claude-buffer.el` からはラッパースクリプト経由で呼び出すための構成例です。
claude-buffer 本体の動作には不要な、任意の補助ファイルです。

| ファイル | 内容 |
|---|---|
| `Dockerfile` | ホストと同じ UID のユーザー `user` を持つ Ubuntu イメージ |
| `build_image.sh` | イメージ `claude-ubuntu` をビルドするスクリプト |
| `run_container.sh` | コンテナ `claude-ubuntu` を作成・起動するスクリプト |
| `claude-wrapper.sh` | パス上に `claude` として置くラッパーのサンプル |

## 仕組み

`claude-buffer.el` はパス上の `claude` を起動し、セッション一覧はホストの
`~/.claude/projects/` を直接読みます。そのため次の 2 点を揃えています。

- 作業ディレクトリは、ホストと **同じ絶対パス** でコンテナにマウントする。
  claude が記録する cwd とセッションの保存先ディレクトリ名がホストのパスと
  一致し、`-here` 系や resume 系のコマンドがそのまま動きます。
- `~/.claude` をホストとコンテナで共有する。Emacs からセッションの jsonl が
  見えるようになります。

## 前提: sudo なしで docker が使えること

Docker 自体のインストールはここでは扱いません。ただし、ラッパーは Emacs から
直接起動されるので、**一般ユーザーが `sudo` なしで `docker` を実行できる** 必要が
あります。以下のスクリプトも `sudo` を付けずに実行してください。

確認方法:

```
docker run --rm hello-world
```

`permission denied while trying to connect to the Docker daemon socket` のような
エラーになる場合は、Docker のインストール手順のうち「root 以外のユーザーで
使う」設定が済んでいません。Linux では通常、ユーザーを `docker` グループに
追加してログインし直します。

```
sudo usermod -aG docker "$USER"
```

Emacs からも同じ権限で見えていることを `M-! docker ps` で確認できます
(グループ追加前から起動している Emacs は、ログインし直してから起動し直します)。

## 1. イメージをビルドする

```
./build_image.sh
```

イメージ内のユーザー `user` は、ホストのユーザーと同じ UID / GID で作られます。
イメージ名は既定で `claude-ubuntu` です。`IMAGE_NAME=...` で変更できます。

## 2. コンテナを起動する

```
./run_container.sh
```

マウントするホスト側のディレクトリを作成してから `docker run` します。
マウントは次の 3 つです。

- `~/workspace` : プロジェクトを置くディレクトリ。環境に合わせてスクリプトを
  変更・追加してください (必ず `ホストのパス:同じパス` の形にします)。
- `~/claude-chats` : `claude-buffer-new` の既定の作業場所 (`~/claude-chats/misc`)。
- `~/.claude` : セッションや設定。コンテナ内の `/home/user/.claude` と共有します。

確認:

```
docker exec -i claude-ubuntu id -u
docker exec -it claude-ubuntu bash
```

## 3. コンテナ内に claude をインストールする

`docker exec -it claude-ubuntu bash` でコンテナに入って実行します。

```
curl -fsSL https://claude.ai/install.sh | bash

echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
export PATH="$HOME/.local/bin:$PATH"

claude --version
```

## 4. 認証する

ホストから TUI を一度起動してログインします。

```
docker exec -it claude-ubuntu /home/user/.local/bin/claude
```

## 5. ラッパーをパス上に置く

`claude-wrapper.sh` を、パスの通ったディレクトリに `claude` という名前でコピー
します。

```
cp claude-wrapper.sh ~/bin/claude
chmod +x ~/bin/claude
```

コンテナ名を変えた場合は、環境変数 `CLAUDE_CONTAINER_NAME` を設定するか
スクリプトを書き換えてください。

ホストにも claude をインストールしている場合 (`~/.local/bin/claude` など) は、
次の 2 点に注意してください。

- パス上で先に見つかった方が使われます。ラッパーが先に来るようにしてください。
  シェルでは `type -a claude`、Emacs では `M-: (executable-find "claude")` で
  確認できます。
- Linux 版の claude は認証情報を `~/.claude` 内のファイルに保存するので、
  ホストが Linux の場合、ホストとコンテナの claude は同じ認証情報を共有します
  (macOS のホストは Keychain に保存するので共有されません)。

これで Emacs から `M-x claude-buffer-new-here` などがコンテナ内の claude で
動作します。

## 制限・注意

- マウントしていないディレクトリで起動すると、`docker exec -w` がコンテナ内に
  そのディレクトリを見つけられずエラーになります。
- ラッパーは `docker exec -i` (TTY なし) で起動するので、claude-buffer のような
  パイプ経由の利用専用です。TUI を使うときは手順 4 のように `-it` で起動して
  ください。
- claude 本体はイメージではなくコンテナ内 (`/home/user/.local`) にインストール
  されるので、コンテナを作り直したら手順 3 をやり直します。認証情報などは
  `~/.claude` に置かれるものについてはホスト側に残ります。
