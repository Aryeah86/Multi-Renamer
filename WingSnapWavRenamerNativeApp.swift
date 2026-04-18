import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class RenamerViewModel: ObservableObject {
    @Published var multitrackFolderPath = ""
    @Published var snapFilePath = ""
    @Published var selectedCard: CardSelection = .b
    @Published var selectedOperation: OperationMode = .rename
    @Published var rows: [PlanRow] = []
    @Published var statusText = "Ready"
    @Published var progressValue: Double = 0
    @Published var progressTotal: Double = 1
    @Published var isRunning = false
    @Published var outputFolderPath = ""
    @Published var alertMessage = ""
    @Published var showAlert = false

    private var currentTask: Task<Void, Never>?

    func chooseMultitrackFolder() {
        let panel = makeOpenPanel(
            canChooseFiles: false,
            canChooseDirectories: true,
            prompt: "Choose Folder",
            startingPath: multitrackFolderPath
        )
        present(panel: panel) { [weak self] url in
            self?.multitrackFolderPath = url.path
        }
    }

    func chooseSnapFile() {
        let panel = makeOpenPanel(
            canChooseFiles: true,
            canChooseDirectories: false,
            prompt: "Choose Snap",
            startingPath: snapFilePath.isEmpty ? multitrackFolderPath : snapFilePath
        )
        if #available(macOS 12.0, *) {
            panel.allowedContentTypes = [UTType(filenameExtension: "snap") ?? .json, .json]
        }
        present(panel: panel) { [weak self] url in
            self?.snapFilePath = url.path
        }
    }

    func cancel() {
        currentTask?.cancel()
        statusText = "Cancelling..."
    }

    func generateCopy() {
        guard !isRunning else { return }
        guard !multitrackFolderPath.isEmpty else {
            presentError("Please choose a multitrack folder.")
            return
        }
        guard !snapFilePath.isEmpty else {
            presentError("Please choose a snap file.")
            return
        }

        rows = []
        outputFolderPath = ""
        progressValue = 0
        progressTotal = 1
        statusText = "Building rename plan..."
        isRunning = true

        let folderURL = URL(fileURLWithPath: multitrackFolderPath)
        let snapURL = URL(fileURLWithPath: snapFilePath)
        let card = selectedCard
        let operation = selectedOperation

        currentTask = Task {
            var createdCopyFolderPath = ""
            do {
                let wavEntries = try NativeRenamer.scanWavs(in: folderURL)
                let snapRoot = try NativeRenamer.loadSnap(from: snapURL)
                try Task.checkCancellation()
                let outputURL = try makeDestinationURL(baseFolder: folderURL, card: card, operation: operation)
                if operation == .copy {
                    createdCopyFolderPath = outputURL.path
                }
                let planRows = try NativeRenamer.buildPlan(
                    wavEntries: wavEntries,
                    snapRoot: snapRoot,
                    card: card,
                    destinationURL: outputURL
                )

                rows = planRows
                outputFolderPath = operation == .copy ? outputURL.path : folderURL.path
                progressValue = 0
                progressTotal = Double(planRows.count)
                statusText = operation == .copy ? "Copying files..." : "Renaming files..."

                let progressHandler: @Sendable (Int, Int, String) -> Void = { [weak self] copied, total, lastName in
                    Task { @MainActor in
                        self?.progressValue = Double(copied)
                        self?.progressTotal = Double(total)
                        let verb = operation == .copy ? "Copying" : "Renaming"
                        self?.statusText = "\(verb) \(copied)/\(total): \(lastName)"
                    }
                }

                if operation == .copy {
                    try NativeRenamer.copyPlan(rows: planRows, progress: progressHandler)
                } else {
                    try NativeRenamer.renamePlan(rows: planRows, progress: progressHandler)
                }

                if operation == .copy {
                    statusText = "Done. Copied \(planRows.count) files to \(outputURL.path)"
                } else {
                    statusText = "Done. Renamed \(planRows.count) files in place."
                }
                isRunning = false
            } catch is CancellationError {
                if operation == .copy && !createdCopyFolderPath.isEmpty {
                    try? FileManager.default.removeItem(atPath: createdCopyFolderPath)
                }
                statusText = "Cancelled."
                isRunning = false
            } catch {
                if operation == .copy && !createdCopyFolderPath.isEmpty {
                    try? FileManager.default.removeItem(atPath: createdCopyFolderPath)
                    outputFolderPath = ""
                }
                presentError(error.localizedDescription)
                isRunning = false
                statusText = "Failed."
            }
        }
    }

    private func makeDestinationURL(baseFolder: URL, card: CardSelection, operation: OperationMode) throws -> URL {
        if operation == .copy {
            return try NativeRenamer.makeTimestampedOutputFolder(baseFolder: baseFolder, card: card)
        }
        return NativeRenamer.makeRenameDestination(baseFolder: baseFolder)
    }

    private func presentError(_ message: String) {
        alertMessage = message
        showAlert = true
    }

    private func makeOpenPanel(
        canChooseFiles: Bool,
        canChooseDirectories: Bool,
        prompt: String,
        startingPath: String
    ) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseFiles = canChooseFiles
        panel.canChooseDirectories = canChooseDirectories
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.directoryURL = preferredDirectoryURL(for: startingPath)
        return panel
    }

    private func present(panel: NSOpenPanel, completion: @escaping (URL) -> Void) {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                completion(url)
            }
            return
        }

        if panel.runModal() == .OK, let url = panel.url {
            completion(url)
        }
    }

    private func preferredDirectoryURL(for path: String) -> URL {
        if !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            let candidate = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}

struct ContentView: View {
    @StateObject private var model = RenamerViewModel()
    @State private var isSourceDropTargeted = false
    @State private var isSnapDropTargeted = false
    private let panelWidth: CGFloat = 560
    private let panelHeight: CGFloat = 596

    var body: some View {
        ZStack {
            InstrumentTheme.background
                .ignoresSafeArea()

            VStack(spacing: 14) {
                    slotPanel(
                        title: "SLOT 1: SOURCE",
                        systemImage: "folder.fill",
                        primary: model.multitrackFolderPath.isEmpty ? "Select multitrack folder" : fileName(from: model.multitrackFolderPath),
                        secondary: model.multitrackFolderPath.isEmpty ? "Browse for extracted WAV folder" : model.multitrackFolderPath,
                        isDropTargeted: isSourceDropTargeted,
                        action: model.chooseMultitrackFolder
                    )
                    .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isSourceDropTargeted) { providers in
                        handleDrop(providers: providers, expectingDirectory: true) { url in
                            model.multitrackFolderPath = url.path
                        }
                    }

                    slotPanel(
                        title: "SLOT 2: REFERENCE",
                        systemImage: "doc.text.fill",
                        primary: model.snapFilePath.isEmpty ? "Select snap reference" : fileName(from: model.snapFilePath),
                        secondary: model.snapFilePath.isEmpty ? "Browse for .snap file" : model.snapFilePath,
                        isDropTargeted: isSnapDropTargeted,
                        action: model.chooseSnapFile
                    )
                    .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isSnapDropTargeted) { providers in
                        handleDrop(providers: providers, expectingDirectory: false) { url in
                            model.snapFilePath = url.path
                        }
                    }

                    settingsSection
                    actionSection
                    telemetrySection
            }
            .padding(18)
            .frame(width: panelWidth, height: panelHeight)
            .background(InstrumentTheme.surface)
            .overlay(Rectangle().stroke(InstrumentTheme.outline, lineWidth: 2))
        }
        .frame(width: panelWidth, height: panelHeight)
        .alert("Error", isPresented: $model.showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alertMessage)
        }
    }

    private func slotPanel(
        title: String,
        systemImage: String,
        primary: String,
        secondary: String,
        isDropTargeted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                Text(title)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(InstrumentTheme.cyan)

                VStack(spacing: 8) {
                    Image(systemName: systemImage)
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(InstrumentTheme.cyan)

                    Text(primary)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(InstrumentTheme.textPrimary)
                        .lineLimit(1)

                    Text(secondary)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(InstrumentTheme.textMuted)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 84)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 136)
            .background(isDropTargeted ? InstrumentTheme.dropTarget : InstrumentTheme.panelRecessed)
            .overlay(Rectangle().stroke(isDropTargeted ? InstrumentTheme.cyan : InstrumentTheme.outline, lineWidth: isDropTargeted ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var settingsSection: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 0) {
                    cardButton(.a)
                    cardButton(.b)
                }
                .overlay(Rectangle().stroke(InstrumentTheme.outline, lineWidth: 1))
            }
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)

            HStack {
                HStack(spacing: 0) {
                    modeButton(.rename)
                    modeButton(.copy)
                }
                .overlay(Rectangle().stroke(InstrumentTheme.outline, lineWidth: 1))
            }
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
        }
        .overlay(alignment: .top) {
            Rectangle().fill(InstrumentTheme.hairline).frame(height: 1)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(InstrumentTheme.hairline).frame(height: 1)
        }
    }

    private func cardButton(_ card: CardSelection) -> some View {
        let selected = model.selectedCard == card
        return Button {
            model.selectedCard = card
        } label: {
            VStack(spacing: 1) {
                Text(card == .a ? "CARD A" : "CARD B")
                Text(card == .a ? "1-32" : "33-64")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .bold, design: .monospaced))
        .foregroundStyle(selected ? InstrumentTheme.onAmber : InstrumentTheme.textMuted)
        .frame(width: 96, height: 34)
        .background(selected ? InstrumentTheme.amber : InstrumentTheme.panelRecessed)
        .contentShape(Rectangle())
        .overlay(alignment: .trailing) {
            if card == .a {
                Rectangle().fill(InstrumentTheme.outline).frame(width: 1)
            }
        }
    }

    private func modeButton(_ mode: OperationMode) -> some View {
        let selected = model.selectedOperation == mode
        return Button {
            model.selectedOperation = mode
        } label: {
            Text(mode == .rename ? "RENAME" : "COPY")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? InstrumentTheme.onAmber : InstrumentTheme.textMuted)
        .frame(width: 96, height: 26)
        .background(selected ? InstrumentTheme.amber : InstrumentTheme.panelRecessed)
        .contentShape(Rectangle())
        .overlay(alignment: .trailing) {
            if mode == .rename {
                Rectangle().fill(InstrumentTheme.outline).frame(width: 1)
            }
        }
    }

    private var actionSection: some View {
        HStack(spacing: 10) {
            commandButton(
                title: model.selectedOperation == .copy ? "EXECUTE COPY" : "EXECUTE RENAME",
                icon: "play.fill",
                fill: InstrumentTheme.amber,
                stroke: InstrumentTheme.outline,
                foreground: InstrumentTheme.onAmber,
                disabled: model.isRunning,
                action: model.generateCopy
            )
        }
    }

    private func commandButton(
        title: String,
        icon: String?,
        fill: Color,
        stroke: Color,
        foreground: Color,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .bold))
                }
                Text(title)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
            }
            .frame(maxWidth: .infinity, minHeight: 42)
            .foregroundStyle(disabled ? InstrumentTheme.textMuted : foreground)
            .background(disabled ? InstrumentTheme.surfaceHighest : fill)
            .overlay(Rectangle().stroke(disabled ? InstrumentTheme.outline.opacity(0.35) : stroke, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func handleDrop(
        providers: [NSItemProvider],
        expectingDirectory: Bool,
        assign: @escaping (URL) -> Void
    ) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            switch item {
            case let data as Data:
                url = URL(dataRepresentation: data, relativeTo: nil)
            case let nsURL as NSURL:
                url = nsURL as URL
            case let string as String:
                url = URL(string: string)
            default:
                url = nil
            }

            guard let fileURL = url else { return }
            let path = fileURL.path
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return }

            if expectingDirectory {
                guard isDirectory.boolValue else { return }
            } else {
                guard !isDirectory.boolValue else { return }
                guard fileURL.pathExtension.lowercased() == "snap" else { return }
            }

            Task { @MainActor in
                assign(fileURL)
            }
        }

        return true
    }

    private var telemetrySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("SYSTEM STATUS")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(InstrumentTheme.cyan)
                Spacer()
                Text(model.isRunning ? "ACTIVE" : "IDLE")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(model.isRunning ? InstrumentTheme.amber : InstrumentTheme.textMuted)
            }

            Text(model.statusText)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(InstrumentTheme.textPrimary)

            ProgressView(value: model.progressValue, total: model.progressTotal)
                .tint(InstrumentTheme.cyan)

            HStack(spacing: 18) {
                metric(label: "ROWS", value: "\(model.rows.count)")
                metric(label: "CARD", value: model.selectedCard.rawValue)
                metric(label: "MODE", value: model.selectedOperation == .rename ? "RENAME" : "COPY")
            }

            if !model.outputFolderPath.isEmpty {
                Text(model.selectedOperation == .copy ? "OUTPUT \(model.outputFolderPath)" : "TARGET \(model.outputFolderPath)")
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(InstrumentTheme.textMuted)
                    .textSelection(.enabled)
                    .lineLimit(3)
            }

            if !model.rows.isEmpty {
                VStack(spacing: 0) {
                    HStack {
                        tableHeader("ORIGINAL", width: 120)
                        tableHeader("ABS", width: 42)
                        tableHeader("FINAL", width: nil)
                        tableHeader("STATE", width: 82)
                    }
                    .padding(.bottom, 6)

                    ForEach(Array(model.rows.prefix(6))) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            tableCell(row.originalName, width: 120)
                            tableCell("\(row.absoluteSlot)", width: 42)
                            tableCell(row.finalName, width: nil)
                            tableCell(row.status, width: 82, color: row.status == "OK" ? InstrumentTheme.cyan : InstrumentTheme.error)
                        }
                        .padding(.vertical, 4)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(InstrumentTheme.hairline).frame(height: 1)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private func metric(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(InstrumentTheme.textMuted)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(InstrumentTheme.textPrimary)
        }
    }

    private func tableHeader(_ text: String, width: CGFloat?) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(InstrumentTheme.textMuted)
            .frame(width: width, alignment: .leading)
    }

    private func tableCell(_ text: String, width: CGFloat?, color: Color = InstrumentTheme.textPrimary) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .regular, design: .monospaced))
            .foregroundStyle(color)
            .lineLimit(1)
            .frame(width: width, alignment: .leading)
    }

    private func fileName(from path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

@main
struct WingSnapWavRenamerNativeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}

enum InstrumentTheme {
    static let background = Color(red: 0.06, green: 0.06, blue: 0.06)
    static let surface = Color(red: 0.075, green: 0.075, blue: 0.075)
    static let panelRecessed = Color(red: 0.055, green: 0.055, blue: 0.055)
    static let surfaceHighest = Color(red: 0.21, green: 0.21, blue: 0.21)
    static let outline = Color(red: 0.82, green: 0.82, blue: 0.82)
    static let hairline = Color(red: 0.32, green: 0.27, blue: 0.20).opacity(0.22)
    static let amber = Color(red: 1.0, green: 0.69, blue: 0.0)
    static let onAmber = Color(red: 0.42, green: 0.28, blue: 0.0)
    static let cyan = Color(red: 0.0, green: 0.89, blue: 1.0)
    static let textPrimary = Color(red: 0.90, green: 0.89, blue: 0.88)
    static let textMuted = Color(red: 0.73, green: 0.67, blue: 0.60)
    static let error = Color(red: 1.0, green: 0.71, blue: 0.67)
    static let dropTarget = Color(red: 0.07, green: 0.14, blue: 0.16)
}
