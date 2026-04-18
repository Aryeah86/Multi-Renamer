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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Wing Multitrack Renamer")
                .font(.system(size: 22, weight: .semibold))

            Text("Choose the multitrack folder, the matching snap file, and the card. Rename in place is the default; copy is optional.")
                .foregroundStyle(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    labeledPathRow(title: "1. Multitrack folder", text: $model.multitrackFolderPath, action: model.chooseMultitrackFolder)
                    labeledPathRow(title: "2. Snap file", text: $model.snapFilePath, action: model.chooseSnapFile)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("3. Card")
                        Picker("Card", selection: $model.selectedCard) {
                            Text("Card A").tag(CardSelection.a)
                            Text("Card B").tag(CardSelection.b)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 220)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Operation")
                        Picker("Operation", selection: $model.selectedOperation) {
                            ForEach(OperationMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 320)
                    }
                }
                .padding(8)
            }

            HStack(spacing: 10) {
                Button(model.selectedOperation == .copy ? "Generate Copy" : "Rename Files") {
                    model.generateCopy()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isRunning)

                Button("Cancel") {
                    model.cancel()
                }
                .disabled(!model.isRunning)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(model.statusText)
                    .font(.system(size: 12))
                ProgressView(value: model.progressValue, total: model.progressTotal)
            }

            if !model.outputFolderPath.isEmpty {
                Text(model.selectedOperation == .copy ? "Output: \(model.outputFolderPath)" : "Target folder: \(model.outputFolderPath)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Table(model.rows) {
                TableColumn("Original") { row in
                    Text(row.originalName)
                }
                TableColumn("Absolute") { row in
                    Text("\(row.absoluteSlot)")
                }
                TableColumn("Resolved Name") { row in
                    Text(row.resolvedName)
                }
                TableColumn("Final Filename") { row in
                    Text(row.finalName)
                }
                TableColumn("Status") { row in
                    Text(row.status)
                }
            }
        }
        .padding(18)
        .frame(minWidth: 920, minHeight: 620)
        .alert("Error", isPresented: $model.showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alertMessage)
        }
    }

    @ViewBuilder
    private func labeledPathRow(title: String, text: Binding<String>, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            HStack {
                TextField("", text: text)
                    .textFieldStyle(.roundedBorder)
                Button("Browse...") {
                    action()
                }
            }
        }
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
