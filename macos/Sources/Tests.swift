import AppKit
import Foundation

enum IslandTests {
    static func mockServer() {
        var redeemed = Set<String>()
        while let line = readLine() {
            guard let data = line.data(using: .utf8),
                  let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = request["id"] as? Int else { continue }
            var result: [String: Any] = [:]
            switch request["method"] as? String {
            case "account/rateLimits/read":
                result = ["accountId": "test-account", "rateLimits": [
                    "primary": ["usedPercent": 40, "windowDurationMins": 300, "resetsAt": 1900000000],
                    "secondary": ["usedPercent": 20, "windowDurationMins": 10080, "resetsAt": 1900100000],
                    "planType": "test"] as [String: Any], "rateLimitResetCredits": ["availableCount": 2]]
            case "account/rateLimitResetCredit/consume":
                let params = request["params"] as! [String: Any]
                let key = params["idempotencyKey"] as! String
                if key == "timeout" { continue }
                let outcome: String
                if key == "empty" { outcome = "noCredit" }
                else if key == "none" { outcome = "nothingToReset" }
                else if redeemed.contains(key) { outcome = "alreadyRedeemed" }
                else { redeemed.insert(key); outcome = "reset" }
                result = ["outcome": outcome]
            default: break
            }
            var response = try! JSONSerialization.data(withJSONObject: ["id": id, "result": result] as [String: Any])
            response.append(10)
            FileHandle.standardOutput.write(response)
        }
    }

    static func transport() {
        let service = CodexQuotaService(testExecutable: URL(fileURLWithPath: CommandLine.arguments[0]).path)
        let cases = [("one", "reset"), ("one", "alreadyRedeemed"), ("none", "nothingToReset"), ("empty", "noCredit"), ("timeout", "uncertain")]
        var started = false
        var complete = false
        var index = 0
        func next() {
            if index == cases.count { complete = true; return }
            let item = cases[index]
            service.consumeReset(key: item.0, expectedStamp: currentCredentialStamp()) { outcome in
                precondition(outcome == item.1, "Unexpected reset outcome: \(outcome)")
                index += 1
                next()
            }
        }
        service.onError = { message in fatalError(message) }
        service.onSnapshot = { snapshot in
            precondition(snapshot.accountID == "test-account")
            precondition(snapshot.primary?.remainingPercent == 60)
            precondition(snapshot.resetCredits == 2)
            guard !started else { return }
            started = true
            service.consumeReset(key: "never-send", expectedStamp: "stale-account") { outcome in
                precondition(outcome == "uncertain")
                next()
            }
        }
        service.start()
        let deadline = Date().addingTimeInterval(35)
        while !complete && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        service.stop()
        precondition(complete, "Transport test timed out")
        print("PASS: fake transport, snapshot decode, reset, idempotent retry, noCredit, nothingToReset, timeout, account guard; no live credits consumed")
    }

    @MainActor static func layout() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let store = QuotaStore()
        let controller = IslandWindowController(store: store)
        controller.verifyLayout()
        precondition(store.snapshot == nil)
        print("PASS: 40 offscreen expand/collapse cycles; fixed sizes; no network connection")
    }
}
