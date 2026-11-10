#!/usr/bin/env ruby
# frozen_string_literal: true

# app-toggle
#   アプリごとのショートカットキーを対話的に割り当てる。割り当ては app-toggle.json に保存し、
#   常駐している app-toggle-daemon(Swift)に SIGHUP を送って読み直させる。
#   ホットキーの登録と、表示・隠すの切り替えそのものは daemon が行う。
#
#   exit 0 = OK / 2 = エラー

require 'optparse'
require 'json'
require 'open3'

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = nil

# リリース時はこことタグ(注釈付き・v なしの数字のみ)と CHANGELOG.md を揃える。
VERSION = '1.3.0'

def utf8(str) = str.to_s.dup.force_encoding(Encoding::UTF_8).scrub

# PATH に置く app-toggle はシンボリックリンクなので、realpath を挟んでから隣のファイルを探す。
SELF = File.realpath(__FILE__)
TOOL_ROOT = File.dirname(SELF)

CONFIG_PATH = ENV.fetch('APP_TOGGLE_CONFIG', File.join(TOOL_ROOT, 'app-toggle.json'))
DAEMON = File.join(TOOL_ROOT, 'build', 'app-toggle-daemon')
LABEL = 'local.app-toggle'
LOG = File.join(Dir.home, 'Library', 'Logs', 'app-toggle.log')
# daemon が読み直しを終えたときに出す行。文言は app-toggle-daemon.swift の reload と揃える。
RELOAD_DONE = '読み込み完了:'

def die(msg, code = 2)
  warn "error: #{msg}"
  exit code
end

def load_config
  return { 'hotkeys' => [], 'disabled_in' => [] } unless File.exist?(CONFIG_PATH)

  cfg = JSON.parse(File.read(CONFIG_PATH))
  cfg['hotkeys'] ||= []
  cfg['disabled_in'] ||= []
  cfg
rescue JSON::ParserError => e
  die("設定ファイルが JSON として読めません: #{CONFIG_PATH} (#{e.message})")
end

# キー指定の解釈は daemon に任せる。Ruby 側に同じキー表を持つと、片方だけ直してずれるため。
# 返り値は [正規形, 表示] か、解釈できなければ [nil, エラー文]。
def parse_spec(spec)
  out, err, st = Open3.capture3(DAEMON, '--parse', spec)
  return [nil, utf8(err).strip] unless st.success?

  utf8(out).strip.split("\t", 2)
end

# ---- 常駐への反映 ------------------------------------------------------------

def agent_loaded?
  system('launchctl', 'print', "gui/#{Process.uid}/#{LABEL}", out: File::NULL, err: File::NULL)
end

# SIGHUP を送り、daemon がログに書く登録結果を拾って見せる。登録に失敗するのは主に
# 他のアプリが同じ組み合わせを先に掴んでいるときで、
# それは daemon が実際に登録を試みるまで分からない。
def reload_daemon
  unless agent_loaded?
    puts '  常駐していないため、まだ反映されていません。./setup.rb --apply で常駐させてください。'
    return
  end

  offset = File.exist?(LOG) ? File.size(LOG) : 0
  system('launchctl', 'kill', 'SIGHUP', "gui/#{Process.uid}/#{LABEL}", out: File::NULL, err: File::NULL)

  lines = []
  deadline = Time.now + 3
  while Time.now < deadline
    sleep 0.1
    next unless File.exist?(LOG) && File.size(LOG) > offset

    lines = utf8(File.binread(LOG, nil, offset)).lines.map(&:chomp)
    break if lines.any? { |l| l.include?(RELOAD_DONE) }
  end

  if lines.none? { |l| l.include?(RELOAD_DONE) }
    puts "  反映の結果を確認できませんでした。ログを見てください: #{LOG}"
    return
  end

  puts '  常駐に反映しました:'
  # 先頭の日時は要らないので落とす("2026-11-02 12:34:56 " の20文字)。
  lines.each { |l| puts "    #{l.sub(/\A\S+ \S+ /, '')}" }
end

# ---- アプリの列挙(app-respawn の --config と同じやり方) -----------------------

# CoreServices を入れるのは Finder がそこにいるため。~/Applications は Chrome の PWA などが入る。
APP_DIRS = [
  '/Applications',
  '/System/Applications',
  '/System/Library/CoreServices',
  File.join(Dir.home, 'Applications')
].freeze

# メニューバー常駐やデーモンは前面に出すウィンドウを持たないので一覧に出さない。
def background_only?(info)
  %w[1 true].include?(info['LSUIElement'].to_s) ||
    %w[1 true].include?(info['LSBackgroundOnly'].to_s)
end

# Info.plist は1回の plutil でまとめて JSON にする。キーごとに -extract を呼ぶと遅い。
def app_info(path)
  plist = File.join(path, 'Contents', 'Info.plist')
  return nil unless File.exist?(plist)

  out, _, st = Open3.capture3('plutil', '-convert', 'json', '-o', '-', plist)
  return nil unless st.success?

  d = JSON.parse(utf8(out))
  bid = d['CFBundleIdentifier'].to_s
  return nil if bid.empty? || background_only?(d)

  name = d['CFBundleDisplayName'] || d['CFBundleName'] || File.basename(path, '.app')
  { bid: bid, name: utf8(name.to_s), path: path }
rescue JSON::ParserError
  nil
end

# System Events を使わないので、割り当てを編集するだけで自動化の許可ダイアログが出ることはない。
def installed_apps
  seen = {}
  APP_DIRS.each do |dir|
    next unless File.directory?(dir)

    # 深く辿らないのは Xcode.app のように内部へ大量の .app を抱えるアプリがあるため。
    ['*.app', '*/*.app', '*/*/*.app'].each do |pat|
      Dir.glob(File.join(dir, pat)).each do |path|
        next unless File.directory?(path)
        next if File.dirname(path).include?('.app/')

        info = app_info(path)
        seen[info[:bid]] ||= info if info
      end
    end
  end
  seen.values.sort_by { |a| a[:name].downcase }
end

def running_app_paths
  out, = Open3.capture2('ps', '-axo', 'comm=')
  utf8(out).lines.filter_map { |l| l[%r{\A(.*?\.app)/Contents/MacOS/}, 1] }.uniq
rescue StandardError
  []
end

# 全角を2桁として数える。日本語名のアプリが混ざると桁が崩れるため。
WIDE_CHAR = /[\p{Hiragana}\p{Katakana}\p{Han}\p{Hangul}　-〿！-｠]/
def dwidth(str) = str.each_char.sum { |c| c.match?(WIDE_CHAR) ? 2 : 1 }

def dpad(str, width)
  s = str.to_s
  s = s[0..-2] while dwidth(s) > width
  s + (' ' * (width - dwidth(s)))
end

# ---- 対話設定 ----------------------------------------------------------------

# 矢印キー("\e[A")と Esc 単独は先頭が同じなので、続きが即座に来ているかで見分ける。
ESC_SEQ_WAIT = 0.1

def read_escape_seq
  return nil unless IO.select([$stdin], nil, nil, ESC_SEQ_WAIT)

  $stdin.getch
  return nil unless IO.select([$stdin], nil, nil, ESC_SEQ_WAIT)

  $stdin.getch
end

# 印字文字は全て検索クエリ(とキー指定の入力)に吸われるので、操作は制御キーに割り当てる。
# 保存を Enter にしないのは、Enter をアプリへの割り当てに使っているため。
KEY_CTRL_C = 3
KEY_CTRL_D = 4
KEY_BS     = 8
KEY_LF     = 10
KEY_CR     = 13
KEY_CTRL_N = 14
KEY_CTRL_P = 16
KEY_CTRL_S = 19 # raw モードでは IXON が外れるので、端末のフロー制御に食われない
KEY_CTRL_U = 21
KEY_CTRL_X = 24
KEY_ESC    = 27
KEY_DEL    = 127

def term_rows
  IO.console&.winsize&.first || ($stdout.winsize.first if $stdout.respond_to?(:winsize)) || 24
rescue StandardError
  24
end

def run_tui
  require 'io/console'
  die('対話端末でのみ使えます(パイプやリダイレクト経由では動きません)') unless $stdin.tty? && $stdout.tty?

  $stdout.print('インストール済みアプリを読み込み中...')
  apps = installed_apps
  running = running_app_paths
  $stdout.print("\r\e[K")
  die('インストール済みアプリを1件も検出できませんでした') if apps.empty?

  cfg = load_config
  # bundle id → 正規形のキー指定。1アプリにつき1つ。
  keys = {}
  display = {} # 正規形 → 表示(⌃⌥T)。daemon への問い合わせを1回で済ませるための控え
  broken = []
  cfg['hotkeys'].each do |h|
    canonical, shown = parse_spec(h['key'].to_s)
    if canonical
      keys[h['bundle_id']] = canonical
      display[canonical] = shown
    else
      broken << "#{h['bundle_id']} (#{h['key']}: #{shown})"
    end
  end

  # 前面にある間はホットキーを全部外すアプリ(IDE など、自前のショートカットが多いもの)。
  disabled = cfg['disabled_in'].dup

  known = apps.to_h { |a| [a[:bid], a] }
  # 設定にあるのにディスクで見つからないアプリは、黙って消さず一覧に残す。
  missing = (keys.keys | disabled).reject { |b| known.key?(b) }
                                  .map { |b| { bid: b, name: '(アプリ未検出)', path: nil } }
  entries = missing + apps

  query = ''
  cursor = 0
  top = 0
  note = broken.empty? ? nil : "解釈できない割り当てを無視しました: #{broken.join(', ')}"
  editing = nil # キー指定を入力中のアプリ { entry:, buf: }
  dirty = false
  action = :cancel

  $stdin.raw do
    loop do
      q = query.downcase
      pool = q.empty? ? entries : entries.select { |e| "#{e[:name]} #{e[:bid]}".downcase.include?(q) }
      # 設定済み(割り当て・無効)を先頭にまとめる。並びは安定させたいので sort_by に元の位置を添える。
      list = pool.each_with_index.sort_by do |e, i|
        [keys.key?(e[:bid]) || disabled.include?(e[:bid]) ? 0 : 1, i]
      end.map(&:first)
      cursor = cursor.clamp(0, [list.size - 1, 0].max)

      rows = [term_rows - 8, 3].max
      top = cursor if cursor < top
      top = cursor - rows + 1 if cursor >= top + rows
      top = 0 if list.size <= rows

      out = +"\e[H\e[J"
      out << "検索: #{query}#{editing ? ' ' : "\e[7m \e[0m"}   #{list.size}/#{entries.size}件" \
             "   割り当て #{keys.size}件   無効 #{disabled.size}件#{dirty ? '   (未保存)' : ''}\r\n\r\n"
      if list.empty?
        out << "  該当なし\r\n"
      else
        list[top, rows].each_with_index do |e, i|
          here = top + i == cursor
          shown = keys[e[:bid]] ? display[keys[e[:bid]]] : ''
          run = e[:path] && running.include?(e[:path]) ? '●' : ' '
          off = disabled.include?(e[:bid]) ? 'X' : ' '
          out << (here ? "\e[7m" : '')
          out << " #{here ? '>' : ' '} #{off} #{dpad(shown, 14)} #{dpad(e[:name], 28)} #{dpad(e[:bid], 34)} #{run} "
          out << (here ? "\e[0m" : '')
          out << "\r\n"
        end
      end
      out << "\r\n ● = 起動中   X = 前面にある間はショートカットを全て無効にする\r\n"
      if editing
        out << " #{editing[:entry][:name]} のショートカット: #{editing[:buf]}\e[7m \e[0m\r\n"
        out << " 例: ctrl+opt+t / cmd+shift+space / f13   Enter 決定(空なら解除)   Esc 戻る\r\n"
      else
        out << " 上下 移動   Enter 割り当て   ^D 解除   ^X 無効の切替   ^S 保存   Esc 取消   ^U 検索クリア\r\n"
      end
      out << " #{note}\r\n" if note
      $stdout.print(out)
      note = nil

      ch = $stdin.getch
      next unless ch && ch.valid_encoding?

      if editing
        case ch.ord
        when KEY_CR, KEY_LF
          bid = editing[:entry][:bid]
          if editing[:buf].strip.empty?
            dirty = true if keys.delete(bid)
            editing = nil
            next
          end
          canonical, shown = parse_spec(editing[:buf])
          if canonical.nil?
            note = shown
          elsif (other = keys.find { |b, k| k == canonical && b != bid })
            # 同じ組み合わせを2つ登録すると後の方が daemon で失敗するので、ここで止める。
            note = "#{shown} は既に #{known.dig(other[0], :name) || other[0]} に割り当てています"
          else
            keys[bid] = canonical
            display[canonical] = shown
            dirty = true
            editing = nil
          end
        when KEY_ESC
          editing = nil if read_escape_seq.nil?
        when KEY_CTRL_C then editing = nil
        when KEY_DEL, KEY_BS then editing[:buf] = editing[:buf][0..-2].to_s
        when KEY_CTRL_U then editing[:buf] = ''
        else
          editing[:buf] += ch if ch.match?(/[[:print:]]/)
        end
        next
      end

      entry = list[cursor]
      case ch.ord
      when KEY_CR, KEY_LF
        editing = { entry: entry, buf: keys[entry[:bid]].to_s } if entry
      when KEY_CTRL_D
        if entry && keys.delete(entry[:bid])
          dirty = true
          note = "解除しました: #{entry[:name]}"
        end
      when KEY_CTRL_X
        next unless entry

        dirty = true
        if disabled.delete(entry[:bid])
          note = "無効を解除しました: #{entry[:name]}"
        else
          disabled << entry[:bid]
          note = "#{entry[:name]} が前面にある間は、ショートカットを全て無効にします"
        end
      when KEY_CTRL_S
        action = :save
        break
      when KEY_CTRL_C then break
      when KEY_ESC
        case read_escape_seq
        when 'A' then cursor -= 1
        when 'B' then cursor += 1
        when nil then break # Esc 単独 = 取消
        end
      when KEY_CTRL_P then cursor -= 1
      when KEY_CTRL_N then cursor += 1
      when KEY_DEL, KEY_BS then query = query[0..-2].to_s
      when KEY_CTRL_U then query = ''
      else
        # 空白はアプリ名に含まれうるので検索に使える(app-respawn と違い space に役割が無い)。
        next unless ch.match?(/[[:print:]]/)

        query += ch
        cursor = 0
      end
    end
  end

  $stdout.print("\e[H\e[J")
  unless action == :save
    puts '中止しました(設定ファイルは変更していません)。'
    return
  end

  cfg['hotkeys'] = keys.map { |bid, key| { 'bundle_id' => bid, 'key' => key } }
  cfg['disabled_in'] = disabled
  File.write(CONFIG_PATH, "#{JSON.pretty_generate(cfg)}\n")
  puts "書き込みました: #{CONFIG_PATH} (割り当て #{keys.size}件 / 無効 #{disabled.size}件)"
  reload_daemon
end

def print_list
  cfg = load_config
  if cfg['hotkeys'].empty?
    puts '割り当てはありません。app-toggle で対話的に追加できます。'
  else
    cfg['hotkeys'].each do |h|
      _, shown = parse_spec(h['key'].to_s)
      puts "#{dpad(shown, 14)} #{h['bundle_id']}"
    end
  end
  return if cfg['disabled_in'].empty?

  puts "\n前面にある間は無効: #{cfg['disabled_in'].join(', ')}"
end

opts = {}
OptionParser.new do |o|
  o.banner = <<~BANNER
    Usage: app-toggle [options]

    アプリごとのショートカットキーを対話的に割り当てる(引数なし)。
    押すと、そのアプリが最前面なら隠し、それ以外なら前面に出す(未起動なら起動する)。
    設定ファイル: #{CONFIG_PATH}

    Options:
  BANNER
  o.on('--list', '割り当ての一覧を表示') { opts[:list] = true }
  o.on('--reload', '設定ファイルを常駐に読み直させる(JSON を手で編集した後に)') { opts[:reload] = true }
  o.on('--version', 'バージョンを表示') { puts "app-toggle #{VERSION}"; exit 0 }
  o.on('-h', '--help') { puts o; exit 0 }
end.parse!(ARGV)

die("daemon がビルドされていません: #{DAEMON}\n  先に ./setup.rb --apply を実行してください") unless File.executable?(DAEMON)

if opts[:list]
  print_list
elsif opts[:reload]
  reload_daemon
else
  run_tui
end
