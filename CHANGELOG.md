# Changelog

このプロジェクトの主な変更点を記録する。
書式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) に、バージョンは
[セマンティック バージョニング](https://semver.org/lang/ja/) に従う。

## [Unreleased]

## [1.2.0] - 2026-11-02

### Added

- 設定ファイルの雛形 `app-toggle.example.json`
- 設定ファイルを dotfiles などで git 管理する手順(シンボリックリンクにする)を README に追加

## [1.1.0] - 2026-11-02

### Added

- 動作環境(macOS・Swift 5.7 以上・Ruby 4 以上など)を確かめる `check-requirements.sh`。`setup.rb` の最初に自動で実行され、足りないものがあれば何も変更せずに止まる

## [1.0.0] - 2026-11-02

### Added

- アプリごとのショートカットキーで、表示・隠す・起動を切り替える常駐(launchd の LaunchAgent)
- インストール済みアプリを絞り込みながらショートカットを割り当てる TUI。保存すると常駐へ即座に反映され、登録結果が表示される
- 指定したアプリが前面にある間は、ショートカットを全て無効にしてキーをそのアプリへ素通しする設定
- 無効/有効が切り替わったときに、画面右上へ1秒だけ表示を出す
- ビルド・LaunchAgent の登録・PATH へのリンクをまとめて行う `setup.rb`
