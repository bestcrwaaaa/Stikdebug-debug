//
//  DebugServerView.swift
//  StikDebug
//

import SwiftUI
import UIKit
import idevice

@MainActor
final class DebugServerViewModel: ObservableObject {

    @Published var command: String = "ls -la /var/mobile"
    @Published var shellMode = true
    @Published var collectAll = true
    @Published var output: String = ""
    @Published var status: String = ""
    @Published var history: [String] = []
    @Published var busy = false
    @Published var pid: String = ""
    @Published var signal: String = "15"
    @Published var filePath: String = "/var/mobile/Media/notes.txt"
    @Published var fileContent: String = ""

    static let presets: [(title: String, command: String)] = [
        ("Root", "ls -la /"),
        ("Identity", "id"),
        ("Who am I", "whoami"),
        ("Processes", "ps aux"),
        ("Disk", "df -h"),
        ("Kernel", "uname -a"),
        ("Uptime", "uptime"),
        ("Env", "env"),
        ("Media", "ls -la /var/mobile/Media"),
        ("Apps", "ls /var/containers/Bundle/Application"),
        ("Greetings", "ls -la /var/mobile/Library/CallServices/Greetings/default")
    ]

    func run() {
        run(command)
    }

    func run(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !busy else { return }

        let payload = shellMode && !trimmed.hasPrefix("platform shell")
            ? "platform shell \(trimmed)"
            : trimmed

        command = text
        if !history.contains(trimmed) { history.insert(trimmed, at: 0) }
        if history.count > 50 { history.removeLast(history.count - 50) }

        busy = true
        output = ""
        status = "Running…"

        let collect = collectAll
        Task.detached(priority: .userInitiated) {
            let started = Date()
            let result = Self.send(payload, collectAll: collect)
            let elapsed = Date().timeIntervalSince(started)

            await MainActor.run {
                self.busy = false
                switch result {
                case let .success(text):
                    self.output = text
                    self.status = String(
                        format: "Done in %.2fs · %d byte(s)",
                        elapsed,
                        text.utf8.count
                    )
                case let .failure(error):
                    self.output = "✗ " + error.localizedDescription
                    self.status = String(format: "Failed after %.2fs", elapsed)
                }
            }
        }
    }

    /// Send one command over the DVT debug proxy.
    nonisolated private static func send(
        _ command: String,
        collectAll: Bool
    ) -> Result<String, Error> {
        do {
            let response = try JITEnableContext.shared.withFreshDebugTunnel(
                hostname: "StikDebugDebugServer"
            ) { adapter, handshake -> String in
                var debugProxy: OpaquePointer?
                if let ffiError = debug_proxy_connect_rsd(adapter, handshake, &debugProxy) {
                    let message = ffiError.pointee.message
                        .map { String(cString: $0) } ?? "unknown"
                    let code = ffiError.pointee.code
                    idevice_error_free(ffiError)
                    throw NSError(
                        domain: "StikDebug",
                        code: Int(code),
                        userInfo: [NSLocalizedDescriptionKey:
                            "Failed to connect the debug proxy: \(message)"]
                    )
                }
                defer { if let debugProxy { debug_proxy_free(debugProxy) } }

                guard let commandHandle = debugserver_command_new(command, nil, 0) else {
                    throw NSError(
                        domain: "StikDebug",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey:
                            "Failed to create the debug server command."]
                    )
                }
                defer { debugserver_command_free(commandHandle) }

                var first: UnsafeMutablePointer<CChar>?
                let ffiError = debug_proxy_send_command(debugProxy, commandHandle, &first)
                if let ffiError {
                    if let first { idevice_string_free(first) }
                    let message = ffiError.pointee.message
                        .map { String(cString: $0) } ?? "unknown"
                    let code = ffiError.pointee.code
                    idevice_error_free(ffiError)
                    throw NSError(
                        domain: "StikDebug",
                        code: Int(code),
                        userInfo: [NSLocalizedDescriptionKey:
                            "The debug server refused the command: \(message)"]
                    )
                }

                var parts: [String] = []
                if let first {
                    parts.append(String(cString: first))
                    idevice_string_free(first)
                }

                if collectAll {
                    // The device closes the channel when the command finishes.
                    for _ in 0..<512 {
                        var chunk: UnsafeMutablePointer<CChar>?
                        if let readError = debug_proxy_read_response(debugProxy, &chunk) {
                            if let chunk { idevice_string_free(chunk) }
                            idevice_error_free(readError)
                            break
                        }
                        guard let chunk else { break }
                        let text = String(cString: chunk)
                        idevice_string_free(chunk)
                        if text.isEmpty { break }
                        parts.append(text)
                    }
                }

                return parts.joined()
            }
            return .success(response)
        } catch {
            return .failure(error)
        }
    }

    func readFile() {
        let path = filePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        fileContent = ""
        run("cat \(path)")
    }

    func writeFile() {
        let path = filePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        let encoded = Data(fileContent.utf8).base64EncodedString()
        run("echo \(encoded) | base64 -d > \(path)")
    }

    func listProcesses() {
        guard !busy else { return }
        busy = true
        status = "Listing processes…"

        Task.detached(priority: .userInitiated) {
            let result: Result<String, Error>
            do {
                let processes = try JITEnableContext.shared.fetchProcessList()
                let text = processes
                    .map { entry -> String in
                        let name = entry["name"] as? String ?? "?"
                        let pid = entry["pid"] as? Int ?? 0
                        let executable = entry["executablePath"] as? String ?? ""
                        return "\(pid)\t\(name)\t\(executable)"
                    }
                    .joined(separator: "\n")
                result = .success(text)
            } catch {
                result = .failure(error)
            }

            await MainActor.run {
                self.busy = false
                switch result {
                case let .success(text):
                    self.output = text
                    let count = text.split(separator: "\n").count
                    self.status = "\(count) process(es)"
                case let .failure(error):
                    self.output = "✗ " + error.localizedDescription
                    self.status = "Failed"
                }
            }
        }
    }

    func sendSignal() {
        guard let pidValue = Int32(pid),
              let number = Int32(signal),
              !busy else { return }
        busy = true

        Task.detached(priority: .userInitiated) {
            let result: Result<String, Error>
            do {
                try JITEnableContext.shared.sendSignal(number, toProcessWithPID: pidValue)
                result = .success("Sent signal \(number) to process \(pidValue).")
            } catch {
                result = .failure(error)
            }

            await MainActor.run {
                self.busy = false
                switch result {
                case let .success(text):
                    self.output = text
                    self.status = "Done"
                case let .failure(error):
                    self.output = "✗ " + error.localizedDescription
                    self.status = "Failed"
                }
            }
        }
    }

    func killProcess() {
        guard let pidValue = Int32(pid), !busy else { return }
        busy = true

        Task.detached(priority: .userInitiated) {
            let result: Result<String, Error>
            do {
                try JITEnableContext.shared.killProcess(withPID: pidValue)
                result = .success("Killed process \(pidValue).")
            } catch {
                result = .failure(error)
            }

            await MainActor.run {
                self.busy = false
                switch result {
                case let .success(text):
                    self.output = text
                    self.status = "Done"
                case let .failure(error):
                    self.output = "✗ " + error.localizedDescription
                    self.status = "Failed"
                }
            }
        }
    }
}

// MARK: - View

struct DebugServerView: View {
    @StateObject private var model = DebugServerViewModel()

    var body: some View {
        Form {
            Section {
                TextField("ls -la /var/mobile", text: $model.command)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .lineLimit(3)

                HStack {
                    Button {
                        model.run()
                    } label: {
                        Label("Run", systemImage: "play.fill")
                    }
                    .disabled(model.busy)

                    Spacer()

                    Toggle("Shell", isOn: $model.shellMode)
                        .labelsHidden()
                    Text("shell")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle("Collect the whole output", isOn: $model.collectAll)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(DebugServerViewModel.presets, id: \.title) { preset in
                            Button {
                                model.run(preset.command)
                            } label: {
                                Text(preset.title)
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.accentColor.opacity(0.15))
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(model.busy)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Command")
            } footer: {
                Text("Type a command and it runs on the device. With shell mode on, the text is sent as `platform shell <command>`; with it off, the text goes to the debug server verbatim.")
            }

            Section {
                if model.output.isEmpty {
                    Text("No output yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal, showsIndicators: true) {
                        Text(model.output)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                HStack {
                    Text(model.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = model.output
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(.caption)
                    }
                    Button {
                        model.output = ""
                        model.status = ""
                    } label: {
                        Label("Clear", systemImage: "trash")
                            .font(.caption)
                    }
                }
            } header: {
                Text("Output")
            }

            Section("Files") {
                TextField("Path on the device", text: $model.filePath)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                TextField("Content", text: $model.fileContent, axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(3...10)

                HStack {
                    Button {
                        model.readFile()
                    } label: {
                        Label("Read", systemImage: "arrow.down.doc")
                    }
                    .disabled(model.busy)

                    Button {
                        model.writeFile()
                    } label: {
                        Label("Write", systemImage: "arrow.up.doc")
                    }
                    .disabled(model.busy)
                }
            }

            Section("Functions") {
                Button {
                    model.listProcesses()
                } label: {
                    Label("List processes", systemImage: "list.bullet.rectangle")
                }
                .disabled(model.busy)

                HStack {
                    TextField("PID", text: $model.pid)
                        .keyboardType(.numberPad)
                        .font(.system(.body, design: .monospaced))
                    TextField("Signal", text: $model.signal)
                        .keyboardType(.numberPad)
                        .font(.system(.body, design: .monospaced))
                }

                Button {
                    model.sendSignal()
                } label: {
                    Label("Send signal", systemImage: "bolt.horizontal")
                }
                .disabled(model.busy)

                Button(role: .destructive) {
                    model.killProcess()
                } label: {
                    Label("Kill process", systemImage: "xmark.octagon")
                }
                .disabled(model.busy)
            }

            if !model.history.isEmpty {
                Section("History") {
                    ForEach(model.history, id: \.self) { entry in
                        Button {
                            model.run(entry)
                        } label: {
                            Text(entry)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                        }
                        .disabled(model.busy)
                    }
                }
            }
        }
        .navigationTitle("Debug Server")
    }
}
