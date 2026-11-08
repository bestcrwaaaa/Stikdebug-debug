//
//  DebugServerView.swift
//  StikDebug — full idevice control panel
//

import SwiftUI
import UIKit
import idevice

// MARK: - plist helpers

private func plistToString(_ plist: UnsafeMutableRawPointer?) -> String {
    guard let plist else { return "<nil>" }
    var xml: UnsafeMutablePointer<CChar>?
    var len: UInt32 = 0
    let err = plist_to_xml(plist, &xml, &len)
    defer { if let xml { plist_mem_free(xml) } }
    guard err == PLIST_ERR_SUCCESS, let xml else { return "<plist err \(err.rawValue)>" }
    return String(cString: xml)
}

private func freePlist(_ plist: UnsafeMutableRawPointer?) {
    if let plist { plist_free(plist) }
}

private func ideviceErrorString(_ err: UnsafeMutablePointer<IdeviceFfiError>?) -> String? {
    guard let err else { return nil }
    let msg = err.pointee.message.map { String(cString: $0) } ?? "code \(err.pointee.code)"
    idevice_error_free(err)
    return msg
}

// MARK: - Service tunnels

private enum Tunnel {
    static func remoteServer<T>(hostname: String = "StikDebugRemoteServer",
                                _ body: (OpaquePointer) throws -> T) throws -> T {
        try JITEnableContext.shared.withFreshDebugTunnel(hostname: hostname) { adapter, handshake in
            var server: OpaquePointer?
            if let err = remote_server_connect_rsd(adapter, handshake, &server) {
                throw NSError(domain: "StikDebug", code: Int(err.pointee.code),
                              userInfo: [NSLocalizedDescriptionKey:
                                "remote_server: \(ideviceErrorString(err) ?? "?")"])
            }
            guard let server else {
                throw NSError(domain: "StikDebug", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "remote_server nil"])
            }
            defer { remote_server_free(server) }
            return try body(server)
        }
    }

    static func diagnostics<T>(hostname: String = "StikDebugDiag",
                               _ body: (OpaquePointer) throws -> T) throws -> T {
        try JITEnableContext.shared.withFreshDebugTunnel(hostname: hostname) { adapter, handshake in
            var client: OpaquePointer?
            if let err = diagnostics_relay_client_connect_rsd(adapter, handshake, &client) {
                throw NSError(domain: "StikDebug", code: Int(err.pointee.code),
                              userInfo: [NSLocalizedDescriptionKey:
                                "diagnostics: \(ideviceErrorString(err) ?? "?")"])
            }
            guard let client else {
                throw NSError(domain: "StikDebug", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "diagnostics nil"])
            }
            defer { diagnostics_relay_client_free(client) }
            return try body(client)
        }
    }

    static func config<T>(hostname: String = "StikDebugConfig",
                          _ body: (OpaquePointer) throws -> T) throws -> T {
        try JITEnableContext.shared.withFreshDebugTunnel(hostname: hostname) { adapter, handshake in
            var client: OpaquePointer?
            if let err = configuration_service_connect_rsd(adapter, handshake, &client) {
                throw NSError(domain: "StikDebug", code: Int(err.pointee.code),
                              userInfo: [NSLocalizedDescriptionKey:
                                "config: \(ideviceErrorString(err) ?? "?")"])
            }
            guard let client else {
                throw NSError(domain: "StikDebug", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "config nil"])
            }
            defer { configuration_service_free(client) }
            return try body(client)
        }
    }

    static func notificationProxy<T>(hostname: String = "StikDebugNotif",
                                     _ body: (OpaquePointer) throws -> T) throws -> T {
        try JITEnableContext.shared.withFreshDebugTunnel(hostname: hostname) { adapter, handshake in
            var client: OpaquePointer?
            if let err = notification_proxy_connect_rsd(adapter, handshake, &client) {
                throw NSError(domain: "StikDebug", code: Int(err.pointee.code),
                              userInfo: [NSLocalizedDescriptionKey:
                                "notif: \(ideviceErrorString(err) ?? "?")"])
            }
            guard let client else {
                throw NSError(domain: "StikDebug", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "notif nil"])
            }
            defer { notification_proxy_client_free(client) }
            return try body(client)
        }
    }

    static func locationSim<T>(hostname: String = "StikDebugLoc",
                               _ body: (OpaquePointer) throws -> T) throws -> T {
        try remoteServer(hostname: hostname) { server in
            var client: OpaquePointer?
            if let err = location_simulation_new(server, &client) {
                throw NSError(domain: "StikDebug", code: Int(err.pointee.code),
                              userInfo: [NSLocalizedDescriptionKey:
                                "location: \(ideviceErrorString(err) ?? "?")"])
            }
            guard let client else {
                throw NSError(domain: "StikDebug", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "location nil"])
            }
            defer { location_simulation_free(client) }
            return try body(client)
        }
    }
}

// MARK: - ViewModel

@MainActor
final class DebugServerViewModel: ObservableObject {

    @Published var output: String = ""
    @Published var status: String = ""
    @Published var busy = false

    // raw command
    @Published var command: String = "QStartNoAckMode"
    @Published var shellMode = false
    @Published var history: [String] = []

    // args
    @Published var pid: String = ""
    @Published var signal: String = "15"
    @Published var bundleID: String = "com.apple.mobilesafari"
    @Published var filePath: String = "/"
    @Published var latitude: String = "55.7558"
    @Published var longitude: String = "37.6173"
    @Published var notificationName: String = "com.apple.springboard.lockcomplete"
    @Published var mgKeys: String = "ProductType,ProductVersion,BuildVersion,UniqueDeviceID,SerialNumber,HWModel,CPUArchitecture,MarketingName"
    @Published var textInput: String = "Hello"

    private func start(_ label: String) {
        busy = true
        status = label
        output = ""
    }

    private func finish(_ result: Result<String, Error>) {
        busy = false
        switch result {
        case let .success(text):
            output = text
            status = "Done · \(text.utf8.count) byte(s)"
        case let .failure(err):
            output = "✗ " + err.localizedDescription
            status = "Failed"
        }
    }

    private func run(_ label: String, _ work: @escaping () throws -> String) {
        guard !busy else { return }
        start(label)
        Task.detached(priority: .userInitiated) {
            let r: Result<String, Error>
            do { r = .success(try work()) } catch { r = .failure(error) }
            await MainActor.run { self.finish(r) }
        }
    }

    // MARK: Command

    func runRawCommand() {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !busy else { return }
        let payload = shellMode && !trimmed.hasPrefix("platform shell")
            ? "platform shell \(trimmed)" : trimmed
        if !history.contains(trimmed) { history.insert(trimmed, at: 0) }
        if history.count > 50 { history.removeLast(history.count - 50) }

        busy = true; output = ""; status = "Running…"
        Task.detached(priority: .userInitiated) {
            let r = Self.sendDebug(payload)
            await MainActor.run {
                self.busy = false
                switch r {
                case let .success(t): self.output = t; self.status = "OK"
                case let .failure(e): self.output = "✗ \(e.localizedDescription)"; self.status = "Failed"
                }
            }
        }
    }

    nonisolated private static func sendDebug(_ command: String) -> Result<String, Error> {
        do {
            let out = try JITEnableContext.shared.withFreshDebugTunnel(hostname: "StikDebugDebugServer") { adapter, handshake -> String in
                var proxy: OpaquePointer?
                if let e = debug_proxy_connect_rsd(adapter, handshake, &proxy) {
                    throw NSError(domain: "dbg", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: ideviceErrorString(e) ?? "?"])
                }
                defer { if let proxy { debug_proxy_free(proxy) } }
                debug_proxy_send_ack(proxy); debug_proxy_send_ack(proxy)
                if let q = debugserver_command_new("QStartNoAckMode", nil, 0) {
                    var r: UnsafeMutablePointer<CChar>?
                    let e = debug_proxy_send_command(proxy, q, &r)
                    debugserver_command_free(q)
                    if let r { idevice_string_free(r) }
                    if let e { idevice_error_free(e) }
                }
                debug_proxy_set_ack_mode(proxy, 0)
                guard let cmd = debugserver_command_new(command, nil, 0) else {
                    throw NSError(domain: "dbg", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "create failed"])
                }
                var resp: UnsafeMutablePointer<CChar>?
                let e = debug_proxy_send_command(proxy, cmd, &resp)
                debugserver_command_free(cmd)
                if let e {
                    if let resp { idevice_string_free(resp) }
                    throw NSError(domain: "dbg", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: ideviceErrorString(e) ?? "?"])
                }
                defer { if let resp { idevice_string_free(resp) } }
                return resp.map { String(cString: $0) } ?? "<nil>"
            }
            return .success(out)
        } catch { return .failure(error) }
    }

    // MARK: System / Diagnostics

    func diagMobileGestalt() {
        let keys = mgKeys.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        run("MobileGestalt…") {
            try Tunnel.diagnostics { client in
                var plist: UnsafeMutableRawPointer?
                let r: Int32 = keys.withCStringArray { arr, count in
                    let e = diagnostics_relay_client_mobilegestalt(client, arr, count, &plist)
                    return e == nil ? 0 : 1
                }
                if r != 0 { throw NSError(domain: "mg", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "mobilegestalt failed"]) }
                defer { freePlist(plist) }
                return plistToString(plist)
            }
        }
    }

    func diagAll() {
        run("DiagnosticsRelay.all…") {
            try Tunnel.diagnostics { c in
                var plist: UnsafeMutableRawPointer?
                if let e = diagnostics_relay_client_all(c, &plist) {
                    throw NSError(domain: "all", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: ideviceErrorString(e) ?? "?"])
                }
                defer { freePlist(plist) }
                return plistToString(plist)
            }
        }
    }

    func diagIoRegistry() {
        run("IO Registry…") {
            try Tunnel.diagnostics { c in
                var plist: UnsafeMutableRawPointer?
                if let e = diagnostics_relay_client_ioregistry(c, nil, nil, nil, &plist) {
                    throw NSError(domain: "ior", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: ideviceErrorString(e) ?? "?"])
                }
                defer { freePlist(plist) }
                return plistToString(plist)
            }
        }
    }

    func diagGasGauge() {
        run("GasGauge…") {
            try Tunnel.diagnostics { c in
                var plist: UnsafeMutableRawPointer?
                if let e = diagnostics_relay_client_gasguage(c, &plist) {
                    throw NSError(domain: "gg", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: ideviceErrorString(e) ?? "?"])
                }
                defer { freePlist(plist) }
                return plistToString(plist)
            }
        }
    }

    func diagNand() {
        run("NAND…") {
            try Tunnel.diagnostics { c in
                var plist: UnsafeMutableRawPointer?
                if let e = diagnostics_relay_client_nand(c, &plist) {
                    throw NSError(domain: "nand", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: ideviceErrorString(e) ?? "?"])
                }
                defer { freePlist(plist) }
                return plistToString(plist)
            }
        }
    }

    func diagWifi() {
        run("WiFi…") {
            try Tunnel.diagnostics { c in
                var plist: UnsafeMutableRawPointer?
                if let e = diagnostics_relay_client_wifi(c, &plist) {
                    throw NSError(domain: "wifi", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: ideviceErrorString(e) ?? "?"])
                }
                defer { freePlist(plist) }
                return plistToString(plist)
            }
        }
    }

    // MARK: Power

    func powerRestart() {
        run("Restarting device…") {
            try Tunnel.diagnostics { c in
                if let e = diagnostics_relay_client_restart(c) {
                    throw NSError(domain: "rst", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: ideviceErrorString(e) ?? "?"])
                }
                return "OK — restart issued"
            }
        }
    }

    func powerShutdown() {
        run("Shutting down…") {
            try Tunnel.diagnostics { c in
                if let e = diagnostics_relay_client_shutdown(c) {
                    throw NSError(domain: "sd", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: ideviceErrorString(e) ?? "?"])
                }
                return "OK — shutdown issued"
            }
        }
    }

    func powerSleep() {
        run("Sleeping…") {
            try Tunnel.diagnostics { c in
                if let e = diagnostics_relay_client_sleep(c) {
                    throw NSError(domain: "sl", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: ideviceErrorString(e) ?? "?"])
                }
                return "OK — sleep issued"
            }
        }
    }

    // MARK: Config

    func configSetDark(_ dark: Bool) {
        run("Set UI style…") {
            try Tunnel.config { c in
                let style: IdeviceUserInterfaceStyle = dark ? IdeviceUserInterfaceStyleDark : IdeviceUserInterfaceStyleLight
                if let e = configuration_service_set_user_interface_style(c, style) {
                    throw NSError(domain: "cfg", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: ideviceErrorString(e) ?? "?"])
                }
                return "OK"
            }
        }
    }

    func configGetStyle() {
        run("Get UI style…") {
            try Tunnel.config { c in
                var style: IdeviceUserInterfaceStyle = IdeviceUserInterfaceStyleLight
                if let e = configuration_service_get_user_interface_style(c, &style) {
                    throw NSError(domain: "cfg", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: ideviceErrorString(e) ?? "?"])
                }
                return "style: \(style == IdeviceUserInterfaceStyleDark ? "Dark" : "Light")"
            }
        }
    }

    func configReduceMotion(_ on: Bool) {
        run("Reduce Motion \(on)…") {
            try Tunnel.config { c in
                if let e = configuration_service_set_reduce_motion(c, on ? 1 : 0) {
                    throw NSError(domain: "cfg", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: ideviceErrorString(e) ?? "?"])
                }
                return "OK"
            }
        }
    }

    func configReduceTransparency(_ on: Bool) {
        run("Reduce Transparency \(on)…") {
            try Tunnel.config { c in
                if let e = configuration_service_set_reduce_transparency(c, on ? 1 : 0) {
                    throw NSError(domain: "cfg", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: ideviceErrorString(e) ?? "?"])
                }
                return "OK"
            }
        }
    }

    func configShowBorders(_ on: Bool) {
        run("Show Borders \(on)…") {
            try Tunnel.config { c in
                if let e = configuration_service_set_show_borders(c, on ? 1 : 0) {
                    throw NSError(domain: "cfg", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: ideviceErrorString(e) ?? "?"])
                }
                return "OK"
            }
        }
    }

    func configSetTextSize(_ size: String) {
        run("Text size \(size)…") {
            try Tunnel.config { c in
                if let e = configuration_service_set_device_text_size(c, size) {
                    throw NSError(domain: "cfg", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: ideviceErrorString(e) ?? "?"])
                }
                return "OK"
            }
        }
    }

    // MARK: Location

    func setLocation() {
        guard let lat = Double(latitude), let lon = Double(longitude) else {
            output = "✗ invalid coordinates"; return
        }
        run("Set location \(lat),\(lon)…") {
            try Tunnel.locationSim { c in
                if let e = location_simulation_set(c, lat, lon) {
                    throw NSError(domain: "loc", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: ideviceErrorString(e) ?? "?"])
                }
                return "OK"
            }
        }
    }

    func clearLocation() {
        run("Clear location…") {
            try Tunnel.locationSim { c in
                if let e = location_simulation_clear(c) {
                    throw NSError(domain: "loc", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: ideviceErrorString(e) ?? "?"])
                }
                return "OK"
            }
        }
    }

    // MARK: Notifications

    func postNotification() {
        let n = notificationName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        run("Post \(n)…") {
            try Tunnel.notificationProxy { c in
                if let e = notification_proxy_post(c, n) {
                    throw NSError(domain: "ntf", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: ideviceErrorString(e) ?? "?"])
                }
                return "OK"
            }
        }
    }

    // MARK: DeviceInfo

    func devHardware() {
        run("Hardware info…") {
            try Tunnel.remoteServer { server in
                var h: OpaquePointer?
                if let e = device_info_new(server, &h) {
                    throw NSError(domain: "di", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: ideviceErrorString(e) ?? "?"])
                }
                guard let h else { throw NSError(domain: "di", code: -1, userInfo: [NSLocalizedDescriptionKey: "nil"]) }
                defer { device_info_free(h) }
                var plist: UnsafeMutableRawPointer?
                if let e = device_info_hardware_information(h, &plist) {
                    throw NSError(domain: "hw", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: ideviceErrorString(e) ?? "?"])
                }
                defer { freePlist(plist) }
                return plistToString(plist)
            }
        }
    }

    func devNetwork() {
        run("Network info…") {
            try Tunnel.remoteServer { server in
                var h: OpaquePointer?
                if let e = device_info_new(server, &h) {
                    throw NSError(domain: "di", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: ideviceErrorString(e) ?? "?"])
                }
                guard let h else { throw NSError(domain: "di", code: -1, userInfo: [NSLocalizedDescriptionKey: "nil"]) }
                defer { device_info_free(h) }
                var plist: UnsafeMutableRawPointer?
                if let e = device_info_network_information(h, &plist) {
                    throw NSError(domain: "nw", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: ideviceErrorString(e) ?? "?"])
                }
                defer { freePlist(plist) }
                return plistToString(plist)
            }
        }
    }

    func devKernel() {
        run("Kernel name…") {
            try Tunnel.remoteServer { server in
                var h: OpaquePointer?
                if let e = device_info_new(server, &h) {
                    throw NSError(domain: "di", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: ideviceErrorString(e) ?? "?"])
                }
                guard let h else { throw NSError(domain: "di", code: -1, userInfo: [NSLocalizedDescriptionKey: "nil"]) }
                defer { device_info_free(h) }
                var name: UnsafeMutablePointer<CChar>?
                if let e = device_info_mach_kernel_name(h, &name) {
                    throw NSError(domain: "kn", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: ideviceErrorString(e) ?? "?"])
                }
                defer { if let name { idevice_string_free(name) } }
                return name.map { String(cString: $0) } ?? "<nil>"
            }
        }
    }

    func devProcesses() {
        run("Running processes…") {
            try Tunnel.remoteServer { server in
                var h: OpaquePointer?
                if let e = device_info_new(server, &h) {
                    throw NSError(domain: "di", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: ideviceErrorString(e) ?? "?"])
                }
                guard let h else { throw NSError(domain: "di", code: -1, userInfo: [NSLocalizedDescriptionKey: "nil"]) }
                defer { device_info_free(h) }
                var procs: UnsafeMutablePointer<UnsafeMutablePointer<IdeviceRunningProcess>?>?
                var count: UInt = 0
                if let e = device_info_running_processes(h, &procs, &count) {
                    throw NSError(domain: "dp", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: ideviceErrorString(e) ?? "?"])
                }
                defer { if let procs { device_info_running_processes_free(procs, count) } }
                var lines: [String] = ["pid\tname\tapp\tpath"]
                if let procs {
                    for i in 0..<Int(count) {
                        guard let p = procs[i] else { continue }
                        let pid = p.pointee.pid
                        let name = p.pointee.name.map { String(cString: $0) } ?? "?"
                        let app = p.pointee.is_application ? "app" : "sys"
                        lines.append("\(pid)\t\(name)\t\(app)")
                    }
                }
                return lines.joined(separator: "\n")
            }
        }
    }

    func devDirListing() {
        let path = filePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        run("List \(path)…") {
            try Tunnel.remoteServer { server in
                var h: OpaquePointer?
                if let e = device_info_new(server, &h) {
                    throw NSError(domain: "di", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: ideviceErrorString(e) ?? "?"])
                }
                guard let h else { throw NSError(domain: "di", code: -1, userInfo: [NSLocalizedDescriptionKey: "nil"]) }
                defer { device_info_free(h) }
                var entries: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
                var count: UInt = 0
                if let e = device_info_directory_listing(h, path, &entries, &count) {
                    throw NSError(domain: "ls", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: ideviceErrorString(e) ?? "?"])
                }
                defer { if let entries { device_info_string_array_free(entries, count) } }
                var out: [String] = []
                if let entries {
                    for i in 0..<Int(count) {
                        if let p = entries[i] { out.append(String(cString: p)) }
                    }
                }
                return out.joined(separator: "\n")
            }
        }
    }

    // MARK: Apps

    func appList() {
        output = "AppService listing not implemented here. Use Browse installed apps (InstallationProxy)."
        status = "Not available"
    }

    func appListViaInstallationProxy() {
        run("InstallationProxy browse…") {
            try JITEnableContext.shared.withFreshDebugTunnel(hostname: "StikDebugInstProxy") { adapter, handshake in
                var client: OpaquePointer?
                if let e = installation_proxy_connect_rsd(adapter, handshake, &client) {
                    throw NSError(domain: "ip", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: ideviceErrorString(e) ?? "?"])
                }
                guard let client else { throw NSError(domain: "ip", code: -1, userInfo: [NSLocalizedDescriptionKey: "nil"]) }
                defer { installation_proxy_client_free(client) }
                var result: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
                var count: Int = 0
                if let e = installation_proxy_browse(client, nil, &result, &count) {
                    throw NSError(domain: "ipb", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: ideviceErrorString(e) ?? "?"])
                }
                var out: [String] = []
                if let result {
                    for i in 0..<count {
                        out.append(plistToString(result[i]))
                    }
                }
                return out.joined(separator: "\n---\n")
            }
        }
    }

    // MARK: Processes

    func listProcesses() {
        run("List processes…") {
            let procs = try JITEnableContext.shared.fetchProcessList()
            return procs.map { entry -> String in
                let name = (entry["name"] as? String) ?? "?"
                let pid = (entry["pid"] as? Int) ?? 0
                let path = (entry["executablePath"] as? String) ?? ""
                return "\(pid)\t\(name)\t\(path)"
            }.joined(separator: "\n")
        }
    }

    func sendSignal() {
        guard let p = Int32(pid), let s = Int32(signal) else { output = "✗ pid/sig"; return }
        run("Signal \(s) → \(p)…") {
            try JITEnableContext.shared.sendSignal(s, toProcessWithPID: p)
            return "OK"
        }
    }

    func killProcess() {
        guard let p = Int32(pid) else { output = "✗ pid"; return }
        run("Kill \(p)…") {
            try JITEnableContext.shared.killProcess(withPID: p)
            return "OK"
        }
    }

    // MARK: Monitor

    func sysmontapSample() {
        run("Sysmontap sample…") {
            try Tunnel.remoteServer { server in
                var h: OpaquePointer?
                if let e = sysmontap_new(server, &h) {
                    throw NSError(domain: "smt", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: ideviceErrorString(e) ?? "?"])
                }
                guard let h else { throw NSError(domain: "smt", code: -1, userInfo: [NSLocalizedDescriptionKey: "nil"]) }
                defer { sysmontap_free(h) }

                var systemAttrs: [UnsafePointer<CChar>?] = []
                let systemNames = ["cpu_usage", "phys_footprint", "vm_pages"]
                let cStrs = systemNames.map { strdup($0) }
                defer { cStrs.forEach { free($0) } }
                for c in cStrs { systemAttrs.append(c) }

                var config = IdeviceSysmontapConfig()
                config.interval_ms = 500
                config.process_attributes = nil
                config.process_attributes_count = 0
                config.system_attributes = systemAttrs.withUnsafeBufferPointer { $0.baseAddress }
                config.system_attributes_count = UInt(systemAttrs.count)

                if let e = sysmontap_set_config(h, &config) {
                    throw NSError(domain: "cfg", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: ideviceErrorString(e) ?? "?"])
                }
                if let e = sysmontap_start(h) {
                    throw NSError(domain: "start", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: ideviceErrorString(e) ?? "?"])
                }
                defer { _ = sysmontap_stop(h) }

                var proc: UnsafeMutableRawPointer?
                var sys: UnsafeMutableRawPointer?
                var cpu: UnsafeMutableRawPointer?
                if let e = sysmontap_next_sample(h, &proc, &sys, &cpu) {
                    throw NSError(domain: "next", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: ideviceErrorString(e) ?? "?"])
                }
                defer { freePlist(proc); freePlist(sys); freePlist(cpu) }
                return "SYSTEM:\n\(plistToString(sys))\n\nCPU:\n\(plistToString(cpu))"
            }
        }
    }

    func energySample() {
        run("Energy sample…") {
            try Tunnel.remoteServer { server in
                var h: OpaquePointer?
                if let e = energy_monitor_new(server, &h) {
                    throw NSError(domain: "en", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: ideviceErrorString(e) ?? "?"])
                }
                guard let h else { throw NSError(domain: "en", code: -1, userInfo: [NSLocalizedDescriptionKey: "nil"]) }
                defer { energy_monitor_free(h) }

                var samples: UnsafeMutablePointer<IdeviceEnergySample>?
                var count: UInt = 0
                if let e = energy_monitor_sample_attributes(h, nil, 0, &samples, &count) {
                    throw NSError(domain: "es", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: ideviceErrorString(e) ?? "?"])
                }
                defer { if let samples { energy_monitor_samples_free(samples, count) } }
                var out: [String] = []
                if let samples {
                    for i in 0..<Int(count) {
                        let s = samples[i]
                        out.append("pid=\(s.pid) total=\(s.total_energy) cpu=\(s.cpu_energy) gpu=\(s.gpu_energy) net=\(s.networking_energy)")
                    }
                }
                return out.joined(separator: "\n")
            }
        }
    }

    func graphicsSample() {
        run("Graphics sample…") {
            try Tunnel.remoteServer { server in
                var h: OpaquePointer?
                if let e = graphics_new(server, &h) {
                    throw NSError(domain: "gr", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: ideviceErrorString(e) ?? "?"])
                }
                guard let h else { throw NSError(domain: "gr", code: -1, userInfo: [NSLocalizedDescriptionKey: "nil"]) }
                defer { graphics_free(h) }

                if let e = graphics_start_sampling(h, 1.0) {
                    throw NSError(domain: "start", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: ideviceErrorString(e) ?? "?"])
                }
                defer { _ = graphics_stop_sampling(h) }

                var sample: UnsafeMutablePointer<IdeviceGraphicsSample>?
                if let e = graphics_next_sample(h, &sample) {
                    throw NSError(domain: "next", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: ideviceErrorString(e) ?? "?"])
                }
                defer { if let sample { graphics_sample_free(sample) } }
                guard let s = sample else { return "<nil>" }
                let gpu = s.pointee.gpu_bundle_name.map { String(cString: $0) } ?? "?"
                return "fps=\(s.pointee.fps)\ngpu=\(gpu)\nalloc=\(s.pointee.alloc_system_memory)\ninuse=\(s.pointee.in_use_system_memory)"
            }
        }
    }
}

// MARK: - CString array helper

extension Array where Element == String {
    func withCStringArray<R>(_ body: (UnsafePointer<UnsafePointer<CChar>?>?, UInt) -> R) -> R {
        if isEmpty { return body(nil, 0) }
        let cStrings = map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        let ptrs: [UnsafePointer<CChar>?] = cStrings.map { UnsafePointer($0) }
        return ptrs.withUnsafeBufferPointer { buf in
            body(buf.baseAddress, UInt(ptrs.count))
        }
    }
}

// MARK: - View

struct DebugServerView: View {
    @StateObject private var m = DebugServerViewModel()
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Cmd").tag(0)
                Text("System").tag(1)
                Text("Power").tag(2)
                Text("Config").tag(3)
                Text("Location").tag(4)
                Text("Notif").tag(5)
                Text("Device").tag(6)
                Text("Files").tag(7)
                Text("Apps").tag(8)
                Text("Proc").tag(9)
                Text("Monitor").tag(10)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    content
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }

            outputPanel
        }
        .navigationTitle("idevice panel")
        .overlay(alignment: .topTrailing) {
            if m.busy { ProgressView().padding(12) }
        }
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case 0: cmdTab
        case 1: systemTab
        case 2: powerTab
        case 3: configTab
        case 4: locationTab
        case 5: notifTab
        case 6: deviceTab
        case 7: filesTab
        case 8: appsTab
        case 9: procTab
        case 10: monitorTab
        default: EmptyView()
        }
    }

    @ViewBuilder private var cmdTab: some View {
        TextField("command", text: $m.command, axis: .vertical)
            .font(.system(.body, design: .monospaced))
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .lineLimit(1...4)
            .textFieldStyle(.roundedBorder)
        Toggle("Shell mode (platform shell)", isOn: $m.shellMode)
        btn("Run command") { m.runRawCommand() }
        ForEach(m.history.prefix(5), id: \.self) { h in
            Button(h) { m.command = h; m.runRawCommand() }
                .font(.caption).buttonStyle(.bordered)
        }
    }

    @ViewBuilder private var systemTab: some View {
        TextField("MobileGestalt keys (comma-separated)", text: $m.mgKeys)
            .font(.system(.caption, design: .monospaced))
            .textFieldStyle(.roundedBorder)
        btn("MobileGestalt") { m.diagMobileGestalt() }
        btn("DiagnosticsRelay.all") { m.diagAll() }
        btn("IO Registry") { m.diagIoRegistry() }
        btn("GasGauge (battery)") { m.diagGasGauge() }
        btn("NAND info") { m.diagNand() }
        btn("WiFi info") { m.diagWifi() }
    }

    @ViewBuilder private var powerTab: some View {
        btn("Restart device", color: .orange) { m.powerRestart() }
        btn("Shutdown device", color: .red) { m.powerShutdown() }
        btn("Sleep device", color: .blue) { m.powerSleep() }
    }

    @ViewBuilder private var configTab: some View {
        HStack {
            btn("Dark") { m.configSetDark(true) }
            btn("Light") { m.configSetDark(false) }
            btn("Get style") { m.configGetStyle() }
        }
        HStack {
            btn("Motion ON") { m.configReduceMotion(true) }
            btn("Motion OFF") { m.configReduceMotion(false) }
        }
        HStack {
            btn("Transparency ON") { m.configReduceTransparency(true) }
            btn("Transparency OFF") { m.configReduceTransparency(false) }
        }
        HStack {
            btn("Borders ON") { m.configShowBorders(true) }
            btn("Borders OFF") { m.configShowBorders(false) }
        }
        HStack {
            btn("XS") { m.configSetTextSize("extra-small") }
            btn("M")  { m.configSetTextSize("medium") }
            btn("XL") { m.configSetTextSize("extra-large") }
        }
    }

    @ViewBuilder private var locationTab: some View {
        TextField("Latitude", text: $m.latitude).textFieldStyle(.roundedBorder)
        TextField("Longitude", text: $m.longitude).textFieldStyle(.roundedBorder)
        btn("Set location") { m.setLocation() }
        btn("Clear location", color: .red) { m.clearLocation() }
    }

    @ViewBuilder private var notifTab: some View {
        TextField("Notification name", text: $m.notificationName)
            .font(.system(.caption, design: .monospaced))
            .textFieldStyle(.roundedBorder)
        btn("Post notification") { m.postNotification() }
        ScrollView(.horizontal) {
            HStack {
                ForEach([
                    "com.apple.springboard.lockcomplete",
                    "com.apple.springboard.hasBlankedScreen",
                    "com.apple.springboard.attemptActivationUnlock",
                    "com.apple.mobile.lockdown.request_pair"
                ], id: \.self) { n in
                    Button(n) { m.notificationName = n }
                        .font(.caption2).buttonStyle(.bordered)
                }
            }
        }
    }

    @ViewBuilder private var deviceTab: some View {
        btn("Hardware info") { m.devHardware() }
        btn("Network info") { m.devNetwork() }
        btn("Kernel name") { m.devKernel() }
        btn("Running processes") { m.devProcesses() }
    }

    @ViewBuilder private var filesTab: some View {
        TextField("Path", text: $m.filePath)
            .font(.system(.caption, design: .monospaced))
            .textFieldStyle(.roundedBorder)
        btn("List directory") { m.devDirListing() }
        ScrollView(.horizontal) {
            HStack {
                ForEach(["/", "/var/mobile", "/var/mobile/Media",
                         "/var/containers/Bundle/Application",
                         "/var/mobile/Library"], id: \.self) { p in
                    Button(p) { m.filePath = p }
                        .font(.caption2).buttonStyle(.bordered)
                }
            }
        }
    }

    @ViewBuilder private var appsTab: some View {
        btn("Browse installed apps (InstallationProxy)") { m.appListViaInstallationProxy() }
    }

    @ViewBuilder private var procTab: some View {
        HStack {
            TextField("PID", text: $m.pid).keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
            TextField("Signal", text: $m.signal).keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
        }
        btn("List processes") { m.listProcesses() }
        HStack {
            btn("Send signal") { m.sendSignal() }
            btn("Kill process", color: .red) { m.killProcess() }
        }
        ScrollView(.horizontal) {
            HStack {
                ForEach(["9","15","18","19","1"], id: \.self) { s in
                    Button("SIG\(s)") { m.signal = s }
                        .font(.caption2).buttonStyle(.bordered)
                }
            }
        }
    }

    @ViewBuilder private var monitorTab: some View {
        btn("Sysmontap sample") { m.sysmontapSample() }
        btn("Energy sample") { m.energySample() }
        btn("Graphics sample") { m.graphicsSample() }
    }

    @ViewBuilder private var outputPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            HStack {
                Text(m.status).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = m.output
                } label: { Label("Copy", systemImage: "doc.on.doc").font(.caption) }
                Button {
                    m.output = ""; m.status = ""
                } label: { Label("Clear", systemImage: "trash").font(.caption) }
            }
            ScrollView {
                Text(m.output.isEmpty ? "No output yet." : m.output)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .foregroundStyle(m.output.isEmpty ? .secondary : .primary)
            }
            .frame(maxHeight: 240)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
    }

    @ViewBuilder
    private func btn(_ title: String, color: Color = .accentColor, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(color.opacity(0.15))
                .foregroundStyle(color)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(m.busy)
    }
}
