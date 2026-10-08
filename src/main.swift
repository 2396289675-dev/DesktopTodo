//
//  DesktopTodo — 常驻桌面的透明底待办挂件 (macOS)
//
import AppKit
import SwiftUI
import ServiceManagement
import Combine
import Carbon.HIToolbox

// MARK: - Model

struct TodoItem: Identifiable, Codable, Equatable {
    var id: UUID
    var text: String
    var done: Bool
    var daily: Bool          // true = 每天重现（跨天自动取消勾选）
    var createdAt: Date

    init(text: String, daily: Bool = true) {
        self.id = UUID()
        self.text = text
        self.done = false
        self.daily = daily
        self.createdAt = Date()
    }
}

struct Settings: Codable {
    var opacity: Double = 0.96
    var locked: Bool = false          // 锁定位置（不可拖动）
    var clickThrough: Bool = false    // 鼠标穿透（桌面图标可点）
    var layerMode: Int = 0            // 0 图标上方 / 1 图标下方 / 2 始终置顶
    var glass: Bool = true            // 毛玻璃底；关闭则纯文字透明
    var showStreak: Bool = true
    var originX: CGFloat? = nil
    var originY: CGFloat? = nil
}

struct TodoData: Codable {
    var items: [TodoItem] = []
    var lastReset: String = ""
    var history: [String: Int] = [:]  // "yyyy-MM-dd" -> 当天完成数
    var settings: Settings = Settings()
}

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published var items: [TodoItem] = []
    @Published var settings: Settings = Settings()
    @Published var streak: Int = 0
    @Published var todayDone: Int = 0
    @Published var flash: String? = nil

    /// 由全局热键触发，通知界面把焦点放进输入框
    let focusRequest = PassthroughSubject<Void, Never>()

    func flashMessage(_ text: String) {
        flash = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            if self?.flash == text { self?.flash = nil }
        }
    }

    func requestInputFocus() { focusRequest.send() }

    private var history: [String: Int] = [:]
    private var lastReset: String = ""
    private let fileURL: URL
    private var saveWork: DispatchWorkItem?

    private static func dayKey(_ d: Date = Date()) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: d)
    }

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DesktopTodo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("data.json")
        let firstRun = !FileManager.default.fileExists(atPath: fileURL.path)
        load()
        if firstRun {
            items = [
                TodoItem(text: "写下今天第一件要做的事"),
                TodoItem(text: "试试点左边的圆圈打勾 ✓")
            ]
            save()
        }
        rolloverIfNeeded()
        recount()
    }

    // MARK: persistence
    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let d = try? JSONDecoder().decode(TodoData.self, from: data) else { return }
        items = d.items
        settings = d.settings
        history = d.history
        lastReset = d.lastReset
    }

    func save() {
        let snapshot = TodoData(items: items, lastReset: lastReset, history: history, settings: settings)
        saveWork?.cancel()
        let w = DispatchWorkItem { [fileURL] in
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
    }

    // MARK: day rollover
    func rolloverIfNeeded() {
        let today = Self.dayKey()
        if lastReset.isEmpty { lastReset = today; save(); return }
        guard lastReset != today else { return }

        // 归档：昨天完成了几项
        let yesterdaysDone = items.filter { $0.done }.count
        if yesterdaysDone > 0 { history[lastReset] = yesterdaysDone }

        // 一次性任务（daily == false）完成后归档移除；每日任务取消勾选
        items.removeAll { $0.done && !$0.daily }
        for i in items.indices { items[i].done = false }

        lastReset = today
        save()
        recount()
    }

    func recount() {
        todayDone = items.filter { $0.done }.count
        var s = 0
        let cal = Calendar.current
        var cursor = todayDone > 0 ? Date() : (cal.date(byAdding: .day, value: -1, to: Date()) ?? Date())
        while true {
            let k = Self.dayKey(cursor)
            if let c = history[k], c > 0 {
                s += 1
                guard let prev = cal.date(byAdding: .day, value: -1, to: cursor) else { break }
                cursor = prev
            } else if Self.dayKey(cursor) == Self.dayKey() && todayDone > 0 {
                s += 1
                guard let prev = cal.date(byAdding: .day, value: -1, to: cursor) else { break }
                cursor = prev
            } else { break }
            if s > 365 { break }
        }
        streak = s
    }

    // MARK: mutations
    var ordered: [TodoItem] {
        items.sorted { a, b in
            if a.done != b.done { return !a.done && b.done }
            return a.createdAt < b.createdAt
        }
    }

    func add(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        items.append(TodoItem(text: t))
        save()
    }

    func toggle(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].done.toggle()
        save(); recount()
        let today = Self.dayKey()
        history[today] = items.filter { $0.done }.count
    }

    func toggleDaily(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].daily.toggle()
        save()
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        save(); recount()
    }

    func clearCompleted() {
        items.removeAll { $0.done }
        save(); recount()
    }

    func updateSettings(_ mutate: (inout Settings) -> Void) {
        var s = settings
        mutate(&s)
        settings = s
        save()
        AppDelegate.shared?.applySettings()
    }
}

// MARK: - Views

struct CardBackground: View {
    var glass: Bool
    var body: some View {
        Group {
            if glass {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )
            } else {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.clear)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(glass ? 0.22 : 0.12), lineWidth: 1)
        )
    }
}

struct CheckBox: View {
    var done: Bool
    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(done ? Color.clear : Color.primary.opacity(0.35), lineWidth: 1.4)
                .frame(width: 17, height: 17)
            if done {
                Circle().fill(Color.accentColor).frame(width: 17, height: 17)
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 22, height: 22)
        .contentShape(Rectangle())
        .animation(.spring(response: 0.22, dampingFraction: 0.7), value: done)
    }
}

struct TodoRow: View {
    @ObservedObject var store: Store
    var item: TodoItem
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            Button { store.toggle(item.id) } label: { CheckBox(done: item.done) }
                .buttonStyle(.plain)

            Text(item.text)
                .font(.system(size: 13.5, weight: .regular))
                .strikethrough(item.done, color: .secondary)
                .foregroundStyle(item.done ? .secondary : .primary)
                .opacity(item.done ? 0.55 : 1.0)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { store.toggle(item.id) }
                .shadow(color: store.settings.glass ? .clear : .black.opacity(0.55), radius: 2, x: 0, y: 1)

            if item.daily {
                Button { store.toggleDaily(item.id) } label: {
                    Image(systemName: "repeat")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .opacity(hovered ? 0.9 : 0.35)
                .help("每日重复：关闭后，完成即归档")
            }

            Button { withAnimation(.easeOut(duration: 0.15)) { store.remove(item.id) } } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .opacity(hovered ? 0.9 : 0)
        }
        .padding(.vertical, 3)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

struct ContentView: View {
    @ObservedObject var store: Store
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var sorted: [TodoItem] { store.ordered }
    private var total: Int { store.items.count }
    private var doneCount: Int { store.items.filter { $0.done }.count }

    private var dateText: String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "M月d日 EEEE"
        return f.string(from: Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // header
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(dateText)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .shadow(color: store.settings.glass ? .clear : .black.opacity(0.6), radius: 2, x: 0, y: 1)
                    Text(total == 0 ? "今天还没有安排" : "\(doneCount)/\(total) 已完成")
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .shadow(color: store.settings.glass ? .clear : .black.opacity(0.6), radius: 3, x: 0, y: 1)
                }
                Spacer(minLength: 4)
                if let f = store.flash {
                    Text(f)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .transition(.opacity)
                } else if store.settings.showStreak && store.streak > 0 {
                    Text("连续 \(store.streak) 天")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                }
            }

            if total > 0 {
                ProgressView(value: Double(doneCount), total: Double(max(total, 1)))
                    .progressViewStyle(.linear)
                    .tint(Color.accentColor)
                    .scaleEffect(y: 0.7)
                    .frame(height: 4)
            }

            // list
            if sorted.isEmpty {
                Text("点下面的输入框，写下第一件事。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 10)
                    .shadow(color: store.settings.glass ? .clear : .black.opacity(0.6), radius: 2, x: 0, y: 1)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(sorted) { item in
                            TodoRow(store: store, item: item)
                            if item.id != sorted.last?.id {
                                Divider().opacity(store.settings.glass ? 0.10 : 0.14)
                            }
                        }
                    }
                }
                .frame(maxHeight: 420)
            }

            // add
            HStack(spacing: 7) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("添加待办，回车确认", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focused)
                    .onSubmit { store.add(draft); draft = "" }
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(Color.primary.opacity(store.settings.glass ? 0.07 : 0.12),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .padding(14)
        .frame(width: 292)
        .background(CardBackground(glass: store.settings.glass))
        .onReceive(store.focusRequest) { _ in focused = true }
        .contextMenu { ContextItems(store: store) }
    }
}

struct ContextItems: View {
    @ObservedObject var store: Store
    var body: some View {
        Button { store.updateSettings { $0.locked.toggle() } } label: {
            Text(store.settings.locked ? "解锁位置" : "锁定位置")
        }
        Button { store.updateSettings { $0.clickThrough.toggle() } } label: {
            Text(store.settings.clickThrough ? "关闭鼠标穿透" : "开启鼠标穿透")
        }
        Button { store.updateSettings { $0.glass.toggle() } } label: {
            Text(store.settings.glass ? "切换为纯透明" : "切换为毛玻璃")
        }
        Divider()
        Button { store.clearCompleted() } label: { Text("清除已完成") }
        Button { NSApp.terminate(nil) } label: { Text("退出") }
    }
}

struct SettingsView: View {
    @ObservedObject var store: Store
    @State private var axOK = AXIsProcessTrusted()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("桌面待办 · 设置").font(.system(size: 13, weight: .semibold))

            Toggle("锁定位置", isOn: Binding(
                get: { store.settings.locked },
                set: { v in store.updateSettings { s in s.locked = v } }))
            Toggle("鼠标穿透（可点击桌面图标）", isOn: Binding(
                get: { store.settings.clickThrough },
                set: { v in store.updateSettings { s in s.clickThrough = v } }))
            Toggle("毛玻璃底", isOn: Binding(
                get: { store.settings.glass },
                set: { v in store.updateSettings { s in s.glass = v } }))
            Toggle("显示连续天数", isOn: Binding(
                get: { store.settings.showStreak },
                set: { v in store.updateSettings { s in s.showStreak = v } }))

            VStack(alignment: .leading, spacing: 4) {
                Text("不透明度  \(Int(store.settings.opacity * 100))%").font(.system(size: 11.5))
                Slider(value: Binding(
                    get: { store.settings.opacity },
                    set: { v in store.updateSettings { s in s.opacity = v } }), in: 0.35...1.0)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("层级").font(.system(size: 11.5))
                Picker("", selection: Binding(
                    get: { store.settings.layerMode },
                    set: { v in store.updateSettings { s in s.layerMode = v } })) {
                    Text("桌面图标上方").tag(0)
                    Text("桌面图标下方").tag(1)
                    Text("始终置顶").tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .font(.system(size: 11))
            }

            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("全局快捷键  ⌥ Space").font(.system(size: 11.5, weight: .medium))
                Text("任何界面按一下，直接唤起输入框；\n在别的 App 里先选中文字再按，那句话直接进待办。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Circle()
                        .fill(axOK ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    Text(axOK ? "辅助功能权限已授予" : "未授予辅助功能权限，收录选中文字不可用")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !axOK {
                        Button("开启") {
                            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                            AXIsProcessTrustedWithOptions(opts)
                        }
                        .controlSize(.mini)
                    }
                }
            }
            .onAppear { axOK = AXIsProcessTrusted() }

            Divider()
            Toggle("开机自动启动", isOn: Binding(
                get: { AppDelegate.shared?.launchAtLogin ?? false },
                set: { AppDelegate.shared?.setLaunchAtLogin($0) }))
            Text("拖动卡片可移动位置；右键卡片有快捷菜单。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 260)
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}

// MARK: - Window

/// 无边框窗口默认不能成为 key window，重写以允许输入框获得键盘焦点。
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Carbon 全局热键回调（必须是 C 函数指针，不能捕获上下文）
private func dtHotKeyHandler(_: EventHandlerCallRef?, _: EventRef?, _: UnsafeMutableRawPointer?) -> OSStatus {
    DispatchQueue.main.async { AppDelegate.shared?.hotKeyTriggered() }
    return noErr
}

// MARK: - App Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    static weak var shared: AppDelegate?
    static var keepAlive: AppDelegate?

    var window: NSWindow!
    var store = Store.shared
    private var statusItem: NSStatusItem!
    private var popover: NSPopover?
    private var hosting: NSHostingView<ContentView>!
    private var cancellables = Set<AnyCancellable>()
    private var raised = false            // 已临时抬到普通窗口之上
    private var raiseUntilResign = false  // 因输入而抬起，保持到窗口失去焦点
    private var raiseTimer: DispatchWorkItem?
    private var hotKeyRef: EventHotKeyRef?

    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    /// 命令行开关：`--login-on` / `--login-off` / `--login-status`（供脚本设置开机启动）
    private func handleCLI() -> Bool {
        let args = CommandLine.arguments.dropFirst()
        guard let cmd = args.first(where: { $0.hasPrefix("--login") }) else { return false }
        switch cmd {
        case "--login-on":
            do { try SMAppService.mainApp.register() }
            catch { print("注册开机启动失败: \(error.localizedDescription)"); exit(1) }
            print("已开启开机启动")
        case "--login-off":
            do { try SMAppService.mainApp.unregister() }
            catch { print("取消开机启动失败: \(error.localizedDescription)"); exit(1) }
            print("已关闭开机启动")
        default:
            print("开机启动: \(SMAppService.mainApp.status == .enabled ? "已开启" : "未开启")")
        }
        exit(0)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if handleCLI() { return }
        AppDelegate.shared = self
        NSApp.setActivationPolicy(.accessory)

        let cv = ContentView(store: store)
        hosting = NSHostingView(rootView: cv)

        window = KeyableWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 300),
                          styleMask: [.borderless, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.contentView = hosting
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenDisallowsTiling]
        window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = true
        window.acceptsMouseMovedEvents = true
        window.level = .floating

        applySettings()
        placeInitial()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        setupStatusItem()
        trackWindowMove()
        installEditingHandlers()
        registerHotKey()

        // 高度自适应
        store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.resize() }
            }
            .store(in: &cancellables)
        resize()

        // 跨天检查
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in
                Store.shared.rolloverIfNeeded()
                Store.shared.save()
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                              object: nil, queue: .main) { _ in
            Task { @MainActor in Store.shared.rolloverIfNeeded() }
        }
        NotificationCenter.default.addObserver(forName: NSWorkspace.didWakeNotification,
                                              object: NSWorkspace.shared, queue: .main) { _ in
            Task { @MainActor in Store.shared.rolloverIfNeeded() }
        }
    }

    // MARK: window
    private static let cardWidth: CGFloat = 292

    private func targetHeight() -> CGFloat {
        let n = store.items.count
        let listH: CGFloat = n == 0 ? 56 : min(CGFloat(n) * 33 + 6, 420)
        return 96 + listH + 44
    }

    func placeInitial() {
        let s = NSScreen.main ?? NSScreen.screens[0]
        let vf = s.visibleFrame
        let h = targetHeight()
        if let x = store.settings.originX, let y = store.settings.originY {
            // 换显示器 / 分辨率变化后若跑出屏幕，回到默认位置
            let r = NSRect(x: x, y: y, width: Self.cardWidth, height: h)
            let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(r) }
            if onScreen { window.setFrame(r, display: true); return }
        }
        window.setFrame(NSRect(x: vf.maxX - Self.cardWidth - 28,
                               y: vf.maxY - h - 28,
                               width: Self.cardWidth, height: h), display: true)
    }

    func resize() {
        let h = targetHeight()
        var f = window.frame
        f.size.width = Self.cardWidth
        let top = f.origin.y + f.size.height
        f.size.height = h
        f.origin.y = top - h
        window.setFrame(f, display: true, animate: false)
    }

    func applySettings() {
        let s = store.settings
        window.alphaValue = s.opacity
        window.isMovableByWindowBackground = !s.locked
        window.ignoresMouseEvents = s.clickThrough
        applyLevel()
        window.hasShadow = !s.clickThrough && s.glass
    }

    private func applyLevel() {
        let s = store.settings
        if raised && s.layerMode != 2 {
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)))
            return
        }
        let base = Int(CGWindowLevelForKey(.desktopWindow))
        let icon = Int(CGWindowLevelForKey(.desktopIconWindow))
        switch s.layerMode {
        case 1:  window.level = NSWindow.Level(rawValue: base + 1)
        case 2:  window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)))
        default: window.level = NSWindow.Level(rawValue: icon + 1)
        }
    }

    /// 桌面层窗口无法成为 key window（canBecomeKey = false），
    /// 因此点到底部输入框时临时抬到浮动层，拿到键盘焦点；失焦后自动落回桌面层。
    private func installEditingHandlers() {
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] ev in
            guard let self, ev.windowNumber == self.window.windowNumber else { return ev }
            if ev.locationInWindow.y < 54 { self.raiseForEditing() }
            return ev
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                              object: window, queue: .main) { [weak self] _ in
            guard let self, self.raiseUntilResign else { return }
            self.lower()
        }
    }

    /// 抬起并抢到键盘焦点（用户要点输入框打字）
    private func raiseForEditing() {
        raiseUntilResign = true
        raiseTimer?.cancel()
        applyRaise(on: true, activate: true)
    }

    /// 只抬起来露个脸，不抢走当前 App 的焦点（收录选中文字后的反馈）
    private func raiseTemporary(_ seconds: Double) {
        raiseUntilResign = false
        applyRaise(on: true, activate: false)
        raiseTimer?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.lower() }
        raiseTimer = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    private func lower() {
        raiseUntilResign = false
        raiseTimer?.cancel()
        applyRaise(on: false, activate: false)
    }

    private func applyRaise(on: Bool, activate: Bool) {
        guard on != raised else { return }
        raised = on
        applyLevel()
        if on {
            if activate { NSApp.activate(ignoringOtherApps: true) }
            window.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: 全局热键 ⌥Space

    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), dtHotKeyHandler, 1, &spec, nil, nil)
        let hkID = EventHotKeyID(signature: OSType(0x4454_4F44), id: 1)  // 'DTOD'
        let st = RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), hkID,
                                     GetApplicationEventTarget(), 0, &hotKeyRef)
        if st != noErr { print("热键注册失败: \(st)") }
    }

    /// 热键触发：别的 App 里有选中文字就收进待办，否则唤起输入框
    func hotKeyTriggered() {
        if let t = Self.selectedText() {
            let text = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                store.add(String(text.prefix(200)))
                store.flashMessage("已收录")
                raiseTemporary(1.6)
                return
            }
        }
        raiseForEditing()
        store.requestInputFocus()
    }

    /// 读取当前前台 App 中选中的文字（需要辅助功能权限，无权限返回 nil）
    static func selectedText() -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef else { return nil }
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focusedRef as! AXUIElement,
                                            kAXSelectedTextAttribute as CFString, &selected) == .success,
              let s = selected as? String else { return nil }
        return s
    }

    private func trackWindowMove() {
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification,
                                              object: window, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.store.settings.originX = self.window.frame.origin.x
            self.store.settings.originY = self.window.frame.origin.y
            self.store.save()
        }
    }

    // MARK: status bar
    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: "桌面待办")
            b.action = #selector(togglePopover(_:))
            b.target = self
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc func togglePopover(_ sender: Any?) {
        guard let b = statusItem.button else { return }
        let event = NSApp.currentEvent
        let isRight = event?.type == .rightMouseUp

        if isRight {
            let m = NSMenu()
            m.addItem(withTitle: "显示 / 隐藏", action: #selector(toggleVisible), keyEquivalent: "")
            m.addItem(.separator())
            let lock = NSMenuItem(title: "锁定位置", action: #selector(toggleLock), keyEquivalent: "")
            lock.state = store.settings.locked ? .on : .off; m.addItem(lock)
            let thru = NSMenuItem(title: "鼠标穿透", action: #selector(toggleThrough), keyEquivalent: "")
            thru.state = store.settings.clickThrough ? .on : .off; m.addItem(thru)
            let glass = NSMenuItem(title: "毛玻璃底", action: #selector(toggleGlass), keyEquivalent: "")
            glass.state = store.settings.glass ? .on : .off; m.addItem(glass)
            m.addItem(.separator())
            let li = NSMenuItem(title: "开机自动启动", action: #selector(toggleLogin), keyEquivalent: "")
            li.state = launchAtLogin ? .on : .off; m.addItem(li)
            m.addItem(withTitle: "清除已完成", action: #selector(clearDone), keyEquivalent: "")
            m.addItem(.separator())
            m.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "q")
            m.items.forEach { $0.target = self }
            statusItem.menu = m
            b.performClick(nil)
            statusItem.menu = nil
            return
        }

        if let p = popover, p.isShown {
            p.performClose(nil); popover = nil; return
        }
        let p = NSPopover()
        p.contentViewController = NSHostingController(rootView: SettingsView(store: store))
        p.behavior = .transient
        p.animates = true
        p.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        popover = p
    }

    @objc func toggleVisible() { window.setIsVisible(!window.isVisible) }
    @objc func toggleLock() { store.updateSettings { $0.locked.toggle() } }
    @objc func toggleThrough() { store.updateSettings { $0.clickThrough.toggle() } }
    @objc func toggleGlass() { store.updateSettings { $0.glass.toggle() } }
    @objc func clearDone() { store.clearCompleted() }
    @objc func quit() { NSApp.terminate(nil) }

    @objc func toggleLogin() { setLaunchAtLogin(!launchAtLogin) }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            let a = NSAlert(); a.messageText = "开机启动设置失败"
            a.informativeText = "\(error.localizedDescription)\n\n请把 DesktopTodo.app 放在「应用程序」文件夹后再试。"
            a.runModal()
        }
        objectWillChange.send()
    }
}

// MARK: - entry

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
MainActor.assumeIsolated {
    let d = AppDelegate()
    app.delegate = d
    AppDelegate.keepAlive = d
}
app.run()
