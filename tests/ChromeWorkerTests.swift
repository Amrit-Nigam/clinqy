import AppKit

@MainActor private final class WorkerActivationLog { var pids: [pid_t] = [] }

@MainActor private final class WorkerObservations {
    var observations: [ObjectIdentifier: [Int: [String: Any]]] = [:]
    func command(_ owner: ChromeWorker, _ name: String, tabID: Int?, args: [String: Any] = [:]) async throws -> [String: Any] {
        var parameters = args
        if let tabID, let token = observations[owner.identity]?[tabID] {
            parameters.merge(token) { _, new in new }
        }
        let result = try await owner.command(name, tabID: tabID, args: parameters)
        if name == "snapshot", let tabID, let document = result["documentID"], let snapshot = result["snapshotID"] {
            observations[owner.identity, default: [:]][tabID] = ["documentID": document, "snapshotID": snapshot]
        }
        return result
    }
}

@main struct ChromeWorkerTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clinqy-worker-tests-\(UUID())")
        let worker = ChromeWorker(root: root.appendingPathComponent("worker"))
        let other = ChromeWorker(root: root.appendingPathComponent("other"))
        let recovered = ChromeWorker(root: root.appendingPathComponent("worker"))
        let activations = WorkerActivationLog()
        var ownedPIDs: Set<pid_t> = []
        let observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                         object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                    activations.pids.append(app.processIdentifier)
                }
            }
        }
        defer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        func rememberPID(_ profile: String) throws {
            let data = try Data(contentsOf: root.appendingPathComponent(profile + "/owner.json"))
            let owner = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            ownedPIDs.insert(pid_t(owner["pid"] as! Int))
        }
        let probe = WorkerObservations()
        let clipboard = NSPasteboard.general.changeCount
        var checks = 0
        func check(_ value: Bool, _ label: String) throws { guard value else { throw WorkerCDP.error(label) }; checks += 1 }
        func page(_ label: String) -> String {
            let html = "<button onclick=\"const field=document.createElement('input');field.setAttribute('aria-label','Dynamic field');document.body.append(field)\">Add field</button><title>\(label)</title><nav><img src='http://127.0.0.1:1/nav.png' width='90' height='70'></nav><img src='http://127.0.0.1:1/article.png' alt='Article image' width='90' height='70'><img src='http://127.0.0.1:1/icon.png' width='16' height='16'><label>Name<input id='name'></label><label>Resume<input id='upload' type='file' onchange=\"setTimeout(async()=>{document.querySelector('#uploadStatus').textContent=await this.files[0].text()},100)\"></label><button onclick=\"document.querySelector('#upload').click()\">Attach sample</button><p id='uploadStatus'></p><button onclick=\"document.body.dataset.sent='yes';this.textContent='Confirmed'\">Submit sample</button>"
            return "data:text/html;base64," + Data(html.utf8).base64EncodedString()
        }
        func token(_ snapshot: [String: Any], _ args: [String: Any] = [:]) -> [String: Any] {
            args.merging(["documentID": snapshot["documentID"]!, "snapshotID": snapshot["snapshotID"]!]) { _, new in new }
        }
        func setup() async throws -> (Int, Int) {
            worker.runStarted()
            other.runStarted()
            let firstURL = page("Worker"), secondURL = page("Concurrent browser")
            async let first = worker.newTab(firstURL)
            async let second = other.newTab(secondURL)
            let (id, otherID) = try await (first, second)
            try rememberPID("worker"); try rememberPID("other")
            let sourceAURL = page("Delegated source A"), sourceBURL = page("Delegated source B")
            async let sourceA = worker.newTab(sourceAURL, select: false)
            async let sourceB = worker.newTab(sourceBURL, select: false)
            let (sourceAID, sourceBID) = try await (sourceA, sourceB)
            try check(sourceAID != sourceBID && sourceAID != id, "parallel source tabs have distinct owned IDs")
            let tabList = try await worker.command("tabs", tabID: nil)["tabs"] as? [[String: Any]] ?? []
            try check(tabList.first(where: { $0["active"] as? Bool == true })?["id"] as? Int == id,
                      "delegated source tabs don't replace the lead's selected tab")
            async let sourceASnapshot = probe.command(worker, "snapshot", tabID: sourceAID)
            async let sourceBSnapshot = probe.command(worker, "snapshot", tabID: sourceBID)
            _ = try await (sourceASnapshot, sourceBSnapshot)
            async let sourceAText = probe.command(worker, "read", tabID: sourceAID)
            async let sourceBText = probe.command(worker, "read", tabID: sourceBID)
            let (aText, bText) = try await (sourceAText, sourceBText)
            try check((aText["text"] as? String)?.contains("Name") == true && (bText["text"] as? String)?.contains("Name") == true,
                      "parallel reads are pinned to their source tabs")
            _ = try await worker.command("closeTab", tabID: sourceAID)
            _ = try await worker.command("closeTab", tabID: sourceBID)
            let leadTab = try await worker.command("tabInfo", tabID: id)
            try check(leadTab["title"] as? String == "Worker", "source-tab cleanup preserves the lead's task")
            try await Task.sleep(for: .milliseconds(500))
            return (id, otherID)
        }
        func inputChecks(id: Int) async throws -> Int? {
            let snap = try await probe.command(worker, "snapshot", tabID: id)
            let imageList = try await probe.command(worker, "images", tabID: id)["images"] as? [[String: Any]] ?? []
            try check(imageList.count == 1 && imageList[0]["alt"] as? String == "Article image", "real browser image discovery excludes navigation and icons")
            try check(imageList.first?["url"] as? String == "http://127.0.0.1:1/article.png", "real browser image source addresses are exposed without focus")
            let elements = snap["elements"] as? [[String: Any]] ?? []
            let name = elements.first { ["textbox", "text"].contains($0["role"] as? String ?? "") }?["i"] as? Int
            try check(name != nil, "snapshots owned form")
            _ = try await probe.command(worker, "fill", tabID: id, args: ["index": name!, "text": "Background only"])
            let review = try await probe.command(worker, "review", tabID: id)
            try check(String(describing: review).contains("Background only"), "reviews actual field value")
            _ = try await probe.command(worker, "focus", tabID: id, args:["index": name!])
            _ = try await probe.command(worker, "cdpKey", tabID: id, args:["keys":"cmd+a"])
            _ = try await probe.command(worker, "cdpType", tabID: id, args:["text":"Trusted worker input"])
            let typed = try await probe.command(worker, "value", tabID: id, args:["index":name!])
            try check(typed["value"] as? String == "Trusted worker input", "trusted input stays in worker field")
            let batch = try await probe.command(worker, "values", tabID: id, args: ["indices": [name!]])
            try check((batch["values"] as? [String: Any])?[String(name!)] as? String == "Trusted worker input", "batched field checks read current values")
            let add = elements.first { ($0["text"] as? String ?? "") == "Add field" }!["i"] as! Int
            _ = try await probe.command(worker, "click", tabID: id, args: ["index": add])
            let changedDOM = try await probe.command(worker, "snapshot", tabID: id)
            try check((changedDOM["elements"] as? [[String: Any]])?.contains { $0["text"] as? String == "Dynamic field" } == true, "candidate cache invalidates when the DOM adds a control")
            let slowRead = Task { try await probe.command(worker, "waitText", tabID: id, args: ["text": "fixture-that-never-appears", "ms": 5_000]) }
            try await Task.sleep(for: .milliseconds(40))
            let cancelledAt = Date(); slowRead.cancel()
            do { _ = try await slowRead.value; preconditionFailure("cancelled CDP read completed") } catch { checks += 1 }
            try check(Date().timeIntervalSince(cancelledAt) < 1, "cancelled browser commands return promptly")
            let submit = elements.first { ($0["text"] as? String ?? "").contains("Submit sample") }!["i"] as! Int
            _ = try await probe.command(worker, "click", tabID: id, args:["index":submit])
            let sent = try await probe.command(worker, "read", tabID: id)
            try check((sent["text"] as? String ?? "").contains("Confirmed"), "clicks and confirms local sample submission")
            let file = elements.first { $0["role"] as? String == "file" || ($0["text"] as? String ?? "").contains("Resume") }?["i"] as? Int
            var args: [String: Any] = ["name":"sample.txt", "type":"text/plain", "data":Data("test attachment".utf8).base64EncodedString()]
            if let file { args["index"] = file }
            let upload = try await probe.command(worker, "upload", tabID: id, args: args)
            try check(upload["ok"] as? Bool == true, "uploads bytes without host picker")
            let attach = elements.first { ($0["text"] as? String ?? "").contains("Attach sample") }!["i"] as! Int
            var via = args; via["index"] = attach
            let chooser = try await probe.command(worker, "uploadVia", tabID: id, args:via)
            try check(chooser["ok"] as? Bool == true, "intercepts file chooser without opening Finder")
            var uploadRead: [String: Any] = [:]
            // Chrome may throttle a background page's 100 ms timer to one second.
            for _ in 0..<30 {
                uploadRead = try await probe.command(worker, "read", tabID: id)
                if (uploadRead["text"] as? String ?? "").contains("test attachment") { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            try check((uploadRead["text"] as? String ?? "").contains("test attachment"), "uploaded file remains readable after picker returns")
            let photo = try await probe.command(worker, "captureTask", tabID: id)
            try check((photo["image"] as? String)?.isEmpty == false, "captures owned task screenshot")
            let png = Data(base64Encoded: photo["image"] as! String)!
            try check(Array(png.prefix(4)) == [137, 80, 78, 71], "exported screenshot remains PNG")
            let preview = try await probe.command(worker, "capturePreview", tabID: id)
            let jpeg = Data(base64Encoded: preview["image"] as! String)!
            try check(Array(jpeg.prefix(2)) == [255, 216], "live preview uses JPEG")
            let bitmap = NSBitmapImageRep(data: jpeg)
            try check(bitmap?.pixelsWide == 1440 && bitmap?.pixelsHigh == 900, "preview preserves the full viewport")
            if let sample = ProcessInfo.processInfo.environment["CLINQY_TEST_PREVIEW"] {
                try jpeg.write(to: URL(fileURLWithPath: sample))
            }
            let vision = try await probe.command(worker, "captureVision", tabID: id)
            try check(Array(Data(base64Encoded: vision["image"] as! String)!.prefix(2)) == [255, 216], "model screenshot matches JPEG media type")
            return name
        }
        func navigationChecks(id: Int, otherID: Int) async throws -> Void {
            let otherSnap = try await probe.command(other, "snapshot", tabID: otherID)
            let otherEls = otherSnap["elements"] as? [[String: Any]] ?? []
            let otherName = otherEls.first { ["textbox", "text"].contains($0["role"] as? String ?? "") }!["i"] as! Int
            let otherValue = try await probe.command(other, "value", tabID: otherID, args:["index":otherName])
            try check(otherValue["value"] as? String == "", "concurrent browser field unchanged")
            do { _ = try await probe.command(worker, "snapshot", tabID: -99); preconditionFailure("accepted unowned tab") } catch { checks += 1 }
            do { _ = try await probe.command(worker, "cdpKey", tabID: id, args:["keys":"cmd+v"]); preconditionFailure("accepted shared clipboard shortcut") } catch { checks += 1 }
            let navigated = try await worker.newTab(page("Before navigation"))
            _ = try await probe.command(worker, "snapshot", tabID: navigated)
            _ = try await probe.command(worker, "navigate", tabID: navigated, args: ["url": page("After navigation")])
            try await Task.sleep(for: .milliseconds(500))
            let nextSnapshot = try await probe.command(worker, "snapshot", tabID: navigated)
            try check(nextSnapshot["title"] as? String == "After navigation", "reinstalls page helpers after navigation")
        }
        func embeddedChecks() async throws -> Void {
            let embeddedHTML = "<title>Embedded form</title><iframe srcdoc=\"<label>Embedded name<input></label>\"></iframe><iframe srcdoc=\"<label>Second name<input></label>\"></iframe>"
            let embedded = try await worker.newTab("data:text/html;base64," + Data(embeddedHTML.utf8).base64EncodedString())
            try await Task.sleep(for: .milliseconds(300))
            let embeddedSnapshot = try await probe.command(worker, "snapshot", tabID: embedded)
            let embeddedElements = embeddedSnapshot["elements"] as? [[String: Any]] ?? []
            let embeddedField = embeddedElements.first { ["textbox", "text"].contains($0["role"] as? String ?? "") }?["i"] as? Int
            try check(embeddedField != nil, "snapshots embedded frame with cached helpers")
            _ = try await probe.command(worker, "fill", tabID: embedded, args: ["index": embeddedField!, "text": "Inside frame"])
            let embeddedValue = try await probe.command(worker, "value", tabID: embedded, args: ["index": embeddedField!])
            try check(embeddedValue["value"] as? String == "Inside frame", "cached frame context routes actions to the right document")
            let frameFields = embeddedElements.filter { ["textbox", "text"].contains($0["role"] as? String ?? "") }.compactMap { $0["i"] as? Int }
            try check(frameFields.count == 2, "concurrent snapshots include both embedded frames")
            let frameBatch = try await probe.command(worker, "values", tabID: embedded, args: ["indices": frameFields])
            let frameValues = frameBatch["values"] as? [String: Any] ?? [:]
            try check(frameValues[String(embeddedField!)] as? String == "Inside frame" && frameValues.count == 2, "batch reads stay pinned to the correct iframe")
        }
        func freshnessChecks() async throws -> Void {
            // Freshness tokens must bind a command to the exact document/listing, not just a URL or label.
            let fixture = "<title>Freshness</title><button id='target' onclick=\"document.querySelector('#result').textContent+='target;'\">Duplicate</button><button onclick=\"document.querySelector('#result').textContent+='second;'\">Duplicate</button><button onclick=\"const n=document.querySelector('#target');n.replaceWith(n.cloneNode(true))\">Replace target</button><button onclick=\"document.querySelector('#target').style.marginLeft='60px'\">Move target</button><button onclick=\"const ds=[...document.querySelectorAll('button')].filter(b=>b.textContent==='Duplicate');ds[0].before(ds[1])\">Reorder duplicates</button><p id='result'></p><iframe srcdoc=\"<label>Frame field<input></label>\"></iframe><button onclick=\"const f=document.querySelector('iframe');f.srcdoc=f.srcdoc\">Reload frame</button>"
            let fixtureURL = "data:text/html;base64," + Data(fixture.utf8).base64EncodedString()
            let freshID = try await worker.newTab(fixtureURL)
            try await Task.sleep(for: .milliseconds(300))
            func index(_ snapshot: [String: Any], _ text: String, occurrence: Int = 0) -> Int {
                let matching = (snapshot["elements"] as! [[String: Any]]).filter { $0["text"] as? String == text }
                return matching[occurrence]["i"] as! Int
            }
            func reject(_ name: String, snapshot: [String: Any]?, args: [String: Any], label: String) async throws {
                do {
                    _ = try await worker.command(name, tabID: freshID, args: snapshot.map { token($0, args) } ?? args)
                } catch { checks += 1; return }
                try check(false, label)
            }
            let seen = try await probe.command(worker, "snapshot", tabID: freshID)
            try check(seen["documentID"] as? String != nil && seen["snapshotID"] as? String != nil, "snapshot returns document and listing tokens")
            try await reject("click", snapshot: nil, args: ["index": index(seen, "Duplicate")], label: "unguarded input rejected")
            let newer = try await probe.command(worker, "snapshot", tabID: freshID)
            try check(seen["documentID"] as? String == newer["documentID"] as? String && seen["snapshotID"] as? String != newer["snapshotID"] as? String, "same document has fresh listing revision")
            try await reject("click", snapshot: seen, args: ["index": index(seen, "Duplicate")], label: "superseded listing rejected")
            _ = try await worker.command("click", tabID: freshID, args: token(newer, ["index": index(newer, "Replace target")]))
            let dead = try await worker.command("alive", tabID: freshID, args: token(newer, ["index": index(newer, "Duplicate")]))
            try check(dead["ok"] as? Bool == false, "identical DOM replacement does not resurrect old target")
            try await reject("click", snapshot: newer, args: ["index": index(newer, "Duplicate")], label: "cannot click replacement through old node")
            var afterReplacement = try await probe.command(worker, "snapshot", tabID: freshID)
            let oldDuplicate = (newer["elements"] as! [[String: Any]]).first { $0["i"] as? Int == index(newer, "Duplicate") }!
            let replacementDuplicate = (afterReplacement["elements"] as! [[String: Any]]).first { $0["i"] as? Int == index(afterReplacement, "Duplicate") }!
            try check(oldDuplicate["key"] as? String != replacementDuplicate["key"] as? String, "new identical node gets new immutable identity across listings")
            let beforeMove = try await worker.command("locate", tabID: freshID, args: token(afterReplacement, ["index": index(afterReplacement, "Duplicate")]))
            _ = try await worker.command("click", tabID: freshID, args: token(afterReplacement, ["index": index(afterReplacement, "Move target")]))
            let stillAlive = try await worker.command("alive", tabID: freshID, args: token(afterReplacement, ["index": index(afterReplacement, "Duplicate")]))
            try check(stillAlive["ok"] as? Bool == true, "same live node survives irrelevant layout change")
            try await reject("cdpClick", snapshot: afterReplacement,
                             args: ["index": index(afterReplacement, "Duplicate"), "x": beforeMove["px"]!, "y": beforeMove["py"]!], label: "old coordinate cannot click moved target")
            _ = try await worker.command("click", tabID: freshID, args: token(afterReplacement, ["index": index(afterReplacement, "Duplicate", occurrence: 1)]))
            let duplicateResult = try await worker.command("read", tabID: freshID, args: token(afterReplacement))
            try check((duplicateResult["text"] as? String ?? "").contains("second;") && !(duplicateResult["text"] as? String ?? "").contains("target;"), "duplicate labels retain exact observed node identity")
            let orderedDuplicates = (afterReplacement["elements"] as! [[String: Any]]).filter { $0["text"] as? String == "Duplicate" }
            _ = try await worker.command("click", tabID: freshID, args: token(afterReplacement, ["index": index(afterReplacement, "Reorder duplicates")]))
            afterReplacement = try await probe.command(worker, "snapshot", tabID: freshID)
            let reversedDuplicates = (afterReplacement["elements"] as! [[String: Any]]).filter { $0["text"] as? String == "Duplicate" }
            try check(orderedDuplicates[0]["key"] as? String == reversedDuplicates[1]["key"] as? String && orderedDuplicates[1]["key"] as? String == reversedDuplicates[0]["key"] as? String, "identical-label reordering preserves each actual node key")
            try check(orderedDuplicates[0]["i"] as? Int == reversedDuplicates[1]["i"] as? Int && orderedDuplicates[1]["i"] as? Int == reversedDuplicates[0]["i"] as? Int, "reordered duplicate nodes retain their exact w IDs")
            let frameElement = (afterReplacement["elements"] as! [[String: Any]]).first { ["textbox", "text"].contains($0["role"] as? String ?? "") }!["i"] as! Int
            _ = try await worker.command("click", tabID: freshID, args: token(afterReplacement, ["index": index(afterReplacement, "Reload frame")]))
            try await Task.sleep(for: .milliseconds(300))
            try await reject("fill", snapshot: afterReplacement, args: ["index": frameElement, "text": "must not type"], label: "iframe document reload rejects old field")
            try await reject("cdpType", snapshot: afterReplacement, args: ["text": "must not type"], label: "trusted typing rejects replaced embedded document")
            try await reject("cdpKey", snapshot: afterReplacement, args: ["keys": "x"], label: "trusted key rejects replaced embedded document")
            try await reject("cdpScroll", snapshot: afterReplacement, args: ["dy": 100], label: "trusted scroll rejects replaced embedded document")
            let frameReloaded = try await probe.command(worker, "snapshot", tabID: freshID)
            let freshFrameField = (frameReloaded["elements"] as! [[String: Any]]).first { ["textbox", "text"].contains($0["role"] as? String ?? "") }!["i"] as! Int
            let untouchedFrame = try await worker.command("value", tabID: freshID, args: token(frameReloaded, ["index": freshFrameField]))
            try check(untouchedFrame["value"] as? String == "", "rejected global inputs leave replacement iframe empty")
            _ = try await worker.command("navigate", tabID: freshID, args: ["url": fixtureURL])
            try await Task.sleep(for: .milliseconds(300))
            try await reject("click", snapshot: afterReplacement, args: ["index": index(afterReplacement, "Duplicate")], label: "same-URL document reload rejects input before refresh")
            let reloaded = try await probe.command(worker, "snapshot", tabID: freshID)
            try check(reloaded["documentID"] as? String != afterReplacement["documentID"] as? String, "same-URL reload changes document identity")
            try await reject("click", snapshot: afterReplacement, args: ["index": index(afterReplacement, "Duplicate")], label: "same-URL old token rejected after new listing")
            let untouched = try await worker.command("read", tabID: freshID, args: token(reloaded))
            try check(!(untouched["text"] as? String ?? "").contains("second;"), "stale commands left replacement document untouched")
            let optionsHTML = "<title>Option targets</title><div role='listbox' aria-label='Choice'><div id='alpha' role='option' onclick=\"document.querySelector('#picked').textContent='Alpha selected'\">Alpha</div><div role='option'>Duplicate option</div><div role='option'>Duplicate option</div></div><button onclick=\"const n=document.querySelector('#alpha');n.replaceWith(n.cloneNode(true))\">Replace option</button><p id='picked'></p>"
            let optionsID = try await worker.newTab("data:text/html;base64," + Data(optionsHTML.utf8).base64EncodedString())
            try await Task.sleep(for: .milliseconds(300))
            let optionSnapshot = try await probe.command(worker, "snapshot", tabID: optionsID)
            let choice = (optionSnapshot["elements"] as! [[String: Any]]).first { $0["role"] as? String == "listbox" }!["i"] as! Int
            let option = try await worker.command("findOption", tabID: optionsID, args: token(optionSnapshot, ["index": choice, "text": "Alpha"]))
            try check(option["found"] as? Bool == true && option["pointToken"] as? String != nil, "option resolution returns node-bound token")
            let ambiguous = try await worker.command("findOption", tabID: optionsID, args: token(optionSnapshot, ["index": choice, "text": "Duplicate option"]))
            try check(ambiguous["found"] as? Bool == false, "ambiguous identical option labels rejected")
            _ = try await worker.command("click", tabID: optionsID, args: token(optionSnapshot, ["index": index(optionSnapshot, "Replace option")]))
            do {
                _ = try await worker.command("clickOption", tabID: optionsID, args: token(optionSnapshot, ["pointToken": option["pointToken"]!, "pointFrame": option["pointFrame"]!]))
                try check(false, "replaced option rejected")
            } catch { checks += 1 }
            let optionNow = try await worker.command("findOption", tabID: optionsID, args: token(optionSnapshot, ["index": choice, "text": "Alpha"]))
            _ = try await worker.command("clickOption", tabID: optionsID, args: token(optionSnapshot, ["pointToken": optionNow["pointToken"]!, "pointFrame": optionNow["pointFrame"]!]))
            let optionReadback = try await worker.command("read", tabID: optionsID, args: token(optionSnapshot))
            try check((optionReadback["text"] as? String ?? "").contains("Alpha selected"), "atomic option click applies to exact current candidate")
            do {
                _ = try await worker.command("clickOption", tabID: optionsID, args: token(optionSnapshot, ["pointToken": optionNow["pointToken"]!, "pointFrame": optionNow["pointFrame"]!]))
                try check(false, "option token cannot replay an input")
            } catch { checks += 1 }
            let multiFile = "<label>First attachment<input type='file'></label><label>Second attachment<input type='file'></label>"
            let multiID = try await worker.newTab("data:text/html;base64," + Data(multiFile.utf8).base64EncodedString())
            try await Task.sleep(for: .milliseconds(300))
            let multiSnapshot = try await probe.command(worker, "snapshot", tabID: multiID)
            let fileFields = (multiSnapshot["elements"] as! [[String: Any]]).filter { $0["role"] as? String == "file" }
            let secondFile = fileFields.first { ($0["text"] as? String ?? "").contains("Second") }!["i"] as! Int
            let fileArgs: [String: Any] = ["name": "exact.txt", "type": "text/plain", "data": Data("exact input".utf8).base64EncodedString()]
            do {
                _ = try await worker.command("upload", tabID: multiID, args: token(multiSnapshot, fileArgs))
                try check(false, "ambiguous global upload rejected")
            } catch { try check(error.localizedDescription.contains("ambiguous"), "ambiguous upload error is explicit and pre-delivery") }
            _ = try await worker.command("upload", tabID: multiID, args: token(multiSnapshot, fileArgs.merging(["index": secondFile]) { _, new in new }))
            let uploadReview = try await worker.command("review", tabID: multiID, args: token(multiSnapshot))
            let uploadItems = uploadReview["items"] as! [[String: Any]]
            try check(uploadItems.first { ($0["q"] as? String ?? "").contains("First") }?["answer"] as? String == "", "unrelated file input remains empty")
            try check((uploadItems.first { ($0["q"] as? String ?? "").contains("Second") }?["answer"] as? String ?? "").contains("exact.txt"), "upload reaches exact selected file input")
        }
        func gestureChecks() async throws -> Void {
            let gesturesHTML = """
            <title>Pointer gestures</title><style>button{padding:20px;margin:10px}#drop{display:inline-block;padding:30px;border:1px solid}</style>
            <button id='hover' onmouseenter="document.querySelector('#result').textContent='Hint revealed'">Hover target</button>
            <button oncontextmenu="event.preventDefault();document.querySelector('#result').textContent='Context opened'">Context target</button>
            <button ondblclick="document.querySelector('#result').textContent='Details opened'">Double target</button>
            <button onmousedown="window.dragging=true">Drag source</button><div id='drop' role='button' aria-label='Drop target'
            onmouseup="if(window.dragging)document.querySelector('#result').textContent='Card dropped';window.dragging=false">Drop target</div><p id='result'></p>
            """
            let gestureID = try await worker.newTab("data:text/html;base64," + Data(gesturesHTML.utf8).base64EncodedString())
            try await Task.sleep(for: .milliseconds(300))
            for (kind, label, expected) in [("hover", "Hover target", "Hint revealed"), ("right_click", "Context target", "Context opened"),
                                             ("double_click", "Double target", "Details opened"), ("drag", "Drag source", "Card dropped")] {
                let observed = try await probe.command(worker, "snapshot", tabID: gestureID)
                let items = observed["elements"] as! [[String: Any]]
                let source = items.first { $0["text"] as? String == label }!["i"] as! Int
                var args: [String: Any] = ["gesture": kind, "index": source]
                if kind == "drag" { args["toIndex"] = items.first { $0["text"] as? String == "Drop target" }!["i"] as! Int }
                let delivered = try await probe.command(worker, "cdpGesture", tabID: gestureID, args: args)
                try check(delivered["verified"] as? Bool == false, "driver delivery never claims goal verification")
                let result = try await probe.command(worker, "read", tabID: gestureID)
                try check((result["text"] as? String ?? "").contains(expected), "real Chromium " + kind + " produces intended page result")
            }
            let staleGesture = try await probe.command(worker, "snapshot", tabID: gestureID)
            _ = try await probe.command(worker, "snapshot", tabID: gestureID)
            do {
                _ = try await worker.command("cdpGesture", tabID: gestureID, args: token(staleGesture, ["gesture": "hover", "index": 0]))
                try check(false, "stale gesture refused")
            } catch { checks += 1 }
            _ = try await probe.command(worker, "closeTab", tabID: gestureID)
        }
        func statusBoundaryChecks() async throws {
            let html = """
            <title>Semantic status boundaries</title><main><button id="review" onclick="document.querySelector('#status').textContent='Local review confirmed'">Open Review window</button><span id="status" role="status"></span>
            <button>Payment</button><span role="status">unpaid</span></main>
            <div role="alert">Independent alert visible</div><div aria-live="polite">Independent live message</div>
            <div role="status" hidden>Hidden confirmation</div><div aria-hidden="true"><span role="status">ARIA hidden confirmation</span></div>
            <div style="opacity:0"><span role="status">Transparent confirmation</span></div>
            <div data-clinqy-overlay><span role="status">Agent overlay confirmation</span></div>
            """
            let tab = try await worker.newTab("data:text/html;base64," + Data(html.utf8).base64EncodedString())
            let observed = try await probe.command(worker, "snapshot", tabID: tab)
            let before = try await probe.command(worker, "read", tabID: tab)["text"] as? String ?? ""
            try check(!VerificationEvidence.appears("Local review confirmed", in: before), "absent confirmation is not invented by semantic extraction")
            let button = (observed["elements"] as! [[String: Any]]).first { $0["text"] as? String == "Open Review window" }!["i"] as! Int
            _ = try await probe.command(worker, "click", tabID: tab, args: ["index": button])
            let after = try await probe.command(worker, "read", tabID: tab)["text"] as? String ?? ""
            try check(VerificationEvidence.newText("Local review confirmed", before: before, after: after), "adjacent inline status has independent word boundaries: " + after)
            try check(VerificationEvidence.appears("Independent alert visible", in: after), "visible alert outside main remains readable")
            try check(VerificationEvidence.appears("Independent live message", in: after), "visible live region outside main remains readable")
            try check(!VerificationEvidence.appears("Paid", in: after), "unpaid never verifies paid after semantic extraction")
            for hidden in ["Hidden confirmation", "ARIA hidden confirmation", "Transparent confirmation", "Agent overlay confirmation"] {
                try check(!VerificationEvidence.appears(hidden, in: after), "hidden or agent-owned semantic region excluded: " + hidden)
            }
            _ = try await probe.command(worker, "closeTab", tabID: tab)
        }
        func autocompleteChecks() async throws {
            let html = """
            <title>Autocomplete fixture</title><label>Reviewer<input id="reviewer" role="combobox" aria-autocomplete="list" aria-controls="suggestions" aria-expanded="false"></label>
            <div id="suggestions" role="listbox" aria-label="Reviewer suggestions" hidden></div><p id="selected">No reviewer selected</p>
            <div role="listbox" aria-label="Persistent list"><button role="option">Always available</button></div>
            <div role="listbox" aria-expanded="false"><button role="option">Closed choice</button></div>
            <script>
            const field=document.querySelector('#reviewer'),box=document.querySelector('#suggestions');
            field.oninput=()=>{box.replaceChildren();for(const name of ['Priya Shah','Priya Sharma','Rahul Mehta'].filter(n=>n.toLowerCase().includes(field.value.toLowerCase()))){
              const button=document.createElement('button');button.role='option';button.textContent=name;
              button.onclick=()=>{field.value=name;box.hidden=true;field.setAttribute('aria-expanded','false');document.querySelector('#selected').textContent='Selected reviewer: '+name;};box.append(button);
            }box.hidden=!box.children.length;field.setAttribute('aria-expanded',String(!box.hidden));};
            </script>
            """
            let tab = try await worker.newTab("data:text/html;base64," + Data(html.utf8).base64EncodedString())
            let initial = try await probe.command(worker, "snapshot", tabID: tab)
            let controls = initial["elements"] as! [[String: Any]]
            let field = controls.first { $0["role"] as? String == "combobox" }!["i"] as! Int
            _ = try await probe.command(worker, "fill", tabID: tab, args: ["index": field, "text": "Priya"])
            let expanded = try await probe.command(worker, "snapshot", tabID: tab)
            let choices = expanded["elements"] as! [[String: Any]]
            let suggestions = choices.filter { $0["role"] as? String == "option" && ($0["text"] as? String ?? "").hasPrefix("Priya") }
            try check(suggestions.count == 2, "visible autocomplete options are addressable without aria-expanded on listbox: " + String(describing: choices))
            try check(choices.contains { $0["text"] as? String == "Always available" }, "persistent visible listbox options require no expanded attribute")
            try check(!choices.contains { $0["text"] as? String == "Closed choice" }, "explicitly collapsed listbox options are not actionable")
            let chosen = suggestions.first { $0["text"] as? String == "Priya Shah" }!["i"] as! Int
            _ = try await probe.command(worker, "click", tabID: tab, args: ["index": chosen])
            let result = try await probe.command(worker, "read", tabID: tab)
            try check((result["text"] as? String ?? "").contains("Selected reviewer: Priya Shah"), "semantic option click chooses exact autocomplete result")
            let closed = try await probe.command(worker, "snapshot", tabID: tab)
            try check(!(closed["elements"] as! [[String: Any]]).contains { $0["role"] as? String == "option" && ($0["text"] as? String ?? "").hasPrefix("Priya") }, "hidden suggestions disappear after selection")
            _ = try await probe.command(worker, "closeTab", tabID: tab)
        }
        func overlayChecks() async throws {
            let activity = try String(contentsOfFile: "extension/activity.js", encoding: .utf8)
            let html = """
            <title>Clinqy overlay fixture</title><style>body{font:18px system-ui;margin:48px;background:#fafbfc;color:#17283b}h1{font-size:36px}button{font:inherit;padding:14px 22px;border:1px solid #ccd5df;border-radius:8px;background:white}#target{position:absolute;right:40px;top:35px}main{margin-top:100px;max-width:720px}input{font:inherit;padding:12px;border:1px solid #ccd5df;border-radius:8px}</style>
            <button id="target">Target control</button><main><h1>Clinqy browser activity</h1><p>The cursor follows this task's target while your physical pointer stays free.</p><label>Example field <input placeholder="Local fixture only"></label><p id="checks">Waiting for layout</p><button onclick="window.checkOverlay()">Check overlay layout</button></main>
            <script>
            const attach=Element.prototype.attachShadow;let overlayRoot;
            Element.prototype.attachShadow=function(options){const root=attach.call(this,options);if(this.hasAttribute('data-clinqy-overlay'))overlayRoot=root;return root;};
            \(activity)
            const target=document.querySelector('#target'),r=target.getBoundingClientRect(),x=r.left+r.width/2,y=r.top+r.height/2;
            window.__clinqy={documentID:'fixture',activityPoint:()=>{const b=target.getBoundingClientRect();return {x:b.left+b.width/2,y:b.top+b.height/2}}};
            window.__clinqyActivity.update({kind:'click',stage:'prepare',x,y,localIndex:1,documentID:'fixture'});
            window.checkOverlay=()=>{
              window.__clinqyActivity.update({kind:'click',stage:'prepare',localIndex:1,documentID:'fixture'});
              const edge=overlayRoot.querySelector('.edge').getBoundingClientRect(),badge=overlayRoot.querySelector('.badge').getBoundingClientRect();
              const cursor=overlayRoot.querySelector('.cursor').getBoundingClientRect();
              const bounds=edge.left===0&&edge.top===0&&edge.width===innerWidth&&edge.height===innerHeight;
              const current=target.getBoundingClientRect();
              const position=Math.abs(cursor.x-current.left-current.width/2)<1&&Math.abs(cursor.y-current.top-current.height/2)<1;
              const unobscured=badge.right<=r.left||badge.left>=r.right||badge.bottom<=r.top||badge.top>=r.bottom;
              const clicks=document.elementFromPoint(x,y)===target;
              document.querySelector('#checks').textContent=bounds&&position&&unobscured&&clicks&&document.title==='Clinqy overlay fixture'?'Overlay geometry verified':'Overlay geometry FAILED '+JSON.stringify({bounds,position,unobscured,clicks});
            };
            </script>
            """
            let tab = try await worker.newTab("data:text/html;base64," + Data(html.utf8).base64EncodedString())
            let observation = try await probe.command(worker, "snapshot", tabID: tab)
            let layoutButton = (observation["elements"] as! [[String: Any]]).first { $0["text"] as? String == "Check overlay layout" }!["i"] as! Int
            _ = try await probe.command(worker, "click", tabID: tab, args: ["index": layoutButton])
            let ready = try await probe.command(worker, "waitText", tabID: tab, args: ["text": "Overlay geometry verified", "ms": 3000])
            let overlayRead = try await probe.command(worker, "read", tabID: tab)
            let capture = try await probe.command(worker, "captureTask", tabID: tab)
            guard let encoded = capture["image"] as? String, let png = Data(base64Encoded: encoded) else { throw WorkerCDP.error("Missing overlay screenshot") }
            let artifact = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CLINQY_TEST_OVERLAY"] ?? "/tmp/clinqy-overlay-chrome.png")
            try png.write(to: artifact)
            print("Chrome overlay screenshot: " + artifact.path); fflush(stdout)
            try check(ready["met"] as? Bool == true, "real Chrome overlay: " + String(describing: overlayRead["text"] ?? "no page text"))
            _ = try await probe.command(worker, "closeTab", tabID: tab)
        }
        func rangeAndWaitChecks() async throws {
            let html = """
            <title>Range and waits</title><label>Even amount<input id="amount" type="range" min="0" max="10" step="2" value="2"
            oninput="window.inputCount=(window.inputCount||0)+1;document.querySelector('#events').textContent='Input events '+window.inputCount"></label>
            <label>Locked amount<input id="locked" type="range" min="0" max="10" step="any" value="1" disabled></label>
            <button onclick="setTimeout(()=>{document.querySelector('#locked').disabled=false;document.querySelector('#ready').textContent='Delayed fixture ready'},200)">Enable later</button>
            <button onclick="document.querySelector('#amount').hidden=true">Hide range</button>
            <p id="events">Input events 0</p><p id="ready"></p>
            """
            let tab = try await worker.newTab("data:text/html;base64," + Data(html.utf8).base64EncodedString())
            let observed = try await probe.command(worker, "snapshot", tabID: tab)
            let items = observed["elements"] as! [[String: Any]]
            func index(_ label: String) throws -> Int {
                guard let value = items.first(where: { ($0["text"] as? String ?? "").contains(label) })?["i"] as? Int else {
                    throw WorkerCDP.error("Missing range fixture control: " + label)
                }
                return value
            }
            let amount = try index("Even amount"), locked = try index("Locked amount")
            let metadata = items.first { $0["i"] as? Int == amount }?["range"] as? String ?? ""
            try check(metadata.contains("min=0") && metadata.contains("max=10") && metadata.contains("step=2"), "range observations expose numeric constraints")
            for desired in [-1, 3, 12] {
                let denied = try await probe.command(worker, "setRange", tabID: tab, args: ["index": amount, "state": desired])
                try check(denied["refused"] as? Bool == true, "range refuses bounds or step violation before dispatch")
            }
            let disabled = try await probe.command(worker, "setRange", tabID: tab, args: ["index": locked, "state": 2])
            try check(disabled["refused"] as? Bool == true, "disabled range refuses dispatch")
            let changed = try await probe.command(worker, "setRange", tabID: tab, args: ["index": amount, "state": 6])
            try check(changed["delivered"] as? Bool == true && changed["value"] as? String == "6", "range setter delivers exact valid value")
            let unchanged = try await probe.command(worker, "setRange", tabID: tab, args: ["index": amount, "state": 6])
            try check(unchanged["already"] as? Bool == true, "unchanged range sends no repeated input")
            let value = try await probe.command(worker, "value", tabID: tab, args: ["index": amount])
            try check(value["value"] as? String == "6", "independent range value readback")
            let read = try await probe.command(worker, "read", tabID: tab)
            try check((read["text"] as? String ?? "").contains("Input events 1"), "invalid and duplicate ranges produce no input events")
            let ready = try await probe.command(worker, "waitCondition", tabID: tab, args: ["condition": ["kind": "ready"], "ms": 1500])
            try check(ready["met"] as? Bool == true, "ready condition observes browser readiness")
            _ = try await probe.command(worker, "click", tabID: tab, args: ["index": try index("Enable later")])
            let enabled = try await probe.command(worker, "waitCondition", tabID: tab, args: ["condition": ["kind": "element", "index": locked, "state": "enabled"], "ms": 3000])
            try check(enabled["met"] as? Bool == true, "element wait observes delayed enabled state")
            let decimal = try await probe.command(worker, "setRange", tabID: tab, args: ["index": locked, "state": 2.375])
            try check(decimal["value"] as? String == "2.375", "step-any range preserves decimal values")
            let absent = try await probe.command(worker, "waitCondition", tabID: tab, args: ["condition": ["kind": "text", "text": "Never present"], "ms": 200])
            try check(absent["met"] as? Bool == false && absent["cancelled"] as? Bool == false, "unmet condition times out without claiming success")
            _ = try await probe.command(worker, "click", tabID: tab, args: ["index": try index("Hide range")])
            let gone = try await probe.command(worker, "waitCondition", tabID: tab, args: ["condition": ["kind": "element", "index": amount, "state": "gone"], "ms": 1500])
            try check(gone["met"] as? Bool == true, "gone waits for stable hidden state")
            _ = try await probe.command(worker, "closeTab", tabID: tab)
        }
        func lifecycleChecks(id: Int) async throws -> Void {
            let disposable = try await worker.newTab(page("Disposable"))
            let completedRun = worker.generation
            await worker.runEnded(keep: id, generation: completedRun)
            do { _ = try await probe.command(worker, "tabInfo", tabID: disposable); preconditionFailure("kept unused task tab") } catch { checks += 1 }
            let finalPhoto = try await probe.command(worker, "captureTask", tabID: id)
            try check((finalPhoto["image"] as? String)?.isEmpty == false, "captures retained tab after idle freeze")
            worker.runStarted()
            await worker.runEnded(keep: nil, generation: completedRun)
            let retained = try await probe.command(worker, "tabInfo", tabID: id)
            try check(retained["title"] as? String == "Worker", "stale cleanup leaves the next run's tab alone")
            let endingGeneration = worker.generation
            let ending = Task { await worker.runEnded(keep: id, generation: endingGeneration) }
            try await Task.sleep(for: .milliseconds(5))
            worker.runStarted()
            _ = try await probe.command(worker, "snapshot", tabID: id)
            await ending.value
            let stillOwned = try await probe.command(worker, "tabInfo", tabID: id)
            try check(stillOwned["title"] as? String == "Worker", "new run survives an overlapping final-frame capture")
        }
        func crossFrameChecks() async throws -> Void {
            // Cross-origin iframe (a separate process: 127.0.0.1 and localhost are different sites), plain, scaled and rotated.
            let site = root.appendingPathComponent("site")
            try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
            let outerPort = Int.random(in: 41000..<44000), innerPort = Int.random(in: 44000..<47000)
            let inner = "<title>Inner</title><p>Inner text proof</p><button onclick=\"document.querySelector('#r').textContent='clicked'\">Lab inside</button><label>Editor<input></label><p id='r'></p>"
            try inner.write(to: site.appendingPathComponent("inner.html"), atomically: true, encoding: .utf8)
            for (name, style) in [("plain", ""), ("scaled", "transform:scale(0.5);transform-origin:0 0;"), ("rotated", "transform:rotate(8deg);")] {
                let outer = "<title>Outer \(name)</title><button>Outer button</button><iframe style='\(style)margin:30px' src='http://localhost:\(innerPort)/inner.html' width='600' height='300'></iframe>"
                try outer.write(to: site.appendingPathComponent("\(name).html"), atomically: true, encoding: .utf8)
            }
            var servers: [Process] = []
            defer { servers.forEach { $0.terminate() } }
            for (host, port) in [("127.0.0.1", outerPort), ("localhost", innerPort)] {
                let server = Process()
                server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                server.arguments = ["python3", "-m", "http.server", String(port), "--bind", host == "localhost" ? "127.0.0.1" : host, "--directory", site.path]
                server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
                try server.run(); servers.append(server)
            }
            try await Task.sleep(for: .seconds(1))
            func frameElements(_ name: String) async throws -> (tab: Int, snapshot: [String: Any]) {
                let tab = try await worker.newTab("http://127.0.0.1:\(outerPort)/\(name).html")
                for _ in 0..<30 { // the iframe's process attaches a moment after the page loads
                    try await Task.sleep(for: .milliseconds(300))
                    let snapshot = try await probe.command(worker, "snapshot", tabID: tab)
                    let found = (snapshot["elements"] as? [[String: Any]] ?? []).contains { ($0["text"] as? String)?.contains("Lab inside") == true }
                    if found || name == "rotated" { return (tab, snapshot) }
                }
                return (tab, try await probe.command(worker, "snapshot", tabID: tab))
            }
            for name in ["plain", "scaled"] {
                let (crossTab, crossSnapshot) = try await frameElements(name)
                let crossElements = crossSnapshot["elements"] as? [[String: Any]] ?? []
                guard let button = crossElements.first(where: { ($0["text"] as? String)?.contains("Lab inside") == true }),
                      let buttonIndex = button["i"] as? Int else { throw WorkerCDP.error("cross-origin iframe (\(name)) elements are missing from the snapshot: \(crossSnapshot["frameCoverage"] ?? [])") }
                try check((crossSnapshot["frameCoverage"] as? [Any])?.isEmpty == true, "\(name): readable cross-origin frame reports no coverage gap")
                let located = try await probe.command(worker, "locate", tabID: crossTab, args: ["index": buttonIndex, "reveal": false])
                guard let px = (located["px"] as? NSNumber)?.doubleValue, let py = (located["py"] as? NSNumber)?.doubleValue else { throw WorkerCDP.error("\(name): locate returned no point") }
                _ = try await probe.command(worker, "cdpClick", tabID: crossTab, args: ["index": buttonIndex, "x": px, "y": py])
                try await Task.sleep(for: .milliseconds(200))
                let readBack = try await probe.command(worker, "read", tabID: crossTab)
                try check((readBack["text"] as? String)?.contains("Inner text proof") == true, "\(name): read includes cross-origin frame text")
                try check((readBack["text"] as? String)?.contains("clicked") == true, "\(name): trusted click lands in the cross-origin frame at the composed coordinates")
                if let field = crossElements.first(where: { ["textbox", "text"].contains($0["role"] as? String ?? "") && ($0["i"] as? Int) != nil })?["i"] as? Int {
                    _ = try await probe.command(worker, "fill", tabID: crossTab, args: ["index": field, "text": "cross-origin value"])
                    let value = try await probe.command(worker, "value", tabID: crossTab, args: ["index": field])
                    try check(value["value"] as? String == "cross-origin value", "\(name): fill reaches the cross-origin frame")
                }
                _ = try await probe.command(worker, "closeTab", tabID: crossTab)
            }
            let (rotatedTab, rotatedSnapshot) = try await frameElements("rotated")
            let gaps = rotatedSnapshot["frameCoverage"] as? [[String: Any]] ?? []
            try check(gaps.contains { ($0["reason"] as? String)?.contains("rotated") == true }, "rotated frame is reported as unreadable, not silently dropped or mis-placed")
            try check(!(rotatedSnapshot["elements"] as? [[String: Any]] ?? []).contains { ($0["text"] as? String)?.contains("Lab inside") == true }, "rotated frame elements are not placed with translation-only math")
            _ = try await probe.command(worker, "closeTab", tabID: rotatedTab)
        }
        do {
            print("Chrome checks: setup"); fflush(stdout)
            let (id, otherID) = try await setup()
            if ProcessInfo.processInfo.environment["CLINQY_CHROME_CHECKS"] == "status-boundaries" {
                try await statusBoundaryChecks()
                await worker.stop(); await recovered.stop(); await other.stop()
                try? FileManager.default.removeItem(at: root)
                print("PASS: \(checks) targeted Chrome semantic status boundary checks")
                return
            }
            if ProcessInfo.processInfo.environment["CLINQY_CHROME_CHECKS"] == "autocomplete" {
                try await autocompleteChecks()
                await worker.stop(); await recovered.stop(); await other.stop()
                try? FileManager.default.removeItem(at: root)
                print("PASS: \(checks) targeted Chrome autocomplete checks")
                return
            }
            if ProcessInfo.processInfo.environment["CLINQY_CHROME_CHECKS"] == "new-controls" {
                try await overlayChecks()
                try await rangeAndWaitChecks()
                await worker.stop(); await recovered.stop(); await other.stop()
                try? FileManager.default.removeItem(at: root)
                print("PASS: \(checks) targeted Chrome overlay/range/wait checks")
                return
            }
            print("Chrome checks: inputs"); fflush(stdout)
            let name = try await inputChecks(id: id)
            print("Chrome checks: navigation"); fflush(stdout)
            try await navigationChecks(id: id, otherID: otherID)
            print("Chrome checks: embedded controls"); fflush(stdout)
            try await embeddedChecks()
            print("Chrome checks: freshness"); fflush(stdout)
            try await freshnessChecks()
            print("Chrome checks: gestures"); fflush(stdout)
            try await gestureChecks()
            print("Chrome checks: semantic status boundaries"); fflush(stdout)
            try await statusBoundaryChecks()
            print("Chrome checks: autocomplete"); fflush(stdout)
            try await autocompleteChecks()
            print("Chrome checks: overlay"); fflush(stdout)
            try await overlayChecks()
            print("Chrome checks: ranges and waits"); fflush(stdout)
            try await rangeAndWaitChecks()
            print("Chrome checks: lifecycle"); fflush(stdout)
            try await lifecycleChecks(id: id)
            print("Chrome checks: cross-origin frames"); fflush(stdout)
            try await crossFrameChecks()
            let recoveredID = try await recovered.newTab(page("Recovered worker"))
            try rememberPID("worker")
            let recoveredInfo = try await probe.command(recovered, "tabInfo", tabID: recoveredID)
            try check(recoveredInfo["title"] as? String == "Recovered worker", "reclaims orphaned owned process without replaying its old target")
            await worker.stop()
            do { _ = try await probe.command(worker, "fill", tabID: id, args:["index": name!, "text":"must fail"]); preconditionFailure("fell through after disconnect") } catch { checks += 1 }
            try check(NSPasteboard.general.changeCount == clipboard, "host clipboard unchanged")
            try check(!activations.pids.contains(where: { ownedPIDs.contains($0) }), "owned worker never activates foreground (user app switches allowed)")
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
