import AppKit
import SwiftUI
import Combine

func currentCredentialStamp() -> String {
    let root = ProcessInfo.processInfo.environment["CODEX_HOME"]
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
    // Only file metadata; no token contents are read or stored.
    return ["auth.json", "config.toml"].map { name in
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: root + "/" + name) else { return "missing" }
        return [attrs[.modificationDate], attrs[.systemFileNumber], attrs[.size]].map { String(describing: $0) }.joined(separator: ":")
    }.joined(separator: "|")
}

func resetOutcomeMessage(_ outcome: String) -> String {
    switch outcome {
    case "reset": return "重置成功，已使用 1 张卡；正在刷新额度。"
    case "alreadyRedeemed": return "该次重置已完成，没有重复消耗卡片。"
    case "nothingToReset": return "当前没有符合条件的额度窗口，未消耗卡片。"
    case "noCredit": return "当前账号没有可用重置卡，未消耗卡片。"
    default: return "结果未确认。再次点击会复用同一次请求，避免重复扣卡。"
    }
}

struct QuotaWindow: Equatable {
    let usedPercent: Double
    let durationMinutes: Int
    let resetsAt: Date

    var remainingPercent: Double { max(0, min(100, 100 - usedPercent)) }
}

struct QuotaSnapshot: Equatable {
    let accountID: String?
    let authStamp: String
    let primary: QuotaWindow?
    let secondary: QuotaWindow?
    let planType: String?
    let resetCredits: Int?
    let updatedAt: Date
}

@MainActor
final class QuotaStore: ObservableObject {
    enum Status: Equatable {
        case loading
        case connected
        case error(String)
    }

    @Published var snapshot: QuotaSnapshot?
    @Published var status: Status = .loading
    @Published var resetBusy = false
    @Published var resetMessage = ""
    @Published var confirmingReset = false

    var canReset: Bool {
        snapshot?.accountID != nil && (snapshot?.resetCredits ?? 0) > 0 && !resetBusy && status == .connected
    }

    func confirmReset() {
        confirmingReset = false
        guard canReset, let snapshot, let account = snapshot.accountID else { return }
        guard snapshot.authStamp == currentCredentialStamp() else {
            resetMessage = "登录状态已变化，请等待新账号额度加载后重试。"
            start()
            return
        }
        // Persist one pending key per account. An uncertain response or restart
        // must never turn a retry into a second redemption.
        let storageKey = "pending-reset." + account
        let key = UserDefaults.standard.string(forKey: storageKey) ?? UUID().uuidString
        UserDefaults.standard.set(key, forKey: storageKey)
        resetBusy = true
        resetMessage = "正在使用重置卡…"
        let currentSession = session
        service.consumeReset(key: key, expectedStamp: snapshot.authStamp) { [weak self] outcome in
            Task { @MainActor in
                if ["reset", "alreadyRedeemed", "nothingToReset", "noCredit"].contains(outcome) {
                    UserDefaults.standard.removeObject(forKey: storageKey)
                }
                guard self?.session == currentSession else { return }
                self?.resetBusy = false
                self?.resetMessage = resetOutcomeMessage(outcome)
                self?.refresh()
            }
        }
    }

    private var service = CodexQuotaService()
    private var pollTimer: Timer?
    private var session = UUID()

    func start() {
        stop()
        service = CodexQuotaService()
        let currentSession = session
        snapshot = nil
        resetMessage = ""
        status = .loading
        service.onSnapshot = { [weak self] snapshot in
            Task { @MainActor in
                guard self?.session == currentSession else { return }
                self?.snapshot = snapshot
                self?.status = .connected
            }
        }
        service.onError = { [weak self] message in
            Task { @MainActor in
                guard self?.session == currentSession else { return }
                self?.snapshot = nil
                self?.status = .error(message)
            }
        }
        service.start()
        let activeService = service
        let timer = Timer(timeInterval: 45, repeats: true) { _ in
            activeService.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func refresh() {
        status = snapshot == nil ? .loading : status
        service.refresh()
    }

    func stop() {
        session = UUID()
        pollTimer?.invalidate()
        pollTimer = nil
        snapshot = nil
        confirmingReset = false
        resetBusy = false
        service.stop()
    }
}

final class CodexQuotaService {
    var onSnapshot: ((QuotaSnapshot) -> Void)?
    var onError: ((String) -> Void)?

    private let queue = DispatchQueue(label: "app.codex.quota-island.transport")
    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: Pipe?
    private var buffer = Data()
    private var nextRequestID = 1
    private var stopped = false
    private var generation = 0
    private var connectionStamp = ""
    private var pendingRead: Int?
    private var knownCredits: [String: Int] = [:]
    private var pendingReset: (id: Int, completion: (String) -> Void)?
    private let testExecutable: String?

    init(testExecutable: String? = nil) {
        self.testExecutable = testExecutable
    }

    func consumeReset(key: String, expectedStamp: String, completion: @escaping (String) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.stopped, self.process?.isRunning == true, self.pendingReset == nil,
                  expectedStamp == currentCredentialStamp(), expectedStamp == self.connectionStamp else {
                DispatchQueue.main.async { completion("uncertain") }
                return
            }
            let id = self.nextRequestID
            self.nextRequestID += 1
            self.pendingReset = (id, completion)
            self.send(["method": "account/rateLimitResetCredit/consume", "id": id,
                       "params": ["idempotencyKey": key]])
            self.queue.asyncAfter(deadline: .now() + 25) { [weak self] in
                guard let self, self.pendingReset?.id == id else { return }
                self.completeReset("uncertain")
            }
        }
    }

    private func completeReset(_ outcome: String) {
        guard let pending = pendingReset else { return }
        pendingReset = nil
        DispatchQueue.main.async { pending.completion(outcome) }
    }

    func start() {
        queue.async { [weak self] in
            self?.stopped = false
            self?.launchServer()
        }
    }

    func stop() {
        queue.async { [self] in
            self.stopped = true
            self.completeReset("uncertain")
            self.pendingRead = nil
            self.generation += 1
            self.stdout?.fileHandleForReading.readabilityHandler = nil
            try? self.stdin?.close()
            self.process?.terminate()
            self.process = nil
            self.stdin = nil
            self.buffer.removeAll()
        }
    }

    func refresh() {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.stopped else { return }
            if self.process?.isRunning != true {
                self.launchServer()
                return
            }
            self.requestRateLimits()
        }
    }

    private func launchServer() {
        guard !stopped, process?.isRunning != true else { return }
        generation += 1
        connectionStamp = currentCredentialStamp()
        pendingRead = nil
        let connection = generation
        guard let executable = findCodexExecutable() else {
            reportError("未找到 Codex。请先安装或打开 Codex 桌面应用。")
            return
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = testExecutable == nil ? ["app-server"] : ["--mock-server"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.queue.asyncAfter(deadline: .now() + 4) {
                guard !self.stopped, self.generation == connection, self.process?.isRunning != true else { return }
                self.launchServer()
            }
        }

        do {
            try process.run()
        } catch {
            reportError("Codex 数据服务启动失败：\(error.localizedDescription)")
            return
        }

        self.process = process
        self.stdin = inputPipe.fileHandleForWriting
        self.stdout = outputPipe
        self.buffer.removeAll(keepingCapacity: true)

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async {
                guard let self, !self.stopped, self.generation == connection else { return }
                self.consume(data)
            }
        }

        send([
            "method": "initialize",
            "id": 0,
            "params": [
                "clientInfo": [
                    "name": "codex_quota_island",
                    "title": "Codex Quota Island",
                    "version": "1.0.0"
                ]
            ]
        ])
        send(["method": "initialized", "params": [String: Any]()])
        requestRateLimits()
    }

    private func requestRateLimits() {
        guard pendingRead == nil else { return }
        let id = nextRequestID
        nextRequestID += 1
        pendingRead = id
        send(["method": "account/rateLimits/read", "id": id, "params": [String: Any]()])
        queue.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.pendingRead == id else { return }
            self.pendingRead = nil
            self.reportError("额度读取超时，请刷新重试。")
        }
    }

    private func send(_ object: [String: Any]) {
        guard let stdin,
              JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        do {
            try stdin.write(contentsOf: data)
        } catch {
            reportError("读取额度时连接中断，正在重连…")
            process?.terminate()
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            handle(object)
        }
    }

    private func handle(_ message: [String: Any]) {
        let id = message["id"] as? Int
        if let pending = pendingReset, id == pending.id {
            let result = message["result"] as? [String: Any]
            completeReset(result?["outcome"] as? String ?? "uncertain")
            requestRateLimits()
            return
        }
        if id == pendingRead { pendingRead = nil }
        if let error = message["error"] as? [String: Any] {
            let detail = error["message"] as? String ?? "Codex 返回了未知错误"
            reportError(detail)
            return
        }

        if let result = message["result"] as? [String: Any],
           result["rateLimits"] != nil || result["rateLimitsByLimitId"] != nil {
            parseAndPublish(result)
            return
        }

        if message["method"] as? String == "account/rateLimits/updated",
           message["params"] != nil {
            // Update notifications can contain only the changed window. Read the
            // complete snapshot so the compact view never drops the weekly limit.
            requestRateLimits()
        }
    }

    private func parseAndPublish(_ payload: [String: Any]) {
        guard connectionStamp == currentCredentialStamp() else {
            reportError("登录状态发生变化，等待重新同步。")
            return
        }
        let bucket: [String: Any]?
        if let buckets = payload["rateLimitsByLimitId"] as? [String: Any] {
            bucket = (buckets["codex"] as? [String: Any]) ?? buckets.values.compactMap { $0 as? [String: Any] }.first
        } else {
            bucket = payload["rateLimits"] as? [String: Any]
        }
        guard let bucket else { return }

        let primary = parseWindow(bucket["primary"] as? [String: Any])
        let secondary = parseWindow(bucket["secondary"] as? [String: Any])
        guard primary != nil || secondary != nil else {
            reportError("当前账号没有可用的额度数据，请确认已在 Codex 登录。")
            return
        }

        let creditsContainer = payload["rateLimitResetCredits"] as? [String: Any]
        let accountID = payload["accountId"] as? String
        let returnedCredits = number(creditsContainer?["availableCount"]).map(Int.init)
        if let accountID, let returnedCredits { knownCredits[accountID] = returnedCredits }
        let credits = returnedCredits ?? accountID.flatMap { knownCredits[$0] }
        let snapshot = QuotaSnapshot(
            accountID: payload["accountId"] as? String,
            authStamp: connectionStamp,
            primary: primary,
            secondary: secondary,
            planType: bucket["planType"] as? String,
            resetCredits: credits,
            updatedAt: Date()
        )
        let callback = onSnapshot
        DispatchQueue.main.async { callback?(snapshot) }
    }

    private func parseWindow(_ object: [String: Any]?) -> QuotaWindow? {
        guard let object,
              let used = number(object["usedPercent"]),
              let duration = number(object["windowDurationMins"]),
              let reset = number(object["resetsAt"]) else { return nil }
        return QuotaWindow(
            usedPercent: used,
            durationMinutes: Int(duration),
            resetsAt: Date(timeIntervalSince1970: reset)
        )
    }

    private func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private func reportError(_ message: String) {
        let callback = onError
        DispatchQueue.main.async { callback?(message) }
    }

    private func findCodexExecutable() -> String? {
        if let testExecutable { return testExecutable }
        let manager = FileManager.default
        let candidates = [ProcessInfo.processInfo.environment["QUOTANOOK_CODEX"] ?? "",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        if let match = candidates.first(where: { manager.isExecutableFile(atPath: $0) }) {
            return match
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return path.split(separator: ":")
            .map { String($0) + "/codex" }
            .first(where: { manager.isExecutableFile(atPath: $0) })
    }
}

@MainActor
final class IslandPresentation: ObservableObject {
    @Published var expanded = false
}

struct IslandRootView: View {
    @ObservedObject var store: QuotaStore
    @ObservedObject var presentation: IslandPresentation
    let toggle: () -> Void
    let dragChanged: (CGSize) -> Void
    let dragEnded: () -> Void

    var body: some View {
        Group {
            if presentation.expanded {
                ExpandedIslandView(
                    store: store,
                    toggle: toggle,
                    dragChanged: dragChanged,
                    dragEnded: dragEnded
                )
            } else {
                CompactIslandView(
                    store: store,
                    toggle: toggle,
                    dragChanged: dragChanged,
                    dragEnded: dragEnded
                )
            }
        }
    }
}

struct CompactIslandView: View {
    @ObservedObject var store: QuotaStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    let toggle: () -> Void
    let dragChanged: (CGSize) -> Void
    let dragEnded: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            GPTLogo(size: 20)
                .frame(width: 24, height: 24)
            if let primary = store.snapshot?.primary {
                CompactQuotaMetric(window: primary)
                Rectangle().fill(.white.opacity(0.16)).frame(width: 0.5, height: 20)
                if let weekly = store.snapshot?.secondary {
                    CompactQuotaMetric(window: weekly)
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CODEX QUOTA")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                    Text(statusText)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 16)
        .frame(width: 240, height: 40)
        .background {
            IslandAtmosphere()
                .clipShape(Capsule())
                .overlay {
                    Capsule().strokeBorder(LinearGradient(colors: [Color(red: 0.65, green: 0.82, blue: 0.70).opacity(hovering ? 0.40 : 0.24), .white.opacity(0.04), Color(red: 0.20, green: 0.43, blue: 0.32).opacity(0.22)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.7)
                }
        }
        .contentShape(Capsule())
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.20), value: hovering)
        .onTapGesture(perform: toggle)
        .simultaneousGesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .onChanged { dragChanged($0.translation) }
                .onEnded { _ in dragEnded() }
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("点击查看额度详情，拖动可调整位置")
        .help("点击查看详情 · 拖动调整位置")
    }

    private var accentColor: Color {
        colorForRemaining(store.snapshot?.primary?.remainingPercent)
    }

    private var statusText: String {
        switch store.status {
        case .loading: return "正在连接…"
        case .connected: return "已连接"
        case .error: return "连接失败 · 点击查看"
        }
    }
}

struct GPTLogo: View {
    let size: CGFloat

    var body: some View {
        Text("Q")
        .font(.system(size: size, weight: .semibold, design: .rounded))
        .frame(width: size, height: size)
        .foregroundStyle(.white.opacity(0.95))
        .accessibilityLabel("QuotaNook")
    }
}

struct CompactQuotaMetric: View {
    let window: QuotaWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(windowLabel(window.durationMinutes))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.60))
                Spacer(minLength: 1)
                Text(percent(window.remainingPercent))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
            }
            TotalQuotaBar(used: window.usedPercent)
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel("\(windowLabel(window.durationMinutes))，剩余\(percent(window.remainingPercent))")
    }
}

/// Decorative only: never changes the quota fill geometry or intercepts input.
struct IslandAtmosphere: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color(white: 0.045)
            LinearGradient(colors: [Color(red: 0.07, green: 0.14, blue: 0.10).opacity(0.60), .clear, Color(red: 0.05, green: 0.10, blue: 0.08).opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing)
            TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion)) { timeline in
                Canvas { context, size in
                    let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                    for index in 0..<14 {
                        let seed = Double(index)
                        let x = (seed * 0.618 + time * 0.008).truncatingRemainder(dividingBy: 1) * size.width
                        // Keep particles near the perimeter, away from the text.
                        let edge = 2 + (sin(time * 0.55 + seed * 2.3) + 1) * 2
                        let y = index.isMultiple(of: 2) ? edge : size.height - edge
                        let radius = index.isMultiple(of: 3) ? 1.2 : 0.7
                        let alpha = 0.22 + 0.18 * (sin(time * 0.8 + seed) + 1) / 2
                        let dot = CGRect(x: x, y: y, width: radius * 2, height: radius * 2)
                        context.fill(Path(ellipseIn: dot.insetBy(dx: -2, dy: -2)), with: .color(Color(red: 0.61, green: 0.79, blue: 0.65).opacity(alpha * 0.12)))
                        context.fill(Path(ellipseIn: dot), with: .color(Color(red: 0.73, green: 0.86, blue: 0.75).opacity(alpha)))
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct TotalQuotaBar: View {
    let used: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color(white: 0.25))
                Rectangle().fill(LinearGradient(colors: [Color(red: 0.28, green: 0.68, blue: 0.47), Color(red: 0.43, green: 0.81, blue: 0.59), Color(red: 0.72, green: 0.91, blue: 0.75)], startPoint: .leading, endPoint: .trailing))
                    .overlay {
                        if !reduceMotion {
                            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 5) / 5
                                LinearGradient(colors: [.clear, .white.opacity(0.65), .clear], startPoint: .leading, endPoint: .trailing)
                                    .frame(width: 28)
                                    .position(x: -28 + (geometry.size.width + 56) * min(1, phase * 1.5), y: 2.5)
                            }
                            .allowsHitTesting(false)
                        }
                    }
                    .frame(width: geometry.size.width * (100 - min(100, max(0, used))) / 100)
                    .clipped()
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.65), value: used)
            }
            .clipShape(RoundedRectangle(cornerRadius: 2))
        }
        .frame(height: 5)
        .help("完整底槽代表总额度 100%，翡翠绿为剩余，深灰色为已用。")
        .accessibilityLabel("总额度百分之百，已用百分之\(Int(used.rounded()))，翡翠绿剩余，深灰色已用")
    }
}

struct ExpandedIslandView: View {
    @ObservedObject var store: QuotaStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    let toggle: () -> Void
    let dragChanged: (CGSize) -> Void
    let dragEnded: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            GPTLogo(size: 20)
                            Text("QuotaNook")
                                .font(.system(size: 18, weight: .semibold))
                        }
                        Text(connectionSubtitle)
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.43))
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 3, coordinateSpace: .global)
                            .onChanged { dragChanged($0.translation) }
                            .onEnded { _ in dragEnded() }
                    )
                    Spacer()
                    Button(action: { store.refresh() }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .help("立即刷新")

                    Button(action: toggle) {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .help("收起")
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 16)

                if let snapshot = store.snapshot {
                    VStack(spacing: 12) {
                        if let primary = snapshot.primary {
                            QuotaRow(title: windowName(primary.durationMinutes), window: primary, now: context.date)
                        }
                        if let secondary = snapshot.secondary {
                            Rectangle().fill(.white.opacity(0.12)).frame(height: 0.5)
                            QuotaRow(title: windowName(secondary.durationMinutes), window: secondary, now: context.date)
                        }
                    }
                    .padding(.horizontal, 24)
                } else {
                    errorOrLoading
                        .frame(maxWidth: .infinity, minHeight: 130)
                        .padding(.horizontal, 18)
                }

                Rectangle().fill(.white.opacity(0.12)).frame(height: 0.5)
                    .padding(.horizontal, 24).padding(.top, 12)
                VStack(alignment: .leading, spacing: 7) {
                    if store.confirmingReset {
                        Text("确认使用当前账号的 1 张重置卡？")
                            .font(.system(size: 11, weight: .semibold))
                        HStack {
                            Button("取消") { store.confirmingReset = false }
                            Spacer()
                            Button("确认使用 1 张") { store.confirmReset() }
                                .disabled(!store.canReset)
                        }
                    } else {
                        HStack {
                            Text(store.snapshot?.resetCredits.map { "重置卡 · \($0) 张" } ?? "重置卡 · 暂未返回数量")
                                .font(.system(size: 11))
                            Spacer()
                            Button(store.resetBusy ? "处理中…" : "使用重置卡") {
                                store.confirmingReset = true
                            }
                            .disabled(!store.canReset)
                        }
                    }
                    if !store.resetMessage.isEmpty && !store.confirmingReset {
                        Text(store.resetMessage)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.65))
                            .lineLimit(1)
                            .help(store.resetMessage)
                    }
                }
                .buttonStyle(.bordered)
                .tint(.gray)
                .padding(.horizontal, 24)
                .padding(.top, 12)

                Spacer().frame(height: 10)

                HStack {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(store.snapshot == nil ? Color.orange : Color.green)
                            .frame(width: 5, height: 5)
                        Text(footerText)
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.42))
                    }
                    Spacer()
                    Button("退出") { NSApplication.shared.terminate(nil) }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.48))
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 14)
            }
            .opacity(reduceMotion || appeared ? 1 : 0)
            .offset(y: reduceMotion || appeared ? 0 : 4)
            .frame(width: 350, height: 350, alignment: .top)
            .foregroundStyle(.white)
            .background {
                IslandAtmosphere()
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .strokeBorder(LinearGradient(colors: [Color(red: 0.65, green: 0.82, blue: 0.70).opacity(0.24), .white.opacity(0.04), Color(red: 0.20, green: 0.43, blue: 0.32).opacity(0.18)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.7)
                    }
            }
        }
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
                appeared = true
            }
        }
    }

    @ViewBuilder
    private var errorOrLoading: some View {
        switch store.status {
        case .loading, .connected:
            VStack(spacing: 10) {
                ProgressView().controlSize(.small).tint(.white)
                Text("正在读取 Codex 额度…")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
            }
        case .error(let message):
            VStack(spacing: 9) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                Button("重试", action: { store.refresh() })
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.white.opacity(0.10)))
            }
        }
    }

    private var connectionSubtitle: String {
        guard let snapshot = store.snapshot else { return "LOCAL APP SERVER" }
        let plan = snapshot.planType?.uppercased() ?? "CHATGPT"
        return "\(plan) · 每 45 秒自动刷新"
    }

    private var footerText: String {
        guard let snapshot = store.snapshot else { return "等待 Codex 数据服务" }
        var parts = ["实时连接"]
        if let credits = snapshot.resetCredits { parts.append("重置券 \(credits)") }
        parts.append("更新于 \(snapshot.updatedAt.formatted(date: .omitted, time: .shortened))")
        return parts.joined(separator: " · ")
    }
}

struct QuotaRow: View {
    let title: String
    let window: QuotaWindow
    let now: Date

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(windowLabel(window.durationMinutes))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer()
                Text(percent(window.remainingPercent))
                    .font(.system(size: 22, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                Text("剩余")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.36))
            }

            TotalQuotaBar(used: window.usedPercent)
            HStack {
                Text("已用 \(percent(window.usedPercent))")
                Spacer()
                Text("总量 100%")
            }
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.52))
            Text("\(resetText(window.resetsAt, now: now))后恢复")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.white.opacity(0.42))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct CodexMark: View {
    let color: Color
    let spinning: Bool
    @State private var rotation = 0.0

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.13), lineWidth: 3)
            if spinning {
                Circle()
                    .trim(from: 0.06, to: 0.78)
                    .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(rotation))
            } else {
                Circle().stroke(color.opacity(0.85), lineWidth: 2)
            }
            Circle().fill(color).frame(width: 4, height: 4)
        }
        .frame(width: 22, height: 22)
        .onAppear {
            guard spinning else { return }
            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { rotation = 360 }
        }
        .onChange(of: spinning) { value in
            if value {
                rotation = 0
                withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { rotation = 360 }
            }
        }
    }
}

func colorForRemaining(_ value: Double?) -> Color {
    guard let value else { return .cyan }
    if value <= 15 { return Color(red: 1.0, green: 0.28, blue: 0.30) }
    if value <= 35 { return Color(red: 1.0, green: 0.64, blue: 0.18) }
    return Color(white: 0.85)
}

func percent(_ value: Double) -> String {
    "\(Int(value.rounded()))%"
}

func windowLabel(_ minutes: Int) -> String {
    if minutes >= 1440, minutes % 1440 == 0 { return "\(minutes / 1440)天" }
    if minutes >= 60, minutes % 60 == 0 { return "\(minutes / 60)小时" }
    return "\(minutes)分钟"
}

func windowName(_ minutes: Int) -> String {
    "\(windowLabel(minutes))窗口"
}

func resetText(_ date: Date, now: Date) -> String {
    let remaining = max(0, Int(date.timeIntervalSince(now)))
    if remaining == 0 { return "即将" }
    let days = remaining / 86_400
    let hours = (remaining % 86_400) / 3_600
    let minutes = (remaining % 3_600) / 60
    let seconds = remaining % 60
    if days > 0 { return "\(days)天 \(hours)小时" }
    if hours > 0 { return "\(hours)小时 \(minutes)分 \(seconds)秒" }
    return String(format: "%02d:%02d", minutes, seconds)
}

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { false }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    required init(rootView: Content) {
        super.init(rootView: rootView)
        sizingOptions = []
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
    }
}

@MainActor
final class IslandWindowController: NSObject {
    private let panel: IslandPanel
    private let presentation: IslandPresentation
    private let compactSize = NSSize(width: 240, height: 40)
    private let expandedSize = NSSize(width: 350, height: 350)
    private var dragStartOrigin: NSPoint?
    private var dragStartMouseLocation: NSPoint?
    private var userPositioned = false

    init(store: QuotaStore) {
        self.presentation = IslandPresentation()
        self.panel = IslandPanel(
            contentRect: NSRect(origin: .zero, size: compactSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none

        let root = IslandRootView(
            store: store,
            presentation: presentation,
            toggle: { [weak self] in self?.toggle() },
            dragChanged: { [weak self] translation in self?.dragChanged(translation) },
            dragEnded: { [weak self] in self?.dragEnded() }
        )
        panel.contentView = TransparentHostingView(rootView: root)
        anchor(size: compactSize, animated: false)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func setVisible(_ visible: Bool) {
        if visible { panel.orderFrontRegardless() }
        else { panel.orderOut(nil) }
    }

    @objc private func screenParametersChanged() {
        let size = presentation.expanded ? expandedSize : compactSize
        if userPositioned {
            panel.setFrame(constrainedFrame(NSRect(origin: panel.frame.origin, size: size)), display: true)
        } else {
            anchor(size: size, animated: false)
        }
    }

    func toggle(activate: Bool = true) {
        presentation.expanded.toggle()
        let target = presentation.expanded ? expandedSize : compactSize
        if userPositioned {
            let current = panel.frame
            let proposed = NSRect(
                x: current.midX - target.width / 2,
                y: current.maxY - target.height,
                width: target.width,
                height: target.height
            )
            panel.setFrame(constrainedFrame(proposed), display: true, animate: false)
        } else {
            anchor(size: target, animated: false)
        }
        if activate { panel.makeKeyAndOrderFront(nil) }
    }

    func verifyLayout() {
        for _ in 0..<40 {
            toggle(activate: false)
            panel.contentView?.layoutSubtreeIfNeeded()
            let expected = presentation.expanded ? expandedSize : compactSize
            precondition(panel.frame.size == expected, "Unexpected window resize")
        }
        precondition(!presentation.expanded)
    }

    private func dragChanged(_ translation: CGSize) {
        if dragStartOrigin == nil {
            dragStartOrigin = panel.frame.origin
            dragStartMouseLocation = NSEvent.mouseLocation
        }
        guard let start = dragStartOrigin,
              let mouseStart = dragStartMouseLocation else { return }
        let mouseNow = NSEvent.mouseLocation
        let proposed = NSRect(
            origin: NSPoint(
                x: start.x + mouseNow.x - mouseStart.x,
                y: start.y + mouseNow.y - mouseStart.y
            ),
            size: panel.frame.size
        )
        panel.setFrame(constrainedFrame(proposed), display: true)
    }

    private func dragEnded() {
        guard dragStartOrigin != nil else { return }
        dragStartOrigin = nil
        dragStartMouseLocation = nil
        userPositioned = true
    }

    private func constrainedFrame(_ proposed: NSRect) -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.screens.max(by: {
                $0.frame.intersection(proposed).width * $0.frame.intersection(proposed).height
                    < $1.frame.intersection(proposed).width * $1.frame.intersection(proposed).height
            })
            ?? NSScreen.main
        guard let screen else { return proposed }
        let margin: CGFloat = 4
        let minX = screen.frame.minX + margin
        let maxX = screen.frame.maxX - proposed.width - margin
        let minY = screen.visibleFrame.minY + margin
        let maxY = screen.frame.maxY - proposed.height - margin
        return NSRect(
            x: min(max(proposed.minX, minX), maxX),
            y: min(max(proposed.minY, minY), maxY),
            width: proposed.width,
            height: proposed.height
        )
    }

    private func anchor(size: NSSize, animated: Bool) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let x = screen.frame.midX - size.width / 2
        let y = screen.frame.maxY - size.height - 4
        let frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        panel.setFrame(frame, display: true, animate: animated)
    }
}

struct SyncState {
    enum Action: Equatable { case none, start, stop, reload }
    private(set) var running = false
    private var credentialStamp = ""

    mutating func update(running next: Bool, stamp: String) -> Action {
        defer { running = next; credentialStamp = stamp }
        if next != running { return next ? .start : .stop }
        if next && stamp != credentialStamp { return .reload }
        return .none
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: QuotaStore?
    private var islandController: IslandWindowController?
    private var syncTimer: Timer?
    private var syncState = SyncState()

    @objc private func synchronize() {
        let running = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.openai.codex" && !$0.isTerminated
        }
        let action = syncState.update(running: running, stamp: currentCredentialStamp())
        switch action {
        case .start, .reload:
            store?.start()
            islandController?.setVisible(true)
        case .stop:
            islandController?.setVisible(false)
            store?.stop()
        case .none:
            break
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let store = QuotaStore()
        self.store = store
        islandController = IslandWindowController(store: store)
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didWakeNotification] {
            center.addObserver(self, selector: #selector(synchronize), name: name, object: nil)
        }
        synchronize()
        let timer = Timer(timeInterval: 2, target: self, selector: #selector(synchronize), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        syncTimer = timer
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.stop()
        syncTimer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}

@main
enum CodexQuotaIslandMain {
    private static var appDelegate: AppDelegate?

    static func main() {
        if CommandLine.arguments.contains("--mock-server") { IslandTests.mockServer(); return }
        if CommandLine.arguments.contains("--transport-test") { IslandTests.transport(); return }
        if CommandLine.arguments.contains("--layout-test") { IslandTests.layout(); return }
        if CommandLine.arguments.contains("--self-test") {
            var state = SyncState()
            precondition(state.update(running: false, stamp: "A") == .none)
            precondition(state.update(running: true, stamp: "A") == .start)
            precondition(state.update(running: true, stamp: "A") == .none)
            precondition(state.update(running: true, stamp: "B") == .reload)
            precondition(state.update(running: true, stamp: "missing") == .reload)
            precondition(state.update(running: false, stamp: "missing") == .stop)
            precondition(state.update(running: false, stamp: "C") == .none)
            precondition(state.update(running: true, stamp: "C") == .start)
            print("PASS: launch, quit, relaunch, unchanged auth, account switch, logout, offline changes")
            return
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        appDelegate = delegate
        application.delegate = delegate
        application.run()
    }
}
