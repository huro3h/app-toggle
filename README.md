# app-toggle

アプリごとにショートカットキーを割り当て、押すたびに表示・隠すを切り替える macOS 用の個人ツール。
Thor Launcher と同じ動きを、サードパーティのアプリを使わずに再現している。

- 対象のアプリが最前面にある → 隠す
- 背面にある・隠れている・ウィンドウが無い → 前面に出す
- 起動していない → 起動する

## 主な機能

- インストール済みアプリを絞り込みながら、TUI でショートカットを割り当てる(bundle id を調べる必要がない)
- 指定したアプリ(IDE など)が前面にある間は、ショートカットを全て無効にしてキーをそのアプリへ素通しする。
  無効/有効が切り替わると、画面右上に1秒だけ表示が出る
- 常駐は launchd の LaunchAgent。保存すると常駐へ即座に反映され、登録できたかどうかがその場で表示される
- アクセシビリティや入力監視の許可は要らない

## セットアップ

```bash
./setup.rb            # ビルド先・生成先・リンク先の確認(ドライラン)
./setup.rb --apply    # daemon のビルド、LaunchAgent の登録、PATH へのリンク作成
```

`setup.rb --apply` は以下を行う。

1. `app-toggle-daemon.swift` を `build/app-toggle-daemon` にコンパイルする(Xcode の Command Line Tools が必要)
2. `~/Library/LaunchAgents/local.app-toggle.plist` をテンプレートから生成し、`launchctl` で読み込む
3. PATH の通ったディレクトリ(`/opt/homebrew/bin` → `/usr/local/bin` → `~/bin` の順で最初に書き込めるもの)に、
   `app-toggle.rb` へのシンボリックリンクを `app-toggle` という名前で張る

リンクが不要なら `--no-link`、まとめて解除するなら `./setup.rb --uninstall --apply`。
Swift のソースを変更したときも `./setup.rb --apply` をやり直す(ビルドし直して常駐を入れ替える)。

## 使い方

```bash
app-toggle            # 対話的に割り当てる
app-toggle --list     # 割り当ての一覧
app-toggle --reload   # JSON を手で編集した後、常駐に読み直させる
```

```
検索: chrome    4/119件   割り当て 3件   無効 1件

 >   ⌃⌥C            Google Chrome                com.google.Chrome                  ●
     ⌃⌥T            Terminal                     com.apple.Terminal
   X                RubyMine                     com.jetbrains.rubymine             ●
```

| キー | 動作 |
|---|---|
| 文字入力 | 絞り込み(アプリ名と bundle id の両方が対象) |
| ↑↓ / `^P` `^N` | カーソル移動 |
| `Enter` | ショートカットを割り当てる(下の書式で入力し、空のまま Enter で解除) |
| `^D` | 割り当てを解除 |
| `^X` | 「前面にある間は無効」の指定/解除 |
| `^S` | 保存して常駐に反映 |
| `Esc` / `^C` | 取消(ファイルは変更しない) |
| `^U` | 検索クリア |

ショートカットは押して記録するのではなく、文字で書く。ターミナルは ⌘ を含む組み合わせを自分で
使ってしまい、TUI まで届かないため。

```
ctrl+opt+t    cmd+shift+space    f13    ctrl+opt+kana
```

- 修飾キー: `ctrl` `opt` `shift` `cmd`(`control` `option` `alt` `command` も可)
- キー: 英数字、記号(`-` `=` `[` `]` `;` `'` `,` `.` `/` `\` とバッククォート)、`f1`〜`f20`、`space` `return` `tab` `escape` `delete`
  `up` `down` `left` `right` `home` `end` `pageup` `pagedown` `eisu` `kana`
- 修飾キーなしで割り当てられるのは F キーだけ
- 同じ組み合わせを2つのアプリに割り当てることはできない

保存後に「NG ... 他のアプリが使用中」と出たら、そのキーは別のアプリ(Thor Launcher など)が先に使っている。
相手側の割り当てを外して、`app-toggle --reload` を実行する。

### 前面にある間は無効にする

RubyMine のようにショートカットを大量に使うアプリを `^X` で指定しておくと、そのアプリが前面にある間は
app-toggle のショートカットを**全て**外し、キーをそのアプリへ素通しする。

指定したアプリにいる間は、ほかのアプリへ切り替えるショートカットも、そのアプリ自身を隠すショートカットも
効かない(macOS のショートカット登録は、押された時点でキーを横取りする仕組みのため。
押されたときに何もしないだけでは、キーがアプリに届かない)。

無効になったとき・有効に戻ったときは、マウスのある画面の右上(メニューバーの直下)に
「app-toggle 無効化(RubyMine)」を赤、「app-toggle 有効化」を緑の文字と枠線で1秒だけ表示する。
通知センターは使わないので、通知の許可は要らない。

## 設定

`app-toggle.json`(`.gitignore` 済み)。TUI が書き出すので、手で書く必要はない。

```json
{
  "hotkeys": [
    { "bundle_id": "com.apple.Terminal", "key": "ctrl+opt+t" }
  ],
  "disabled_in": ["com.jetbrains.rubymine"]
}
```

環境変数 `APP_TOGGLE_CONFIG` で TUI が読むパスを変えられる(常駐が読むのは plist に書いたパスのまま)。

```bash
# 状態確認 / ログ追尾
launchctl print gui/$(id -u)/local.app-toggle | grep -E 'state|pid'
tail -f ~/Library/Logs/app-toggle.log
```

## 構成

| ファイル | 役割 |
|---|---|
| `app-toggle-daemon.swift` | 常駐本体。ホットキーの登録と表示・隠すの切り替え |
| `app-toggle.rb` | 割り当て用の TUI(Ruby、標準ライブラリのみ) |
| `setup.rb` | ビルド、LaunchAgent の登録、PATH リンクの作成/削除 |
| `local.app-toggle.plist.template` | LaunchAgent のテンプレート |

実装の詳細・設計判断は `.claude/skills/app-toggle/SKILL.md` を参照。

## 要件

macOS / Xcode Command Line Tools(`swiftc`) / Ruby(追加の gem は不要)

## ライセンス

[MIT License](LICENSE)
