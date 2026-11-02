---
name: app-toggle
description: アプリごとのショートカットキーで表示・隠すを切り替える macOS 個人ツール app-toggle の改修・設定・launchd 常駐。ホットキー登録(Carbon RegisterEventHotKey)、前面アプリでの無効化、TUI での割り当て、Swift daemon のビルドを扱うときに参照。
---

# `app-toggle` — アプリの表示・隠すをショートカットで切り替える

実体: `~/projects/app-toggle/`。構成と TUI の作りは `app-respawn` を下敷きにしている
(アプリ列挙・raw モードの絞り込み UI・`setup` の流儀は同じ。違いだけをここに書く)。

## 構成と役割分担

| 部品 | 言語 | 理由 |
|---|---|---|
| `app-toggle-daemon.swift` | Swift | グローバルホットキーは常駐プロセスが登録するしかなく、Carbon/AppKit を素直に呼べるのが Swift |
| `app-toggle.rb` | Ruby | 割り当て用 TUI。`app-respawn --config` のコードを流用できる |
| `setup.rb` | Ruby | `swiftc` でビルド → plist 生成 → `launchctl bootstrap` → PATH リンク |

- launchd が起動するのは**コンパイル済みバイナリ**(`build/`、git 管理外)で、Ruby は介さない。
  app-respawn が踏んだ「rbenv で Ruby を上げると TCC の許可が切れる」問題がそもそも起きない
- **キー指定の解釈は daemon だけが持つ。** TUI は `app-toggle-daemon --parse SPEC` を呼んで
  「正規形<TAB>表示」を受け取る。キー表を Ruby にも持つと片方だけ直してずれるため
- TUI は保存後に `launchctl kill SIGHUP` を送り、daemon が書く `読み込み完了:` の行が出るまで
  ログを追って登録結果を表示する。**この文言は両方のファイルで揃える**(`RELOAD_DONE`)

## ホットキーの方式

**Carbon の `RegisterEventHotKey` を使う。許可が一切要らない**のが決め手。
CGEventTap や `NSEvent.addGlobalMonitorForEvents` はアクセシビリティ/入力監視の許可が要るうえ、
ターミナルや launchd 経由だと許可の主体がややこしい(app-respawn で責任プロセス問題を踏んだ)。

- 他のアプリが同じ組み合わせを先に登録していると `-9878`(`eventHotKeyExistsErr`)。
  ログに `NG ... 他のアプリが使用中` と出る
- Carbon のハンドラは C 関数ポインタなのでクロージャで捕捉できない。`targets` など状態はグローバル変数
- SIGHUP は `DispatchSource.makeSignalSource` でメインキューに受ける(シグナルハンドラ内で Carbon を呼ばない)

## 切り替えの実装

最前面なら `NSRunningApplication.hide()`、それ以外は全部
`NSWorkspace.openApplication(at:configuration:)`(`activates = true`)に任せる。
起動済み→前面化、隠れている→再表示、ウィンドウ無し→reopen(Dock クリック相当)、未起動→起動、を
1つの呼び出しで済ませられる。`activate()` で場合分けしない。

> [!NOTE]
> macOS 14 以降は「協調的アクティベーション」で、前面でないプロセスからの `activate` が拒否されうる。
> `.prohibited`(Dock 無し)の launchd 常駐から `openApplication` で前面化できることは、
> 2026-11-02 に launchd 配下で実測済み(合成キー入力で 起動→隠す→表示→隠す を確認)。
> 手動実行だけで確かめないこと(app-respawn の教訓)。

## 前面アプリでの無効化(`disabled_in`)

IDE のようにショートカットが多いアプリと衝突させないための機能。
**押されたときに無視するだけでは駄目**で、`RegisterEventHotKey` は押された時点でキーを横取りするので
前面のアプリに届かない。そのため `NSWorkspace.didActivateApplicationNotification` を監視し、
除外アプリが前面に来たら**全部 `UnregisterEventHotKey`**、離れたら登録し直す(`applyFrontmost`)。

- 代償として、除外アプリにいる間はそのアプリ自身を隠すキーも効かない。README に明記してある
- 再開のたびに全件をログへ書くと TUI が読む結果が埋もれるので、再開時は失敗だけを書く
- 除外アプリが前面のまま SIGHUP で読み直したときは、一度登録して結果をログに出してから外す
  (登録できるかどうかを確かめられるように)

### 切り替わりの表示(`showHUD`)

無効/有効が切り替わったら、マウスのある画面の右上に1秒だけパネルを出す
(`~/.hammerspoon/init.lua` の起動中バナーと同じ位置・配色)。

- **通知センターは使わない。** `UNUserNotificationCenter` は署名済みのアプリバンドルと通知の許可が要り、
  launchd から起動する素のバイナリでは使えない。さらに、消えるまでの時間を指定できない
- `NSPanel` を `.borderless` + `.nonactivatingPanel` で作り、`orderFrontRegardless()` で出す。
  前面のアプリを奪わず、`ignoresMouseEvents` でクリックも素通しする
- **活性化ポリシーは `.accessory`。** 最初は `.prohibited` にしていたが、こちらはウィンドウを出せない。
  `.accessory` でも Dock には出ず、自分から前面に出ることもないので見た目は変わらない
- 立て続けに切り替わったときは、表示を差し替えてタイマーを数え直す
- 文字色と 1px の枠線は無効化=赤・有効化=緑(枠は `layer.borderColor` を表示のたびに塗り替える)。背景が暗いので `systemRed` / `systemGreen` より明るい値を直書きしている
- **確認には `screencapture` ではなくウィンドウ一覧を使う。** 2026-11-02 の確認では、パネルは
  実際に画面に出ていた(ユーザーが目視で確認)のに、`screencapture -x` の画像には写らなかった。
  `CGWindowListCopyWindowInfo([.optionOnScreenOnly], ...)` で、所有者が `app-toggle-daemon` の
  ウィンドウを探すほうが確実(表示直後にあり、1.2秒後に消えていれば正しい)

## キー指定の書式

`ctrl+opt+t` のように書く。**押して記録する方式にしなかった**のは、ターミナルの TUI には
⌘ を含む組み合わせが届かないため(ターミナルが先に使う)。正規形は ⌃⌥⇧⌘ の順(Apple のメニュー表記と同じ)。

- 修飾なしは F キー(`f\d+`)だけ許す。最初 `hasPrefix("f")` で判定していて、
  素の `f` が通ってしまうバグがあった
- 仮想キーコードは物理位置。`kVK_ANSI_*` は US 刻印の名前だが、JIS 配列でも英数字の位置は同じ。
  JIS 固有は `eisu` / `kana` だけ足してある

## 動作環境の確認(`check-requirements.sh`)

`setup.rb` が最初に `system` で呼び、失敗したら何も変更せずに止まる。

- **sh で書いている。** Ruby が古い・無い状態でも結果を出したいため。`/bin/bash` は 3.2 なので新しい機能は使わない。
  バージョン比較は `sort -V`
- **Ruby は 4 以上を要件にした(3 以下はサポート対象外)。** 2026-11-02 にユーザーが決めた。
  コード上は Ruby 3.0 の1行 `def` が最も新しい構文だが、動作を確かめる範囲を絞るため。
  `setup.rb` は Ruby 3 なら読み込めるので、チェックの NG まで表示される。2.x では構文エラーで止まるが、対象外なので構わない
- 確かめるのは TUI が使う「PATH で最初に見つかる `ruby`」。daemon はバイナリなので Ruby に依存しない
- **`command -v swiftc` で有無を判定してはいけない。** `/usr/bin/swiftc` は Command Line Tools が無くても
  全ての Mac にある代理のコマンドで、無い状態で実行するとインストールのダイアログが出る。
  先に `xcode-select -p` で Command Line Tools / Xcode の有無を見て、あるときだけ `swiftc` を呼ぶ
- **Swift 5.7 以上を要件にしている**(`SWIFT_MIN`)。daemon が `if let error {` の省略形(5.7 から)を使うため。
  Xcode 14 / Command Line Tools 14 以降が該当。daemon に新しい構文を使ったら、ここも上げること
- バージョンに加えて `import AppKit` / `import Carbon.HIToolbox` を `-typecheck` に通して確かめる。
  macOS を上げた直後などに SDK だけ壊れていることがあるため。エラー文に license を含むときは
  Xcode のライセンス未同意として、`sudo xcodebuild -license accept` を案内する(Xcode.app を使っている場合だけ起きる)
- Homebrew は任意(リンク先の候補になるだけ)なので、NG ではなく情報として出す
- 失敗時の確認: 偽の `ruby`(`printf 3.3.6` するだけ)を PATH の先頭に置き、本物の ruby で `setup.rb --apply` を実行する。
  Swift も同様に、`--version` で古い版を名乗る偽の `swiftc`、ライセンスのエラーを返す偽の `swiftc` で確かめた

## setup.rb の入れ替え

`launchctl bootout` は外し終わる前に戻ることがあり、すぐ `bootstrap` すると
`Bootstrap failed: 5: Input/output error` で失敗する(2026-11-02 に、連続して `--apply` したときに踏んだ)。
`launchctl print` が失敗する(=外れた)まで最大5秒待ってから読み込む。

## TUI の操作キー

印字文字は検索とキー指定の入力に吸われるので、操作は全て制御キー。
保存は `Enter` ではなく `^S`(`Enter` を割り当てに使うため)。`io/console` の `raw` は IXON を外すので、
`^S` が端末のフロー制御に食われることはない。

全角幅の計算(`WIDE_CHAR`)に ⌃⌥⇧⌘ を入れてはいけない。East Asian Width が Neutral で、
ターミナルでは1桁で描かれる。

## テストの仕方

- 割り当ての解釈: `build/app-toggle-daemon --parse 'opt+ctrl+t'`
- 実際の切り替え: テスト用の設定と別ラベルの plist を作り、`launchctl bootstrap` → `kickstart` で
  launchd 配下に置いてから、`osascript -e 'tell application "System Events" to key code 80 using {control down, option down, shift down}'`
  で合成キーを送る(⌃⌥⇧F19 なら実利用と衝突しない)。前面アプリは System Events の
  `frontmost` で確かめる。テスト対象は電卓など無害なアプリにし、元から起動していなかったものは終わらせる
- TUI: Ruby の `PTY.spawn` で操作する。エスケープシーケンスは1バイトずつ送らない(app-respawn と同じ注意)
- **本番の常駐で試すときは、普段使うキーを割り当てない。** 開発中にテストで `ctrl+t` を割り当て、
  一時的に Ctrl+T がシステム全体で奪われた

## リリース

方式はワークスペース共通(`projects-workspace` skill のルール4、`/release`)。
バージョンは `app-toggle.rb` 冒頭の `VERSION` 定数が持つ(`--version` で表示)。
リリース時は定数・CHANGELOG・タグの3つを揃える(app-respawn と同じ持ち方)。
daemon(Swift)側はバージョンを持たない。
