// app-toggle-daemon
//   設定ファイルに書いたショートカットキーを登録して常駐し、押されたらアプリの表示・隠すを切り替える。
//   最前面なら隠し、それ以外(背面にある・隠れている・未起動)なら前面に出す。
//   SIGHUP で設定を読み直す(TUI が保存後に送る)。
//   disabled_in に書いたアプリが前面にある間は、ホットキーを全部外してキーを素通しする。
//   無効/有効が切り替わったときは、画面右上に1秒だけ表示を出す。
//
//   app-toggle-daemon --config PATH   常駐する(launchd から起動する用)
//   app-toggle-daemon --parse SPEC    キー指定を検証して「正規形<TAB>表示」を出すだけ(TUI 用)
//
//   ホットキーは Carbon の RegisterEventHotKey で登録する。CGEventTap や NSEvent の
//   グローバル監視と違い、アクセシビリティや入力監視の許可が要らない。

import AppKit
import Carbon.HIToolbox

// ---- キー指定の解釈 ---------------------------------------------------------
//
// 書式は "ctrl+opt+t" のように修飾キーとキーを + でつなぐ。ターミナルの TUI では ⌘ を含む
// 組み合わせを受け取れない(ターミナル自身が先に食べる)ため、押して記録する方式ではなく文字で書く。

// 表示は Apple のメニューと同じ ⌃⌥⇧⌘ の順に揃える。正規形もこの順にする。
let modifierTable: [(names: [String], canonical: String, symbol: String, flag: Int)] = [
  (["ctrl", "control", "⌃"], "ctrl", "⌃", controlKey),
  (["opt", "option", "alt", "⌥"], "opt", "⌥", optionKey),
  (["shift", "⇧"], "shift", "⇧", shiftKey),
  (["cmd", "command", "⌘"], "cmd", "⌘", cmdKey),
]

// 仮想キーコードはキーの物理位置を指す(kVK_ANSI_* の名前は US 配列の刻印)。
// JIS 配列でも英字・数字の位置は同じなので、そのまま使える。
let namedKeys: [String: (code: Int, label: String)] = {
  var keys: [String: (code: Int, label: String)] = [:]
  let letters: [(String, Int)] = [
    ("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D), ("e", kVK_ANSI_E),
    ("f", kVK_ANSI_F), ("g", kVK_ANSI_G), ("h", kVK_ANSI_H), ("i", kVK_ANSI_I), ("j", kVK_ANSI_J),
    ("k", kVK_ANSI_K), ("l", kVK_ANSI_L), ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O),
    ("p", kVK_ANSI_P), ("q", kVK_ANSI_Q), ("r", kVK_ANSI_R), ("s", kVK_ANSI_S), ("t", kVK_ANSI_T),
    ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W), ("x", kVK_ANSI_X), ("y", kVK_ANSI_Y),
    ("z", kVK_ANSI_Z),
    ("0", kVK_ANSI_0), ("1", kVK_ANSI_1), ("2", kVK_ANSI_2), ("3", kVK_ANSI_3), ("4", kVK_ANSI_4),
    ("5", kVK_ANSI_5), ("6", kVK_ANSI_6), ("7", kVK_ANSI_7), ("8", kVK_ANSI_8), ("9", kVK_ANSI_9),
    ("-", kVK_ANSI_Minus), ("=", kVK_ANSI_Equal), ("[", kVK_ANSI_LeftBracket),
    ("]", kVK_ANSI_RightBracket), (";", kVK_ANSI_Semicolon), ("'", kVK_ANSI_Quote),
    (",", kVK_ANSI_Comma), (".", kVK_ANSI_Period), ("/", kVK_ANSI_Slash),
    ("\\", kVK_ANSI_Backslash), ("`", kVK_ANSI_Grave),
  ]
  for (name, code) in letters { keys[name] = (code, name.uppercased()) }

  let fkeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
               kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
  for (i, code) in fkeys.enumerated() { keys["f\(i + 1)"] = (code, "F\(i + 1)") }

  let special: [(String, Int, String)] = [
    ("space", kVK_Space, "Space"), ("return", kVK_Return, "↩"), ("tab", kVK_Tab, "⇥"),
    ("escape", kVK_Escape, "⎋"), ("delete", kVK_Delete, "⌫"), ("forwarddelete", kVK_ForwardDelete, "⌦"),
    ("up", kVK_UpArrow, "↑"), ("down", kVK_DownArrow, "↓"), ("left", kVK_LeftArrow, "←"),
    ("right", kVK_RightArrow, "→"), ("home", kVK_Home, "↖"), ("end", kVK_End, "↘"),
    ("pageup", kVK_PageUp, "⇞"), ("pagedown", kVK_PageDown, "⇟"),
    ("eisu", kVK_JIS_Eisu, "英数"), ("kana", kVK_JIS_Kana, "かな"),
  ]
  for (name, code, label) in special { keys[name] = (code, label) }
  return keys
}()

let keyAliases = ["enter": "return", "esc": "escape", "backspace": "delete", "spc": "space"]

struct KeySpec {
  let keyCode: UInt32
  let modifiers: UInt32
  let canonical: String  // 設定ファイルに書く形 例: ctrl+opt+t
  let display: String    // 人に見せる形 例: ⌃⌥T
}

func parseSpec(_ spec: String) -> Result<KeySpec, ParseError> {
  let tokens = spec.lowercased().replacingOccurrences(of: " ", with: "")
    .split(separator: "+", omittingEmptySubsequences: false).map(String.init)
  // "ctrl++" のように + 自体を指すことはできない(= を使う)。空のトークンは書き間違いとして弾く。
  guard let last = tokens.last, !tokens.contains("") else {
    return .failure(ParseError("書式は ctrl+opt+t のように + でつなぎます"))
  }

  var flags = 0
  for token in tokens.dropLast() {
    guard let mod = modifierTable.first(where: { $0.names.contains(token) }) else {
      return .failure(ParseError("修飾キーではありません: \(token)(ctrl / opt / shift / cmd)"))
    }
    flags |= mod.flag
  }

  let keyName = keyAliases[last] ?? last
  guard let key = namedKeys[keyName] else {
    return .failure(ParseError("キーが分かりません: \(last)(英数字・記号・f1〜f20・space・return・up など)"))
  }
  // 修飾なしの文字キーを奪うと普通の入力ができなくなる。F キーだけは単独で使われる前提なので許す。
  if flags == 0 && keyName.range(of: #"^f\d+$"#, options: .regularExpression) == nil {
    return .failure(ParseError("修飾キーなしで割り当てられるのは F キーだけです"))
  }

  let ordered = modifierTable.filter { flags & $0.flag != 0 }
  let canonical = (ordered.map(\.canonical) + [keyName]).joined(separator: "+")
  let display = ordered.map(\.symbol).joined() + key.label
  return .success(KeySpec(keyCode: UInt32(key.code), modifiers: UInt32(flags),
                          canonical: canonical, display: display))
}

struct ParseError: Error {
  let message: String
  init(_ message: String) { self.message = message }
}

// ---- 常駐 ------------------------------------------------------------------

func log(_ message: String) {
  let formatter = DateFormatter()
  formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
  print("\(formatter.string(from: Date())) \(message)")
  fflush(stdout)  // launchd がファイルへ流すので、行ごとに吐かないと TUI が結果を読めない
}

struct Config: Decodable {
  struct Entry: Decodable {
    let bundleID: String
    let key: String
    enum CodingKeys: String, CodingKey { case bundleID = "bundle_id", key }
  }
  let hotkeys: [Entry]
  // これらのアプリが前面にある間は、全てのホットキーを外してキーをそのアプリへ素通しする。
  let disabledIn: [String]?
  enum CodingKeys: String, CodingKey { case hotkeys, disabledIn = "disabled_in" }
}

func toggle(_ bundleID: String) {
  let workspace = NSWorkspace.shared
  if let front = workspace.frontmostApplication, front.bundleIdentifier == bundleID {
    front.hide()
    return
  }
  guard let url = workspace.urlForApplication(withBundleIdentifier: bundleID) else {
    log("アプリが見つかりません: \(bundleID)")
    return
  }
  // 起動済みなら前面に出し、隠れていれば再表示し、ウィンドウが無ければ Dock のクリックと同じく
  // 開き直させる(reopen イベント)。未起動なら起動する。NSRunningApplication.activate() を
  // 使わないのは、この3つを自分で場合分けする必要がなくなるため。
  let config = NSWorkspace.OpenConfiguration()
  config.activates = true
  workspace.openApplication(at: url, configuration: config) { _, error in
    if let error { log("前面に出せませんでした: \(bundleID) \(error.localizedDescription)") }
  }
}

let signature = OSType(0x5447_4C45)  // 'TGLE'
var hotkeys: [(spec: KeySpec, bundleID: String)] = []  // 解釈できた割り当て
var disabledIn: Set<String> = []
var registered: [EventHotKeyRef] = []
var targets: [UInt32: String] = [:]
var nextID: UInt32 = 1
var suspendedBy: String?  // いま前面にいる除外アプリ。nil なら有効

// RegisterEventHotKey で登録したキーは、押された時点で横取りされて前面のアプリに届かない。
// ハンドラで「何もしない」だけでは除外アプリでそのキーが使えないので、登録ごと外す。
func unregisterAll() {
  registered.forEach { UnregisterEventHotKey($0) }
  registered.removeAll()
  targets.removeAll()
}

// verbose でないとき(除外アプリから離れて再開するたび)は失敗だけを書く。
// アプリを切り替えるたびに全件をログへ出すと、TUI が読む読み込み結果が埋もれるため。
@discardableResult
func registerAll(verbose: Bool) -> Int {
  var failed = 0
  for hotkey in hotkeys {
    var ref: EventHotKeyRef?
    let id = EventHotKeyID(signature: signature, id: nextID)
    let status = RegisterEventHotKey(hotkey.spec.keyCode, hotkey.spec.modifiers, id,
                                     GetApplicationEventTarget(), 0, &ref)
    if status == noErr, let ref {
      registered.append(ref)
      targets[nextID] = hotkey.bundleID
      if verbose { log("OK \(hotkey.spec.display) → \(hotkey.bundleID)") }
    } else {
      // -9878 (eventHotKeyExistsErr) は、他のアプリが同じ組み合わせを先に登録しているとき
      let reason = status == OSStatus(eventHotKeyExistsErr) ? "他のアプリが使用中" : "登録に失敗"
      log("NG \(hotkey.spec.display) → \(hotkey.bundleID): \(reason) (\(status))")
      failed += 1
    }
    nextID += 1
  }
  return failed
}

// ---- 切り替わりの表示 --------------------------------------------------------
//
// 無効/有効が切り替わったことを、画面右上(メニューバーの直下)に1秒だけ出す。
// 文言の先頭にツール名を入れるのは、どの常駐が出した表示かを見て分かるようにするため。
// 通知センターを使わないのは、署名済みのアプリと通知の許可が要るうえ、消えるまでの時間を
// こちらで決められないため。パネルは前面を奪わず、クリックも素通しする。

let hudWidth: CGFloat = 300
let hudHeight: CGFloat = 40
let hudMargin: CGFloat = 12
let hudDuration: TimeInterval = 1.0

let hudPanel: NSPanel = {
  let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: hudWidth, height: hudHeight),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
  panel.level = .statusBar
  panel.isOpaque = false
  panel.backgroundColor = .clear
  panel.hasShadow = true
  panel.ignoresMouseEvents = true
  panel.hidesOnDeactivate = false
  // どの操作スペースでも、フルスクリーンのアプリの上でも出す
  panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

  let box = NSView(frame: panel.contentView!.bounds)
  box.wantsLayer = true
  box.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.85).cgColor
  box.layer?.cornerRadius = 10
  box.layer?.borderWidth = 1  // 色は文字と同じものを showHUD で塗る
  panel.contentView = box
  return panel
}()

let hudLabel: NSTextField = {
  let label = NSTextField(labelWithString: "")
  label.font = .systemFont(ofSize: 14, weight: .medium)
  label.textColor = .white
  label.alignment = .center
  label.lineBreakMode = .byTruncatingTail
  label.frame = NSRect(x: 12, y: (hudHeight - 20) / 2, width: hudWidth - 24, height: 20)
  hudPanel.contentView?.addSubview(label)
  return label
}()

var hudHideTimer: Timer?

// 背景が暗いので、system の赤・緑(明るい背景向けの濃さ)より少し明るくして読みやすくする。
let hudDisabledColor = NSColor(srgbRed: 1.0, green: 0.42, blue: 0.42, alpha: 1)
let hudEnabledColor = NSColor(srgbRed: 0.30, green: 0.85, blue: 0.39, alpha: 1)

func showHUD(_ text: String, color: NSColor) {
  hudLabel.stringValue = text
  hudLabel.textColor = color
  hudPanel.contentView?.layer?.borderColor = color.cgColor
  // マウスのある画面に出す。作業中の画面である可能性がいちばん高いため。
  let mouse = NSEvent.mouseLocation
  let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
  if let visible = screen?.visibleFrame {  // メニューバーと Dock を除いた領域
    hudPanel.setFrameOrigin(NSPoint(x: visible.maxX - hudWidth - hudMargin,
                                    y: visible.maxY - hudHeight - hudMargin))
  }
  hudPanel.alphaValue = 1
  hudPanel.orderFrontRegardless()

  // 立て続けに切り替わったときは表示を差し替え、消えるまでの時間を数え直す。
  hudHideTimer?.invalidate()
  hudHideTimer = Timer.scheduledTimer(withTimeInterval: hudDuration, repeats: false) { _ in
    NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; hudPanel.animator().alphaValue = 0 },
                                         completionHandler: { hudPanel.orderOut(nil) })
  }
}

func appName(_ bundleID: String) -> String {
  NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName ?? bundleID
}

// 前面のアプリが変わるたびに呼ぶ。除外アプリに入ったら外し、出たら登録し直す。
func applyFrontmost(_ app: NSRunningApplication?) {
  let bundleID = app?.bundleIdentifier ?? ""
  if disabledIn.contains(bundleID) {
    guard suspendedBy == nil else { suspendedBy = bundleID; return }
    unregisterAll()
    suspendedBy = bundleID
    log("一時停止: \(bundleID) が前面")
    showHUD("app-toggle 無効化(\(appName(bundleID)))", color: hudDisabledColor)
  } else if let previous = suspendedBy {
    suspendedBy = nil
    registerAll(verbose: false)
    log("再開: \(previous) から離れた")
    showHUD("app-toggle 有効化", color: hudEnabledColor)
  }
}

// 読み直しのたびに全部外して登録し直す。差分を取らないのは、件数が少なく一瞬で終わるため。
func reload(configPath: String) {
  unregisterAll()
  hotkeys.removeAll()
  disabledIn.removeAll()
  suspendedBy = nil

  var config = Config(hotkeys: [], disabledIn: nil)
  if FileManager.default.fileExists(atPath: configPath) {
    do {
      config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: URL(fileURLWithPath: configPath)))
    } catch {
      log("設定ファイルを読めません: \(configPath) \(error)")
    }
  }

  var failed = 0
  for entry in config.hotkeys {
    switch parseSpec(entry.key) {
    case .failure(let err):
      log("NG \(entry.key) → \(entry.bundleID): \(err.message)")
      failed += 1
    case .success(let spec):
      if NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.bundleID) == nil {
        log("注意 \(spec.display) → \(entry.bundleID): アプリが見つかりません(登録はします)")
      }
      hotkeys.append((spec, entry.bundleID))
    }
  }
  disabledIn = Set(config.disabledIn ?? [])
  failed += registerAll(verbose: true)
  if !disabledIn.isEmpty { log("無効にするアプリ: \(disabledIn.sorted().joined(separator: ", "))") }

  // TUI はこの行を待って結果を読み取る。文言を変えるときは app-toggle.rb も直す。
  log("読み込み完了: 登録 \(registered.count)件 / 失敗 \(failed)件 (\(configPath))")
  // 除外アプリが前面にいる状態で読み直した場合は、登録結果を確かめてからすぐ外す。
  applyFrontmost(NSWorkspace.shared.frontmostApplication)
}

// ---- 入口 ------------------------------------------------------------------

let args = CommandLine.arguments
func argument(after flag: String) -> String? {
  guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
  return args[i + 1]
}

if let spec = argument(after: "--parse") {
  switch parseSpec(spec) {
  case .success(let parsed):
    print("\(parsed.canonical)\t\(parsed.display)")
    exit(0)
  case .failure(let err):
    FileHandle.standardError.write(Data((err.message + "\n").utf8))
    exit(1)
  }
}

guard let configPath = argument(after: "--config") else {
  FileHandle.standardError.write(Data("usage: app-toggle-daemon --config PATH | --parse SPEC\n".utf8))
  exit(2)
}

var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
  var hotkeyID = EventHotKeyID()
  GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &hotkeyID)
  if let bundleID = targets[hotkeyID.id] { toggle(bundleID) }
  return noErr
}, 1, &eventType, nil, nil)

// シグナルは直接ハンドラで処理せず、メインキューで受ける(ハンドラ内では Carbon を呼べない)。
signal(SIGHUP, SIG_IGN)
let hupSource = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .main)
hupSource.setEventHandler { reload(configPath: configPath) }
hupSource.resume()

let activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
  forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
) { note in
  applyFrontmost(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
}

log("開始 pid=\(getpid())")
reload(configPath: configPath)

let app = NSApplication.shared
// Dock には出さない。.prohibited だとウィンドウを出せず切り替わりの表示が使えないので .accessory にする。
// 自分から前面に出ることはないので、メニューバーが app-toggle に乗っ取られることもない。
app.setActivationPolicy(.accessory)
app.run()
