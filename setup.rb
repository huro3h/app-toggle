#!/usr/bin/env ruby
# frozen_string_literal: true

# app-toggle のセットアップ。
#   0. check-requirements.sh で動作環境を確かめる(足りなければ何もせずに止まる)。
#   1. app-toggle-daemon.swift を build/ にコンパイルする。
#   2. LaunchAgent の plist をテンプレートから生成して読み込ませる。
#      plist には daemon と設定ファイルの絶対パスが要るので、静的ファイルでは持ち運べない。
#   3. PATH の通ったディレクトリに TUI(app-toggle.rb)へのシンボリックリンクを app-toggle として張る。
#
#   exit 0 = OK / 2 = エラー

require 'optparse'
require 'open3'
require 'fileutils'

LABEL     = 'local.app-toggle'
TOOL_ROOT = File.expand_path(__dir__)
TEMPLATE  = File.join(TOOL_ROOT, "#{LABEL}.plist.template")
SOURCE    = File.join(TOOL_ROOT, 'app-toggle-daemon.swift')
DAEMON    = File.join(TOOL_ROOT, 'build', 'app-toggle-daemon')
TUI       = File.join(TOOL_ROOT, 'app-toggle.rb')
CHECK     = File.join(TOOL_ROOT, 'check-requirements.sh')
CONFIG    = File.join(TOOL_ROOT, 'app-toggle.json')
DEST      = File.join(Dir.home, 'Library', 'LaunchAgents', "#{LABEL}.plist")
LOG       = File.join(Dir.home, 'Library', 'Logs', 'app-toggle.log')

# リンクを置く先の候補(優先順)。PATH を総当たりしないのは、rbenv の shims などが
# 書き込み可能なまま先頭に来ており、そこへ置くと rehash で消えるから。
LINK_CANDIDATES = ['/opt/homebrew/bin', '/usr/local/bin', File.join(Dir.home, 'bin')].freeze

def die(msg, code = 2) = (warn "error: #{msg}"; exit code)

def link_dir
  path = ENV['PATH'].to_s.split(File::PATH_SEPARATOR)
  LINK_CANDIDATES.find { |d| path.include?(d) && File.directory?(d) && File.writable?(d) }
end

opts = {}
OptionParser.new do |o|
  o.banner = "Usage: app-toggle/setup.rb [--apply]\n\n" \
             "  daemon をビルドし、LaunchAgent(#{LABEL})を読み込み、PATH にリンクを張る。既定はドライラン。\n\n"
  o.on('--apply', '実際にビルド・書き込み・読み込みをする') { opts[:apply] = true }
  o.on('--uninstall', 'LaunchAgent とリンクを削除する') { opts[:uninstall] = true }
  o.on('--no-link', 'PATH へのシンボリックリンクを作らない') { opts[:no_link] = true }
  o.on('-h', '--help') { puts o; exit 0 }
end.parse!(ARGV)

uid = Process.uid
dir = opts[:no_link] ? nil : link_dir
link = dir && File.join(dir, 'app-toggle')

# 自分が張ったリンクだけを消す。同名の別物を巻き込まないため実体を確認する。
def our_link?(link)
  link && File.symlink?(link) && File.realpath(link) == TUI
rescue Errno::ENOENT # 壊れたリンク
  false
end

if opts[:uninstall]
  unless opts[:apply]
    puts "削除する: #{DEST} (+ launchctl bootout)"
    puts "削除する: #{link}" if our_link?(link)
    puts '  実行するには --apply を付けてください'
    exit 0
  end
  Open3.capture3('launchctl', 'bootout', "gui/#{uid}/#{LABEL}")
  File.delete(DEST) if File.exist?(DEST)
  File.delete(link) if our_link?(link)
  puts "削除しました: #{LABEL}(設定ファイルと build/ は残しています)"
  exit 0
end

# ビルドや常駐の登録を始める前に、必要なものが揃っているかを確かめる。ドライランでも走らせ、
# 足りないものがあれば先に分かるようにする。結果はスクリプトがそのまま表示する。
die('動作環境が揃っていません(上の NG を参照)') unless system(CHECK)
puts

die("テンプレートがありません: #{TEMPLATE}") unless File.exist?(TEMPLATE)
die("ソースがありません: #{SOURCE}") unless File.exist?(SOURCE)

plist = File.read(TEMPLATE)
            .gsub('{{LABEL}}', LABEL)
            .gsub('{{DAEMON}}', DAEMON)
            .gsub('{{CONFIG}}', CONFIG)
            .gsub('{{LOG}}', LOG)

link_note =
  if opts[:no_link] then '(--no-link のため作らない)'
  elsif link.nil?   then '(PATH に書き込める候補が無いため作らない)'
  else link
  end

unless opts[:apply]
  puts "ビルド: swiftc -O #{SOURCE} -o #{DAEMON}"
  puts "生成先: #{DEST}"
  puts "  config : #{CONFIG}#{File.exist?(CONFIG) ? '' : '(まだ無い。空の割り当てで起動する)'}"
  puts "  log    : #{LOG}"
  puts "  link   : #{link_note}"
  puts "\n実際にビルドして読み込むには --apply を付けてください"
  exit 0
end

FileUtils.mkdir_p(File.dirname(DAEMON))
puts 'daemon をビルドしています...'
_, err, st = Open3.capture3('swiftc', '-O', SOURCE, '-o', DAEMON)
die("ビルドに失敗しました:\n#{err}") unless st.success?

FileUtils.mkdir_p(File.dirname(DEST))
File.write(DEST, plist)
_, err, st = Open3.capture3('plutil', '-lint', DEST)
die("plist が不正です: #{err}") unless st.success?

# 既存があれば外してから読み込む。ビルドし直した daemon に入れ替えるためにも必要。
# bootout は外し終わる前に戻ることがあり、すぐ bootstrap すると
# "Bootstrap failed: 5: Input/output error" になる(実際に踏んだ)。消えるまで待つ。
Open3.capture3('launchctl', 'bootout', "gui/#{uid}/#{LABEL}")
deadline = Time.now + 5
while Time.now < deadline
  _, _, loaded = Open3.capture3('launchctl', 'print', "gui/#{uid}/#{LABEL}")
  break unless loaded.success?

  sleep 0.1
end
_, err, st = Open3.capture3('launchctl', 'bootstrap', "gui/#{uid}", DEST)
die("launchctl bootstrap に失敗: #{err}") unless st.success?

puts "LaunchAgent を読み込みました: #{LABEL}"

if link.nil?
  puts "PATH へのリンクは作りませんでした #{link_note}"
elsif File.exist?(link) && !our_link?(link)
  # 別物を黙って上書きすると気付けないので、消さずに知らせるだけにする。
  warn "警告: #{link} が既にあるためリンクを作りませんでした"
else
  File.delete(link) if File.symlink?(link) || File.exist?(link)
  File.symlink(TUI, link)
  puts "PATH にリンクしました: #{link} -> #{TUI}"
end

puts "  ログ: tail -f #{LOG}"
