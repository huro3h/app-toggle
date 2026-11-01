#!/bin/bash
# app-toggle の動作に必要なものが揃っているかを確かめる。setup.rb の最初にも自動で走る。
#   Ruby が古い・無い状態でも結果を出せるよう、Ruby ではなく sh で書いている。
#   /bin/bash は 3.2 なので、連想配列などの新しい機能は使わない。
#
#   exit 0 = 全て揃っている / 1 = 足りないものがある

RUBY_MIN="4.0" # 3 以下はサポート対象外
MACOS_MIN="10.15" # NSWorkspace.OpenConfiguration が使える最初の版
SWIFT_MIN="5.7"   # daemon が `if let x {` の省略形を使っている
RUBY_LIBS="optparse json open3 io/console fileutils"

failed=0
ok()   { printf '  \033[32mOK\033[0m  %s\n' "$1"; }
ng()   { printf '  \033[31mNG\033[0m  %s\n' "$1"; [ -n "$2" ] && printf '        → %s\n' "$2"; failed=1; }
info() { printf '  --  %s\n' "$1"; }

# a >= b なら真。sort -V は macOS 標準の sort にもある。
version_ge() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$2" ]; }

echo 'app-toggle の動作環境を確認しています'

# ---- macOS -------------------------------------------------------------------
if [ "$(uname -s)" != "Darwin" ]; then
  ng "macOS ではありません($(uname -s))"
else
  macos=$(sw_vers -productVersion)
  if version_ge "$macos" "$MACOS_MIN"; then ok "macOS $macos"
  else ng "macOS $macos" "$MACOS_MIN 以上が必要です"; fi
fi

# ---- Command Line Tools / Xcode(daemon のビルド) ----------------------------
# /usr/bin/swiftc は Command Line Tools が無くても全ての Mac に置かれている代理のコマンドで、
# 無い状態で実行すると「インストールしますか?」のダイアログが出る。そのため `command -v swiftc` では
# 有無を判定できず、先に xcode-select -p で確かめる。この順番を逆にしないこと。
if dev=$(xcode-select -p 2>/dev/null) && [ -d "$dev" ]; then
  ok "Command Line Tools / Xcode ($dev)"
  swift_ver=$(swiftc --version 2>/dev/null | sed -n 's/.*Swift version \([0-9][0-9.]*\).*/\1/p' | head -1)
  if [ -z "$swift_ver" ]; then
    ng 'swiftc のバージョンを取得できません' 'xcode-select --install で入れ直してください'
  elif ! version_ge "$swift_ver" "$SWIFT_MIN"; then
    ng "Swift $swift_ver" "$SWIFT_MIN 以上が必要です(Xcode 14 / Command Line Tools 14 以降)。softwareupdate か xcode-select --install で更新してください"
  # macOS を上げた直後などは swiftc が動いても SDK が壊れていることがあるので、
  # daemon が使うフレームワークを実際に読み込ませて確かめる。
  elif out=$(printf 'import AppKit\nimport Carbon.HIToolbox\n' | swiftc -typecheck - 2>&1); then
    ok "Swift $swift_ver(AppKit / Carbon を読み込める)"
  else
    if printf '%s' "$out" | grep -qi 'license'; then
      ng 'Xcode のライセンスに同意していません' 'sudo xcodebuild -license accept(管理者権限が必要)'
    else
      ng 'swiftc で AppKit / Carbon を読み込めません' 'xcode-select --install で入れ直してください'
      printf '%s\n' "$out" | head -3 | sed 's/^/        /'
    fi
  fi
else
  ng 'Command Line Tools も Xcode も入っていません' 'xcode-select --install'
fi

# ---- Ruby(TUI と setup.rb) --------------------------------------------------
# TUI は #!/usr/bin/env ruby で起動するので、PATH で最初に見つかる ruby を確かめる。
if command -v ruby >/dev/null 2>&1; then
  ruby_path=$(command -v ruby)
  ruby_ver=$(ruby -e 'print RUBY_VERSION' 2>/dev/null)
  if version_ge "$ruby_ver" "$RUBY_MIN"; then
    ok "Ruby $ruby_ver ($ruby_path)"
    missing=""
    for lib in $RUBY_LIBS; do
      ruby -e "require '$lib'" >/dev/null 2>&1 || missing="$missing $lib"
    done
    if [ -z "$missing" ]; then ok "Ruby 標準ライブラリ ($RUBY_LIBS)"
    else ng "Ruby のライブラリを読み込めません:$missing" 'Ruby を入れ直してください(どれも標準添付)'; fi
  else
    ng "Ruby $ruby_ver ($ruby_path)" "Ruby 4 以上が必要です。3 以下はサポート対象外です(rbenv なら: rbenv install -l で 4.x を選ぶ)"
  fi
else
  ng 'ruby が見つかりません' 'Ruby 4 以上を入れてください'

fi

# ---- macOS 標準のコマンド ------------------------------------------------------
for cmd in launchctl plutil ps; do
  if command -v "$cmd" >/dev/null 2>&1; then ok "$cmd"
  else ng "$cmd が見つかりません" 'macOS 標準のコマンドです。PATH を確認してください'; fi
done

# ---- Homebrew(任意) ----------------------------------------------------------
# 必須ではない。setup.rb が app-toggle コマンドのリンクを置く先の第一候補が Homebrew の bin。
if command -v brew >/dev/null 2>&1; then
  info "Homebrew $(brew --prefix)(app-toggle コマンドのリンク先に使う。任意)"
else
  info 'Homebrew なし(任意。リンクは /usr/local/bin か ~/bin に置く)'
fi

echo
if [ "$failed" -eq 0 ]; then
  echo '必要なものは全て揃っています。'
else
  echo '足りないものがあります。上の NG を解消してから setup.rb を実行してください。'
fi
exit "$failed"
