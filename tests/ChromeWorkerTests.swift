import AppKit

@main struct ChromeWorkerTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clinqy-worker-tests-\(UUID())")
        let worker = ChromeWorker(root: root.appendingPathComponent("worker"))
        let other = ChromeWorker(root: root.appendingPathComponent("other"))
        let recovered = ChromeWorker(root: root.appendingPathComponent("worker"))
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let clipboard = NSPasteboard.general.changeCount
        var checks = 0
        func check(_ value: Bool, _ label: String) throws { guard value else { throw WorkerCDP.error(label) }; checks += 1 }
        func page(_ label: String) -> String {
            let html = "<title>\(label)</title><label>Name<input id='name'></label><label>Resume<input id='upload' type='file' onchange=\"setTimeout(async()=>{document.querySelector('#uploadStatus').textContent=await this.files[0].text()},100)\"></label><button onclick=\"document.querySelector('#upload').click()\">Attach sample</button><p id='uploadStatus'></p><button onclick=\"document.body.dataset.sent='yes';this.textContent='Confirmed'\">Submit sample</button>"
            return "data:text/html;base64," + Data(html.utf8).base64EncodedString()
        }
        do {
            worker.runStarted()
            other.runStarted()
            let firstURL = page("Worker"), secondURL = page("Concurrent browser")
            async let first = worker.newTab(firstURL)
            async let second = other.newTab(secondURL)
            let (id, otherID) = try await (first, second)
            try await Task.sleep(for: .milliseconds(500))
            let snap = try await worker.command("snapshot", tabID: id)
            let elements = snap["elements"] as? [[String: Any]] ?? []
            let name = elements.first { ["textbox", "text"].contains($0["role"] as? String ?? "") }?["i"] as? Int
            try check(name != nil, "snapshots owned form")
            _ = try await worker.command("fill", tabID: id, args: ["index": name!, "text": "Background only"])
            let review = try await worker.command("review", tabID: id)
            try check(String(describing: review).contains("Background only"), "reviews actual field value")
            _ = try await worker.command("focus", tabID: id, args:["index": name!])
            _ = try await worker.command("cdpKey", tabID: id, args:["keys":"cmd+a"])
            _ = try await worker.command("cdpType", tabID: id, args:["text":"Trusted worker input"])
            let typed = try await worker.command("value", tabID: id, args:["index":name!])
            try check(typed["value"] as? String == "Trusted worker input", "trusted input stays in worker field")
            let submit = elements.first { ($0["text"] as? String ?? "").contains("Submit sample") }!["i"] as! Int
            _ = try await worker.command("click", tabID: id, args:["index":submit])
            let sent = try await worker.command("read", tabID: id)
            try check((sent["text"] as? String ?? "").contains("Confirmed"), "clicks and confirms local sample submission")
            let file = elements.first { $0["role"] as? String == "file" || ($0["text"] as? String ?? "").contains("Resume") }?["i"] as? Int
            var args: [String: Any] = ["name":"sample.txt", "type":"text/plain", "data":Data("test attachment".utf8).base64EncodedString()]
            if let file { args["index"] = file }
            let upload = try await worker.command("upload", tabID: id, args: args)
            try check(upload["ok"] as? Bool == true, "uploads bytes without host picker")
            let attach = elements.first { ($0["text"] as? String ?? "").contains("Attach sample") }!["i"] as! Int
            var via = args; via["index"] = attach
            let chooser = try await worker.command("uploadVia", tabID: id, args:via)
            try check(chooser["ok"] as? Bool == true, "intercepts file chooser without opening Finder")
            try await Task.sleep(for: .milliseconds(500))
            let uploadRead = try await worker.command("read", tabID: id)
            try check((uploadRead["text"] as? String ?? "").contains("test attachment"), "uploaded file remains readable after picker returns")
            let photo = try await worker.command("captureTask", tabID: id)
            try check((photo["image"] as? String)?.isEmpty == false, "captures owned task screenshot")
            let otherSnap = try await other.command("snapshot", tabID: otherID)
            let otherEls = otherSnap["elements"] as? [[String: Any]] ?? []
            let otherName = otherEls.first { ["textbox", "text"].contains($0["role"] as? String ?? "") }!["i"] as! Int
            let otherValue = try await other.command("value", tabID: otherID, args:["index":otherName])
            try check(otherValue["value"] as? String == "", "concurrent browser field unchanged")
            do { _ = try await worker.command("snapshot", tabID: -99); preconditionFailure("accepted unowned tab") } catch { checks += 1 }
            do { _ = try await worker.command("cdpKey", tabID: id, args:["keys":"cmd+v"]); preconditionFailure("accepted shared clipboard shortcut") } catch { checks += 1 }
            let disposable = try await worker.newTab(page("Disposable"))
            let completedRun = worker.generation
            await worker.runEnded(keep: id, generation: completedRun)
            do { _ = try await worker.command("tabInfo", tabID: disposable); preconditionFailure("kept unused task tab") } catch { checks += 1 }
            let finalPhoto = try await worker.command("captureTask", tabID: id)
            try check((finalPhoto["image"] as? String)?.isEmpty == false, "captures retained tab after idle freeze")
            worker.runStarted()
            await worker.runEnded(keep: nil, generation: completedRun)
            let retained = try await worker.command("tabInfo", tabID: id)
            try check(retained["title"] as? String == "Worker", "stale cleanup leaves the next run's tab alone")
            let recoveredID = try await recovered.newTab(page("Recovered worker"))
            let recoveredInfo = try await recovered.command("tabInfo", tabID: recoveredID)
            try check(recoveredInfo["title"] as? String == "Recovered worker", "reclaims orphaned owned process without replaying its old target")
            await worker.stop()
            do { _ = try await worker.command("fill", tabID: id, args:["index": name!, "text":"must fail"]); preconditionFailure("fell through after disconnect") } catch { checks += 1 }
            try check(NSPasteboard.general.changeCount == clipboard, "host clipboard unchanged")
            try check(NSWorkspace.shared.frontmostApplication?.processIdentifier == front, "host foreground app unchanged")
            await recovered.stop(); await other.stop()
            try? FileManager.default.removeItem(at: root)
            print("PASS: \(checks) headless Chrome isolation checks")
        } catch {
            await worker.stop(); await recovered.stop(); await other.stop()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }
}
