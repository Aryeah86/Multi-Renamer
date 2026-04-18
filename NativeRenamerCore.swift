import Foundation

enum RenamerError: LocalizedError {
    case wavFolderMissing(String)
    case wavFolderNotDirectory(String)
    case noMatchingFiles(String)
    case snapMissing(String)
    case snapNotFile(String)
    case invalidJSON(String)
    case invalidSnapRoot(String)
    case invalidSlot(Int)
    case outputFolderExists(String)
    case renameConflict(String)

    var errorDescription: String? {
        switch self {
        case .wavFolderMissing(let path):
            return "WAV folder does not exist: \(path)"
        case .wavFolderNotDirectory(let path):
            return "WAV path is not a folder: \(path)"
        case .noMatchingFiles(let path):
            return "No matching files found in \(path). Expected Channel-N.WAV files."
        case .snapMissing(let path):
            return "Snap file not found: \(path)"
        case .snapNotFile(let path):
            return "Snap path is not a file: \(path)"
        case .invalidJSON(let detail):
            return "Snap is not valid JSON: \(detail)"
        case .invalidSnapRoot(let detail):
            return detail
        case .invalidSlot(let slot):
            return "Absolute slot out of range: \(slot)"
        case .outputFolderExists(let path):
            return "Output folder already exists: \(path)"
        case .renameConflict(let detail):
            return detail
        }
    }
}

struct WavEntry: Identifiable {
    let id = UUID()
    let url: URL
    let originalName: String
    let localIndex: Int
}

struct ResolvedName {
    let name: String
    let status: String
    let note: String
}

struct RouteResolution {
    let name: String
    let sourceRef: String
    let descriptor: String
    let appendDescriptorSuffix: Bool
}

struct PlanRow: Identifiable {
    let id = UUID()
    let sourceURL: URL
    let originalName: String
    let localIndex: Int
    let card: String
    let absoluteSlot: Int
    let resolvedName: String
    let finalName: String
    let status: String
    let note: String
    let targetURL: URL
}

enum CardSelection: String, CaseIterable, Identifiable {
    case a = "A"
    case b = "B"

    var id: String { rawValue }
}

enum OperationMode: String, CaseIterable, Identifiable {
    case rename = "Rename In Place"
    case copy = "Copy To New Folder"

    var id: String { rawValue }
}

enum NativeRenamer {
    static let defaultUnnamed = "UNNAMED"
    private static let invalidFileNameScalars = CharacterSet(charactersIn: "\\/:*?\"<>|")

    static func scanWavs(in folderURL: URL) throws -> [WavEntry] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDirectory) else {
            throw RenamerError.wavFolderMissing(folderURL.path)
        }
        guard isDirectory.boolValue else {
            throw RenamerError.wavFolderNotDirectory(folderURL.path)
        }

        let entries = try FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        let regex = try NSRegularExpression(pattern: #"^Channel-(\d+)\.wav$"#, options: [.caseInsensitive])
        let wavs = entries.compactMap { url -> WavEntry? in
            let name = url.lastPathComponent
            let range = NSRange(location: 0, length: name.utf16.count)
            guard let match = regex.firstMatch(in: name, options: [], range: range) else {
                return nil
            }
            guard let groupRange = Range(match.range(at: 1), in: name),
                  let index = Int(name[groupRange]) else {
                return nil
            }
            return WavEntry(url: url, originalName: name, localIndex: index)
        }.sorted { $0.localIndex < $1.localIndex }

        guard !wavs.isEmpty else {
            throw RenamerError.noMatchingFiles(folderURL.path)
        }
        return wavs
    }

    static func loadSnap(from url: URL) throws -> [String: Any] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw RenamerError.snapMissing(url.path)
        }
        guard !isDirectory.boolValue else {
            throw RenamerError.snapNotFile(url.path)
        }

        let data = try Data(contentsOf: url)
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw RenamerError.invalidJSON(error.localizedDescription)
        }

        guard let payload = json as? [String: Any] else {
            throw RenamerError.invalidSnapRoot("Snap root is not a JSON object.")
        }

        if let aeData = payload["ae_data"] as? [String: Any], isProbableDataRoot(aeData) {
            return aeData
        }
        if isProbableDataRoot(payload) {
            return payload
        }
        for value in payload.values {
            if let dict = value as? [String: Any], isProbableDataRoot(dict) {
                return dict
            }
        }

        let keys = payload.keys.sorted().joined(separator: ", ")
        throw RenamerError.invalidSnapRoot(
            "Could not find snap data root (expected ae_data or direct data object). Top-level keys: \(keys)"
        )
    }

    static func buildPlan(
        wavEntries: [WavEntry],
        snapRoot: [String: Any],
        card: CardSelection,
        destinationURL: URL
    ) throws -> [PlanRow] {
        var rows: [PlanRow] = []
        var usedTargets = Set<String>()

        for entry in wavEntries {
            let absoluteSlot = try toAbsoluteSlot(localIndex: entry.localIndex, card: card)
            let resolved = resolveSourceName(absoluteSlot: absoluteSlot, snapRoot: snapRoot)
            let preferredName = buildFinalFileName(slot: absoluteSlot, resolvedName: resolved.name)
            let collisionResolvedName = resolveCollisionName(
                preferredName: preferredName,
                destinationURL: destinationURL,
                sourceURL: entry.url,
                usedTargets: &usedTargets
            )

            rows.append(
                PlanRow(
                    sourceURL: entry.url,
                    originalName: entry.originalName,
                    localIndex: entry.localIndex,
                    card: card.rawValue,
                    absoluteSlot: absoluteSlot,
                    resolvedName: resolved.name.isEmpty ? defaultUnnamed : resolved.name,
                    finalName: collisionResolvedName,
                    status: resolved.status,
                    note: resolved.note,
                    targetURL: destinationURL.appendingPathComponent(collisionResolvedName)
                )
            )
        }

        return rows
    }

    static func copyPlan(
        rows: [PlanRow],
        progress: @escaping @Sendable (_ copied: Int, _ total: Int, _ lastName: String) -> Void
    ) throws {
        for (index, row) in rows.enumerated() {
            try FileManager.default.copyItem(at: row.sourceURL, to: row.targetURL)
            progress(index + 1, rows.count, row.finalName)
        }
    }

    static func renamePlan(
        rows: [PlanRow],
        progress: @escaping @Sendable (_ completed: Int, _ total: Int, _ lastName: String) -> Void
    ) throws {
        let fileManager = FileManager.default
        var staged: [(tempURL: URL, originalURL: URL, targetURL: URL)] = []

        for row in rows {
            if row.sourceURL.standardizedFileURL == row.targetURL.standardizedFileURL {
                continue
            }

            let tempURL = row.sourceURL.deletingLastPathComponent()
                .appendingPathComponent(".__wing_tmp__\(UUID().uuidString).tmp")
            try fileManager.moveItem(at: row.sourceURL, to: tempURL)
            staged.append((tempURL: tempURL, originalURL: row.sourceURL, targetURL: row.targetURL))
        }

        do {
            for (index, item) in staged.enumerated() {
                try fileManager.moveItem(at: item.tempURL, to: item.targetURL)
                progress(index + 1, staged.count, item.targetURL.lastPathComponent)
            }
        } catch {
            for item in staged where fileManager.fileExists(atPath: item.tempURL.path) {
                if !fileManager.fileExists(atPath: item.originalURL.path) {
                    try? fileManager.moveItem(at: item.tempURL, to: item.originalURL)
                }
            }
            throw error
        }
    }

    static func makeTimestampedOutputFolder(baseFolder: URL, card: CardSelection) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let stamp = formatter.string(from: Date())
        let url = baseFolder.appendingPathComponent("copy_card_\(card.rawValue.lowercased())_\(stamp)", isDirectory: true)
        if FileManager.default.fileExists(atPath: url.path) {
            throw RenamerError.outputFolderExists(url.path)
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    static func makeRenameDestination(baseFolder: URL) -> URL {
        baseFolder
    }

    private static func isProbableDataRoot(_ object: [String: Any]) -> Bool {
        object["io"] is [String: Any] && object["ch"] is [String: Any]
    }

    private static func toAbsoluteSlot(localIndex: Int, card: CardSelection) throws -> Int {
        let slot = card == .a ? localIndex : localIndex + 32
        guard (1...64).contains(slot) else {
            throw RenamerError.invalidSlot(slot)
        }
        return slot
    }

    private static func resolveSourceName(absoluteSlot: Int, snapRoot: [String: Any]) -> ResolvedName {
        guard let route = nestedDict(snapRoot, ["io", "out", "CRD", "\(absoluteSlot)"]) else {
            return ResolvedName(name: "", status: "UNRESOLVED", note: "missing CRD route")
        }

        let group = (route["grp"] as? String ?? "").uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceIndex = route["in"] as? Int ?? Int("\(route["in"] ?? "")")

        guard let sourceIndex else {
            return ResolvedName(name: "", status: "UNRESOLVED", note: "slot \(absoluteSlot) has invalid route index")
        }

        if group.isEmpty || group == "OFF" {
            return ResolvedName(name: "", status: "UNRESOLVED", note: "slot \(absoluteSlot) route is OFF")
        }

        let routeResolution = resolveRouteGroupName(group: group, sourceIndex: sourceIndex, snapRoot: snapRoot)
        if !routeResolution.name.isEmpty {
            var finalName = routeResolution.name
            if routeResolution.appendDescriptorSuffix {
                finalName = sanitizeName("\(finalName) - \(routeResolution.descriptor)")
            }
            return ResolvedName(name: finalName, status: "OK", note: "from \(routeResolution.sourceRef)")
        }

        if !routeResolution.descriptor.isEmpty {
            let fallback = sanitizeName(routeResolution.descriptor)
            if !fallback.isEmpty {
                return ResolvedName(name: fallback, status: "OK", note: "\(routeResolution.sourceRef) name missing; used route descriptor")
            }
        }

        return ResolvedName(name: "", status: "UNRESOLVED", note: "\(routeResolution.sourceRef) label missing or unsupported")
    }

    private static func resolveRouteGroupName(group: String, sourceIndex: Int, snapRoot: [String: Any]) -> RouteResolution {
        if let ioIn = nestedDict(snapRoot, ["io", "in"]), let groupContainer = ioIn[group] as? [String: Any] {
            let name = nameFromGroupContainer(groupContainer, index: sourceIndex)
            return RouteResolution(
                name: name,
                sourceRef: "\(group).\(sourceIndex)",
                descriptor: "\(group) \(sourceIndex)",
                appendDescriptorSuffix: false
            )
        }

        let rootKeyMap = [
            "MAIN": "main",
            "MTX": "mtx",
            "BUS": "bus",
            "DCA": "dca",
            "FX": "fx",
            "CH": "ch",
            "AUX": "aux",
            "PLAY": "play",
        ]

        guard let rootKey = rootKeyMap[group], let container = snapRoot[rootKey] as? [String: Any] else {
            return RouteResolution(
                name: "",
                sourceRef: "\(group).\(sourceIndex)",
                descriptor: "\(group) \(sourceIndex)",
                appendDescriptorSuffix: false
            )
        }

        let lane = laneToLogicalIndex(container: container, laneIndex: sourceIndex)
        guard let logicalIndex = lane.logicalIndex else {
            return RouteResolution(
                name: "",
                sourceRef: "\(group).\(sourceIndex)",
                descriptor: "\(group) \(sourceIndex)",
                appendDescriptorSuffix: true
            )
        }

        let name = nameFromGroupContainer(container, index: logicalIndex)
        let descriptor = lane.side.isEmpty ? "\(group) \(logicalIndex)" : "\(group) \(logicalIndex) \(lane.side)"
        let sourceRef = logicalIndex == sourceIndex ? "\(group).\(sourceIndex)" : "\(group).\(sourceIndex)->\(rootKey).\(logicalIndex)"
        return RouteResolution(
            name: name,
            sourceRef: sourceRef,
            descriptor: sanitizeName(descriptor),
            appendDescriptorSuffix: true
        )
    }

    private static func nameFromGroupContainer(_ container: [String: Any], index: Int) -> String {
        guard let node = container["\(index)"] as? [String: Any] else {
            return ""
        }
        return sanitizeName(node["name"] as? String ?? "")
    }

    private static func sanitizeName(_ raw: String) -> String {
        let replaced = raw.unicodeScalars.map { scalar -> Character in
            invalidFileNameScalars.contains(scalar) ? " " : Character(scalar)
        }
        let collapsed = String(replaced).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func buildFinalFileName(slot: Int, resolvedName: String) -> String {
        let base = sanitizeName(resolvedName).isEmpty ? defaultUnnamed : sanitizeName(resolvedName)
        return String(format: "%02d %@.WAV", slot, base)
    }

    private static func resolveCollisionName(
        preferredName: String,
        destinationURL: URL,
        sourceURL: URL,
        usedTargets: inout Set<String>
    ) -> String {
        let fileManager = FileManager.default
        let nsPreferred = preferredName as NSString
        let stem = nsPreferred.deletingPathExtension
        let suffix = "." + nsPreferred.pathExtension

        var candidate = preferredName
        var counter = 1
        while true {
            let targetURL = destinationURL.appendingPathComponent(candidate)
            let key = targetURL.path.lowercased()
            let sameAsSource = targetURL.standardizedFileURL == sourceURL.standardizedFileURL
            let conflictInBatch = usedTargets.contains(key)
            let conflictOnDisk = fileManager.fileExists(atPath: targetURL.path) && !sameAsSource
            if !conflictInBatch && !conflictOnDisk {
                usedTargets.insert(key)
                return candidate
            }
            counter += 1
            candidate = "\(stem) (\(counter))\(suffix)"
        }
    }

    private static func nestedDict(_ root: [String: Any], _ keys: [String]) -> [String: Any]? {
        var current: Any = root
        for key in keys {
            guard let dict = current as? [String: Any], let next = dict[key] else {
                return nil
            }
            current = next
        }
        return current as? [String: Any]
    }

    private struct LaneResolution {
        let logicalIndex: Int?
        let side: String
    }

    private static func laneToLogicalIndex(container: [String: Any], laneIndex: Int) -> LaneResolution {
        guard laneIndex > 0 else {
            return LaneResolution(logicalIndex: nil, side: "")
        }

        let numericNodes = container.compactMap { key, value -> (Int, [String: Any])? in
            guard let idx = Int(key), let dict = value as? [String: Any] else {
                return nil
            }
            return (idx, dict)
        }.sorted { $0.0 < $1.0 }

        guard !numericNodes.isEmpty else {
            return LaneResolution(logicalIndex: nil, side: "")
        }

        let allHaveBusMono = numericNodes.allSatisfy { $0.1["busmono"] != nil }
        if allHaveBusMono {
            var laneCursor = 0
            for (logicalIndex, node) in numericNodes {
                let width = (node["busmono"] as? Bool ?? false) ? 1 : 2
                let start = laneCursor + 1
                let end = laneCursor + width
                laneCursor = end
                if (start...end).contains(laneIndex) {
                    if width == 2 {
                        return LaneResolution(logicalIndex: logicalIndex, side: laneIndex == start ? "L" : "R")
                    }
                    return LaneResolution(logicalIndex: logicalIndex, side: "")
                }
            }
            return LaneResolution(logicalIndex: nil, side: "")
        }

        return LaneResolution(logicalIndex: laneIndex, side: "")
    }
}
