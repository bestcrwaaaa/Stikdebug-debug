//
//  DebugServerView.swift
//  StikDebug — full idevice control panel
//

import SwiftUI
import UIKit
import idevice

// MARK: - helpers

private func plistToString(_ plist: UnsafeMutableRawPointer?) -> String {
    guard let plist else { return "<nil>" }
    var xml: UnsafeMutablePointer<CChar>?
    var len: UInt32 = 0
    let err = plist_to_xml(plist, &xml, &len)
    defer { if let xml { plist_mem_free(UnsafeMutableRawPointer(xml)) } }
    guard err.rawValue == 0, let xml else { return "<plist err \(err.rawValue)>" }
    return String(cString: xml)
}
private func freePlist(_ p: UnsafeMutableRawPointer?) { if let p { plist_free(p) } }

private func ideviceErrorString(_ err: UnsafeMutablePointer<IdeviceFfiError>?) -> String? {
    guard let err else { return nil }
    let msg = err.pointee.message.map { String(cString: $0) } ?? "code \(err.pointee.code)"
    idevice_error_free(err)
    return msg
}

private func makeFileDomain(_ raw: Int) -> IdeviceFileServiceDomain {
    switch raw {
    case 1: return IdeviceFileServiceDomainAppDataContainer
    case 2: return IdeviceFileServiceDomainAppGroupDataContainer
    case 3: return IdeviceFileServiceDomainTemporary
    case 5: return IdeviceFileServiceDomainSystemCrashLogs
    default: return IdeviceFileServiceDomainSystemCrashLogs
    }
}

private func previewBytes(_ data: Data) -> String {
    if let text = String(data: data.prefix(65536), encoding: .utf8) { return text }
    return data.prefix(4096).map { String(format: "%02x", $0) }.joined()
}

private func stringFromC(_ ptr: UnsafePointer<CChar>?) -> String? {
    guard let ptr else { return nil }
    return String(cString: ptr)
}

extension Array where Element == String {
    /// Returns true on success. `body(nil, 0)` for empty arrays.
    func withCStringArray<R>(_ body: (UnsafePointer<UnsafePointer<CChar>?>?, UInt) -> R) -> R {
        if isEmpty { return body(nil, 0) }
        let cStrings = map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        var ptrs: [UnsafePointer<CChar>?] = cStrings.map { UnsafePointer($0) }
        return ptrs.withUnsafeBufferPointer { buf in
            body(buf.baseAddress, UInt(ptrs.count))
        }
    }
}

// MARK: - tunnels

private enum Tunnel {
    static func remoteServer<T>(hostname: String = "StikDebugRemoteServer",
                                _ body: (OpaquePointer) throws -> T) throws -> T {
        try JITEnableContext.shared.withFreshDebugTunnel(hostname: hostname) { adapter, handshake in
            var server: OpaquePointer?
            if let e = remote_server_connect_rsd(adapter, handshake, &server) {
                throw NSError(domain: "StikDebug", code: Int(e.pointee.code),
                              userInfo: [NSLocalizedDescriptionKey: "remote_server: \(ideviceErrorString(e) ?? "?")"])
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
            if let e = diagnostics_relay_client_connect_rsd(adapter, handshake, &client) {
                throw NSError(domain: "StikDebug", code: Int(e.pointee.code),
                              userInfo: [NSLocalizedDescriptionKey: "diagnostics: \(ideviceErrorString(e) ?? "?")"])
            }
            guard let client else {
                throw NSError(domain: "StikDebug", code: -1, userInfo: [NSLocalizedDescriptionKey: "diagnostics nil"])
            }
            defer { diagnostics_relay_client_free(client) }
            return try body(client)
        }
    }

    static func config<T>(hostname: String = "StikDebugConfig",
                          _ body: (OpaquePointer) throws -> T) throws -> T {
        try JITEnableContext.shared.withFreshDebugTunnel(hostname: hostname) { adapter, handshake in
            var client: OpaquePointer?
            if let e = configuration_service_connect_rsd(adapter, handshake, &client) {
                throw NSError(domain: "StikDebug", code: Int(e.pointee.code),
                              userInfo: [NSLocalizedDescriptionKey: "config: \(ideviceErrorString(e) ?? "?")"])
            }
            guard let client else {
                throw NSError(domain: "StikDebug", code: -1, userInfo: [NSLocalizedDescriptionKey: "config nil"])
            }
            defer { configuration_service_free(client) }
            return try body(client)
        }
    }

    static func notificationProxy<T>(hostname: String = "StikDebugNotif",
                                     _ body: (OpaquePointer) throws -> T) throws -> T {
        try JITEnableContext.shared.withFreshDebugTunnel(hostname: hostname) { adapter, handshake in
            var client: OpaquePointer?
            if let e = notification_proxy_connect_rsd(adapter, handshake, &client) {
                throw NSError(domain: "StikDebug", code: Int(e.pointee.code),
                              userInfo: [NSLocalizedDescriptionKey: "notif: \(ideviceErrorString(e) ?? "?")"])
            }
            guard let client else {
                throw NSError(domain: "StikDebug", code: -1, userInfo: [NSLocalizedDescriptionKey: "notif nil"])
            }
            defer { notification_proxy_client_free(client) }
            return try body(client)
        }
    }

    static func locationSim<T>(hostname: String = "StikDebugLoc",
                               _ body: (OpaquePointer) throws -> T) throws -> T {
        try remoteServer(hostname: hostname) { server in
            var client: OpaquePointer?
            if let e = location_simulation_new(server, &client) {
                throw NSError(domain: "StikDebug", code: Int(e.pointee.code),
                              userInfo: [NSLocalizedDescriptionKey: "location: \(ideviceErrorString(e) ?? "?")"])
            }
            guard let client else {
                throw NSError(domain: "StikDebug", code: -1, userInfo: [NSLocalizedDescriptionKey: "location nil"])
            }
            defer { location_simulation_free(client) }
            return try body(client)
        }
    }

    static func processControl<T>(hostname: String = "StikDebugPC",
                                  _ body: (OpaquePointer) throws -> T) throws -> T {
        try remoteServer(hostname: hostname) { server in
            var h: OpaquePointer?
            if let e = process_control_new(server, &h) {
                throw NSError(domain: "StikDebug", code: Int(e.pointee.code),
                              userInfo: [NSLocalizedDescriptionKey: "process_control_new: \(ideviceErrorString(e) ?? "?")"])
            }
            guard let h else {
                throw NSError(domain: "StikDebug", code: -1, userInfo: [NSLocalizedDescriptionKey: "process_control nil"])
            }
            defer { process_control_free(h) }
            return try body(h)
        }
    }

    static func appService<T>(hostname: String = "StikDebugAS",
                              _ body: (OpaquePointer) throws -> T) throws -> T {
        try JITEnableContext.shared.withFreshDebugTunnel(hostname: hostname) { adapter, handshake in
            var h: OpaquePointer?
            if let e = app_service_connect_rsd(adapter, handshake, &h) {
                throw NSError(domain: "StikDebug", code: Int(e.pointee.code),
                              userInfo: [NSLocalizedDescriptionKey: "app_service_connect_rsd: \(ideviceErrorString(e) ?? "?")"])
            }
            guard let h else {
                throw NSError(domain: "StikDebug", code: -1, userInfo: [NSLocalizedDescriptionKey: "app_service nil"])
            }
            defer { app_service_free(h) }
            return try body(h)
        }
    }

    static func houseArrest<T>(bundleID: String, hostname: String = "StikDebugHA",
                               _ body: (OpaquePointer) throws -> T) throws -> T {
        try JITEnableContext.shared.withFreshDebugTunnel(hostname: hostname) { adapter, handshake in
            var ha: OpaquePointer?
            if let e = house_arrest_client_connect_rsd(adapter, handshake, &ha) {
                throw NSError(domain: "StikDebug", code: Int(e.pointee.code),
                              userInfo: [NSLocalizedDescriptionKey: "house_arrest: \(ideviceErrorString(e) ?? "?")"])
            }
            guard let ha else {
                throw NSError(domain: "StikDebug", code: -1, userInfo: [NSLocalizedDescriptionKey: "ha nil"])
            }
            defer { house_arrest_client_free(ha) }

            var afc: OpaquePointer?
            let vendErr = bundleID.withCString { house_arrest_vend_documents(ha, $0, &afc) }
            if let vendErr {
                throw NSError(domain: "StikDebug", code: Int(vendErr.pointee.code),
                              userInfo: [NSLocalizedDescriptionKey: "vend_documents: \(ideviceErrorString(vendErr) ?? "?")"])
            }
            guard let afc else {
                throw NSError(domain: "StikDebug", code: -1, userInfo: [NSLocalizedDescriptionKey: "afc nil"])
            }
            defer { afc_client_free(afc) }
            return try body(afc)
        }
    }

    static func fileService<T>(domain rawDomain: Int, bundleID: String, hostname: String = "StikDebugFS",
                               _ body: (OpaquePointer, OpaquePointer, UInt16) throws -> T) throws -> T {
        try JITEnableContext.shared.withFreshDebugTunnel(hostname: hostname) { adapter, handshake in
            var dataPort: UInt16 = 0
            var services: UnsafeMutablePointer<CRsdServiceArray>?
            if let e = rsd_get_services(handshake, &services) {
                throw NSError(domain: "StikDebug", code: Int(e.pointee.code),
                              userInfo: [NSLocalizedDescriptionKey: "rsd_get_services: \(ideviceErrorString(e) ?? "?")"])
            }
            defer { if let services { rsd_free_services(services) } }
            if let services {
                let arr = services.pointee
                for i in 0..<Int(arr.count) {
                    let svc = arr.services[i]
                    if let namePtr = svc.name,
                       String(cString: namePtr) == "com.apple.coredevice.fileservice.data" {
                        dataPort = svc.port
                        break
                    }
                }
            }
            guard dataPort != 0 else {
                throw NSError(domain: "StikDebug", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "fileservice.data port not found"])
            }

            var control: OpaquePointer?
            if let e = file_service_connect_rsd(adapter, handshake, &control) {
                throw NSError(domain: "StikDebug", code: Int(e.pointee.code),
                              userInfo: [NSLocalizedDescriptionKey: "file_service_connect_rsd: \(ideviceErrorString(e) ?? "?")"])
            }
            guard let control else {
                throw NSError(domain: "StikDebug", code: -1, userInfo: [NSLocalizedDescriptionKey: "file_service nil"])
            }
            defer { file_service_free(control) }

            let domain = makeFileDomain(rawDomain)
            let needsIdent = (domain.rawValue == 1 || domain.rawValue == 2)
            var sessionID: UnsafeMutablePointer<CChar>?
            let createErr = bundleID.withCString { bid in
                file_service_create_session(control, domain, needsIdent ? bid : nil, &sessionID)
            }
            if let createErr {
                throw NSError(domain: "StikDebug", code: Int(createErr.pointee.code),
                              userInfo: [NSLocalizedDescriptionKey: "create_session: \(ideviceErrorString(createErr) ?? "?")"])
            }
            defer { if let sessionID { idevice_string_free(sessionID) } }

            return try body(control, adapter, dataPort)
        }
    }

    /// DVT FileService with explicit raw UInt32 domain + optional identifier.
    /// `identifier == nil` → passes nil to create_session.
    static func fileServiceRaw<T>(
        domain: UInt32,
        identifier: String?,
        hostname: String = "StikDebugFSRaw",
        _ body: (OpaquePointer, OpaquePointer, UInt16) throws -> T
    ) throws -> T {
        try JITEnableContext.shared.withFreshDebugTunnel(hostname: hostname) { adapter, handshake in
            var dataPort: UInt16 = 0
            var services: UnsafeMutablePointer<CRsdServiceArray>?
            if let e = rsd_get_services(handshake, &services) {
                throw NSError(domain: "StikDebug", code: Int(e.pointee.code),
                              userInfo: [NSLocalizedDescriptionKey: "rsd_get_services: \(ideviceErrorString(e) ?? "?")"])
            }
            defer { if let services { rsd_free_services(services) } }
            if let services {
                let arr = services.pointee
                for i in 0..<Int(arr.count) {
                    let svc = arr.services[i]
                    if let namePtr = svc.name,
                       String(cString: namePtr) == "com.apple.coredevice.fileservice.data" {
                        dataPort = svc.port
                        break
                    }
                }
            }
            guard dataPort != 0 else {
                throw NSError(domain: "StikDebug", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "fileservice.data port not found"])
            }

            var control: OpaquePointer?
            if let e = file_service_connect_rsd(adapter, handshake, &control) {
                throw NSError(domain: "StikDebug", code: Int(e.pointee.code),
                              userInfo: [NSLocalizedDescriptionKey: "file_service_connect_rsd: \(ideviceErrorString(e) ?? "?")"])
            }
            guard let control else {
                throw NSError(domain: "StikDebug", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "file_service nil"])
            }
            defer { file_service_free(control) }

            // Known enum cases → safe path. Arbitrary raw → bitcast (C enum ABI is UInt32).
            let dom: IdeviceFileServiceDomain
            if let d = IdeviceFileServiceDomain(rawValue: domain) {
                dom = d
            } else {
                dom = unsafeBitCast(domain, to: IdeviceFileServiceDomain.self)
            }

            var sessionID: UnsafeMutablePointer<CChar>?
            var createErr: UnsafeMutablePointer<IdeviceFfiError>?
            if let ident = identifier {
                createErr = ident.withCString { ptr in
                    file_service_create_session(control, dom, ptr, &sessionID)
                }
            } else {
                createErr = file_service_create_session(control, dom, nil, &sessionID)
            }
            if let ce = createErr {
                throw NSError(domain: "StikDebug", code: Int(ce.pointee.code),
                              userInfo: [NSLocalizedDescriptionKey: "create_session: \(ideviceErrorString(ce) ?? "?")"])
            }
            defer { if let sessionID { idevice_string_free(sessionID) } }

            return try body(control, adapter, dataPort)
        }
    }
}

// MARK: - ViewModel

@MainActor
final class DebugServerViewModel: ObservableObject {

    @Published var output: String = ""
    @Published var status: String = ""
    @Published var busy = false

    @Published var command: String = "QStartNoAckMode"
    @Published var shellMode = false
    @Published var history: [String] = []

    @Published var pid: String = ""
    @Published var signal: String = "15"
    @Published var bundleID: String = "com.apple.mobilesafari"
    @Published var filePath: String = "/var/mobile/Library/Logs/CrashReporter"
    @Published var fileContent: String = ""
    @Published var dvtDomainRaw: Int = 5

    @Published var latitude: String = "55.7558"
    @Published var longitude: String = "37.6173"
    @Published var notificationName: String = "com.apple.springboard.lockcomplete"
    @Published var mgKeys: String = "ProductType,ProductVersion,BuildVersion,UniqueDeviceID,SerialNumber,HWModel,CPUArchitecture,MarketingName"

    // Raw DVT control (additive — existing fields untouched)
    @Published var dvtDomainText: String = "5"
    @Published var dvtIdentifierOverride: String = ""
    @Published var dvtUseNilIdentifier: Bool = true
    @Published var dvtPathRaw: String = "/var/mobile/Library/Logs/CrashReporter"

    // Process Control
    @Published var launchBundle: String = "com.apple.Preferences"
    @Published var launchEnv: String = ""
    @Published var launchArgs: String = ""
    @Published var startSuspended = false
    @Published var killExisting = false
    @Published var lastLaunchedPID: String = ""
    @Published var lastAuditToken: String = ""

    init() {
        // Global TCP timeout — prevents deadlocks in DVT / debug / os_trace reads
        idevice_set_global_timeout(5)
    }

    private func start(_ label: String) { busy = true; status = label; output = "" }

    private func finish(_ r: Result<String, Error>) {
        busy = false
        switch r {
        case .success(let t): output = t; status = "Done · \(t.utf8.count) byte(s)"
        case .failure(let e): output = "✗ \(e.localizedDescription)"; status = "Failed"
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
                case .success(let t): self.output = t; self.status = "OK"
                case .failure(let e): self.output = "✗ \(e.localizedDescription)"; self.status = "Failed"
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
            try Tunnel.diagnostics { c in
                var plist: UnsafeMutableRawPointer?
                var cKeys: [UnsafePointer<CChar>?] = keys.map { strdup($0).map { UnsafePointer($0) } }
                defer { cKeys.forEach { if let p = $0 { free(UnsafeMutablePointer(mutating: p)) } } }
                let arrPtr = cKeys.withUnsafeBufferPointer { $0.baseAddress }
                if let e = diagnostics_relay_client_mobilegestalt(c, arrPtr, UInt(cKeys.count), &plist) {
                    throw NSError(domain: "mg", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: ideviceErrorString(e) ?? "?"])
                }
                defer { freePlist(plist) }
                return plistToString(plist)
            }
        }
    }

    func diagAll() {
        run("DiagnosticsRelay.all…") {
            try Tunnel.diagnostics { c in
                var p: UnsafeMutableRawPointer?
                if let e = diagnostics_relay_client_all(c, &p) {
                    throw NSError(domain: "all", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: ideviceErrorString(e) ?? "?"])
                }
                defer { freePlist(p) }
                return plistToString(p)
            }
        }
    }

    func diagIoRegistry() {
        run("IO Registry…") {
            try Tunnel.diagnostics { c in
                var p: UnsafeMutableRawPointer?
                if let e = diagnostics_relay_client_ioregistry(c, nil, nil, nil, &p) {
                    throw NSError(domain: "ior", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: ideviceErrorString(e) ?? "?"])
                }
                defer { freePlist(p) }
                return plistToString(p)
            }
        }
    }

    func diagGasGauge() {
        run("GasGauge…") {
            try Tunnel.diagnostics { c in
                var p: UnsafeMutableRawPointer?
                if let e = diagnostics_relay_client_gasguage(c, &p) {
                    throw NSError(domain: "gg", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: ideviceErrorString(e) ?? "?"])
                }
                defer { freePlist(p) }
                return plistToString(p)
            }
        }
    }

    func diagNand() {
        run("NAND…") {
            try Tunnel.diagnostics { c in
                var p: UnsafeMutableRawPointer?
                if let e = diagnostics_relay_client_nand(c, &p) {
                    throw NSError(domain: "nand", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: ideviceErrorString(e) ?? "?"])
                }
                defer { freePlist(p) }
                return plistToString(p)
            }
        }
    }

    func diagWifi() {
        run("WiFi…") {
            try Tunnel.diagnostics { c in
                var p: UnsafeMutableRawPointer?
                if let e = diagnostics_relay_client_wifi(c, &p) {
                    throw NSError(domain: "wifi", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: ideviceErrorString(e) ?? "?"])
                }
                defer { freePlist(p) }
                return plistToString(p)
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
                var s: IdeviceUserInterfaceStyle = IdeviceUserInterfaceStyleLight
                if let e = configuration_service_get_user_interface_style(c, &s) {
                    throw NSError(domain: "cfg", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: ideviceErrorString(e) ?? "?"])
                }
                return "style: \(s.rawValue == 1 ? "Dark" : "Light")"
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
                if let e = size.withCString({ configuration_service_set_device_text_size(c, $0) }) {
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

    // MARK: Notifications (proxy)

    func postNotification() {
        let n = notificationName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        run("Post \(n)…") {
            try Tunnel.notificationProxy { c in
                if let e = n.withCString({ notification_proxy_post(c, $0) }) {
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
                var p: UnsafeMutableRawPointer?
                if let e = device_info_hardware_information(h, &p) {
                    throw NSError(domain: "hw", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: ideviceErrorString(e) ?? "?"])
                }
                defer { freePlist(p) }
                return plistToString(p)
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
                var p: UnsafeMutableRawPointer?
                if let e = device_info_network_information(h, &p) {
                    throw NSError(domain: "nw", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: ideviceErrorString(e) ?? "?"])
                }
                defer { freePlist(p) }
                return plistToString(p)
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
                var lines: [String] = ["pid\tname\ttype"]
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

    // MARK: Files (DVT)

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
                if let e = path.withCString({ device_info_directory_listing(h, $0, &entries, &count) }) {
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
                return out.isEmpty ? "<empty>" : out.joined(separator: "\n")
            }
        }
    }

    func readFileDVT() {
        let path = filePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { output = "✗ empty path"; return }
        let domainRaw = dvtDomainRaw
        let bundle = bundleID
        run("DVT read \(path)…") {
            try Tunnel.fileService(domain: domainRaw, bundleID: bundle) { control, adapter, dataPort in
                var data: UnsafeMutablePointer<UInt8>?
                var len: UInt = 0
                if let e = path.withCString({ file_service_retrieve_file(control, $0, adapter, dataPort, &data, &len) }) {
                    throw NSError(domain: "fs", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: "retrieve_file: \(ideviceErrorString(e) ?? "?")"])
                }
                defer { if let data { idevice_data_free(data, len) } }
                guard let data, len > 0 else { return "<empty>" }
                return previewBytes(Data(bytes: data, count: Int(len)))
            }
        }
    }

    func proposeEmptyFileDVT() {
        let path = filePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { output = "✗ empty path"; return }
        let domainRaw = dvtDomainRaw
        let bundle = bundleID
        run("DVT create \(path)…") {
            try Tunnel.fileService(domain: domainRaw, bundleID: bundle) { control, _, _ in
                let now = Int64(Date().timeIntervalSince1970)
                if let e = path.withCString({
                    file_service_propose_empty_file(control, $0, 0o644, 501, 501, now, now)
                }) {
                    throw NSError(domain: "fs", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: "propose: \(ideviceErrorString(e) ?? "?")"])
                }
                return "OK — file created"
            }
        }
    }

    func readFileAFC() {
        let path = filePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { output = "✗ empty path"; return }
        let bundle = bundleID
        run("AFC read \(path)…") {
            try Tunnel.houseArrest(bundleID: bundle) { afc in
                var fh: OpaquePointer?
                if let e = path.withCString({ afc_file_open(afc, $0, AfcRdOnly, &fh) }) {
                    throw NSError(domain: "afc", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: "open: \(ideviceErrorString(e) ?? "?")"])
                }
                guard let fh else { throw NSError(domain: "afc", code: -1, userInfo: [NSLocalizedDescriptionKey: "fh nil"]) }
                defer { _ = afc_file_close(fh) }

                var dataPtr: UnsafeMutablePointer<UInt8>?
                var len: Int = 0
                if let e = afc_file_read_entire(fh, &dataPtr, &len) {
                    throw NSError(domain: "afc", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: "read: \(ideviceErrorString(e) ?? "?")"])
                }
                defer { if let dataPtr { afc_file_read_data_free(dataPtr, len) } }
                guard let dataPtr, len > 0 else { return "<empty>" }
                return previewBytes(Data(bytes: dataPtr, count: len))
            }
        }
    }

    func writeFileAFC() {
        let path = filePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { output = "✗ empty path"; return }
        let bundle = bundleID
        let content = fileContent
        run("AFC write \(path)…") {
            try Tunnel.houseArrest(bundleID: bundle) { afc in
                var fh: OpaquePointer?
                if let e = path.withCString({ afc_file_open(afc, $0, AfcWr, &fh) }) {
                    idevice_error_free(e)
                    fh = nil
                    if let e2 = path.withCString({ afc_file_open(afc, $0, AfcWrOnly, &fh) }) {
                        throw NSError(domain: "afc", code: Int(e2.pointee.code),
                                      userInfo: [NSLocalizedDescriptionKey: "open: \(ideviceErrorString(e2) ?? "?")"])
                    }
                }
                guard let fh else { throw NSError(domain: "afc", code: -1, userInfo: [NSLocalizedDescriptionKey: "fh nil"]) }
                defer { _ = afc_file_close(fh) }

                let data = Data(content.utf8)
                if data.isEmpty { return "OK — empty write" }

                var writeErr: UnsafeMutablePointer<IdeviceFfiError>?
                data.withUnsafeBytes { rawBuf in
                    let ptr = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self)
                    writeErr = afc_file_write(fh, ptr, data.count)
                }
                if let writeErr {
                    throw NSError(domain: "afc", code: Int(writeErr.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: "write: \(ideviceErrorString(writeErr) ?? "?")"])
                }
                return "OK — wrote \(data.count) bytes"
            }
        }
    }

    // MARK: Apps (InstallationProxy)

    func appList() {
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
                    for i in 0..<count { out.append(plistToString(result[i])) }
                }
                return out.joined(separator: "\n---\n")
            }
        }
    }

    // MARK: Processes (JITEnableContext)

    func listProcesses() {
        run("List processes…") {
            let procs = try JITEnableContext.shared.fetchProcessList()
            return procs.map { e -> String in
                let name = (e["name"] as? String) ?? "?"
                let pid = (e["pid"] as? Int) ?? 0
                let path = (e["executablePath"] as? String) ?? ""
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

    // MARK: Process Control (process_control_*)

    func pcLaunchApp() {
        let bundle = launchBundle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundle.isEmpty else { output = "✗ empty bundle"; return }
        let env = launchEnv.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let args = launchArgs.split(separator: "\n").map { String($0) }.filter { !$0.isEmpty }
        let susp = startSuspended
        let killEx = killExisting
        run("process_control launch \(bundle)…") {
            try Tunnel.processControl { h in
                var pidOut: UInt64 = 0
                let err: UnsafeMutablePointer<IdeviceFfiError>? = env.withCStringArray { envPtr, envCount in
                    args.withCStringArray { argPtr, argCount in
                        bundle.withCString { bid in
                            process_control_launch_app(
                                h, bid,
                                envPtr, envCount,
                                argPtr, argCount,
                                susp, killEx,
                                &pidOut
                            )
                        }
                    }
                }
                if let err {
                    throw NSError(domain: "pc", code: Int(err.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: "launch: \(ideviceErrorString(err) ?? "?")"])
                }
                self.await_setLastPID(pidOut)
                return "OK — launched pid \(pidOut)"
            }
        }
    }

    nonisolated private func await_setLastPID(_ pid: UInt64) {
        Task { @MainActor [weak self] in
            self?.lastLaunchedPID = String(pid)
        }
    }

    nonisolated private func await_setLastAuditToken(_ hex: String) {
        Task { @MainActor [weak self] in
            self?.lastAuditToken = hex
        }
    }

    func pcKillApp() {
        guard let p = UInt64(pid) else { output = "✗ pid"; return }
        run("process_control kill \(p)…") {
            try Tunnel.processControl { h in
                if let e = process_control_kill_app(h, p) {
                    throw NSError(domain: "pc", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: "kill: \(ideviceErrorString(e) ?? "?")"])
                }
                return "OK — killed pid \(p)"
            }
        }
    }

    func pcDisableMemoryLimit() {
        guard let p = UInt64(pid) else { output = "✗ pid"; return }
        run("disable memory limit \(p)…") {
            try Tunnel.processControl { h in
                if let e = process_control_disable_memory_limit(h, p) {
                    throw NSError(domain: "pc", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: "disable_limit: \(ideviceErrorString(e) ?? "?")"])
                }
                return "OK — limit disabled for pid \(p)"
            }
        }
    }

    // MARK: AppService

    func asLaunchApp() {
        let bundle = launchBundle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundle.isEmpty else { output = "✗ empty bundle"; return }
        let args = launchArgs.split(separator: "\n").map { String($0) }.filter { !$0.isEmpty }
        let susp = startSuspended
        let killEx = killExisting
        run("app_service launch \(bundle)…") {
            try Tunnel.appService { h in
                var response: UnsafeMutablePointer<LaunchResponseC>?
                let err: UnsafeMutablePointer<IdeviceFfiError>? = args.withCStringArray { argPtr, argCount in
                    bundle.withCString { bid in
                        app_service_launch_app(
                            h, bid,
                            argPtr, argCount,
                            killEx ? 1 : 0,
                            susp ? 1 : 0,
                            nil,
                            &response
                        )
                    }
                }
                if let err {
                    throw NSError(domain: "as", code: Int(err.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: "launch: \(ideviceErrorString(err) ?? "?")"])
                }
                defer { if let response { app_service_free_launch_response(response) } }
                guard let response else { return "<nil>" }
                let pid = response.pointee.pid
                let path = response.pointee.executable_url.map { String(cString: $0) } ?? "?"
                self.await_setLastPID(UInt64(pid))
                return "OK — pid \(pid)\nurl: \(path)"
            }
        }
    }

    func asSendSignal() {
        guard let p = UInt32(pid) else { output = "✗ pid"; return }
        guard let s = UInt32(signal) else { output = "✗ signal"; return }
        run("app_service signal \(s) → \(p)…") {
            try Tunnel.appService { h in
                var response: UnsafeMutablePointer<SignalResponseC>?
                if let e = app_service_send_signal(h, p, s, &response) {
                    throw NSError(domain: "as", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: "signal: \(ideviceErrorString(e) ?? "?")"])
                }
                defer { if let response { app_service_free_signal_response(response) } }
                guard let response else { return "OK (no response)" }
                let path = response.pointee.executable_url.map { String(cString: $0) } ?? "?"
                return "OK — pid \(response.pointee.pid), signal \(response.pointee.signal)\nurl: \(path)"
            }
        }
    }

    func asUninstall() {
        let bundle = launchBundle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundle.isEmpty else { output = "✗ empty bundle"; return }
        run("uninstall \(bundle)…") {
            try Tunnel.appService { h in
                if let e = bundle.withCString({ app_service_uninstall_app(h, $0) }) {
                    throw NSError(domain: "as", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: "uninstall: \(ideviceErrorString(e) ?? "?")"])
                }
                return "OK — uninstalled \(bundle)"
            }
        }
    }

    // MARK: Live — Notifications

    func liveNotificationsOne() {
        run("Notifications next…") {
            try Tunnel.remoteServer(hostname: "StikDebugLiveNotif") { server in
                var h: OpaquePointer?
                if let e = notifications_new(server, &h) {
                    throw NSError(domain: "ntf", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: "notifications_new: \(ideviceErrorString(e) ?? "?")"])
                }
                guard let h else { throw NSError(domain: "ntf", code: -1, userInfo: [NSLocalizedDescriptionKey: "nil"]) }
                defer { notifications_free(h) }
                if let e = notifications_start(h) {
                    throw NSError(domain: "ntf", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: "start: \(ideviceErrorString(e) ?? "?")"])
                }
                defer { _ = notifications_stop(h) }

                var info: UnsafeMutablePointer<IdeviceNotificationInfo>?
                if let e = notifications_get_next(h, &info) {
                    throw NSError(domain: "ntf", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: "next: \(ideviceErrorString(e) ?? "?")"])
                }
                defer { if let info { notifications_info_free(info) } }
                guard let info else { return "<nil>" }
                let p = info.pointee
                let type = stringFromC(p.notification_type) ?? "?"
                let exec = stringFromC(p.exec_name) ?? "?"
                let app = stringFromC(p.app_name) ?? "?"
                let state = stringFromC(p.state_description) ?? "?"
                return "type: \(type)\npid: \(p.pid)\nexec: \(exec)\napp: \(app)\nstate: \(state)"
            }
        }
    }

    // MARK: Live — Network

    func liveNetworkOne() {
        run("Network next…") {
            try Tunnel.remoteServer(hostname: "StikDebugLiveNet") { server in
                var h: OpaquePointer?
                if let e = network_monitor_new(server, &h) {
                    throw NSError(domain: "net", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: "network_monitor_new: \(ideviceErrorString(e) ?? "?")"])
                }
                guard let h else { throw NSError(domain: "net", code: -1, userInfo: [NSLocalizedDescriptionKey: "nil"]) }
                defer { network_monitor_free(h) }
                if let e = network_monitor_start(h) {
                    throw NSError(domain: "net", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: "start: \(ideviceErrorString(e) ?? "?")"])
                }
                defer { _ = network_monitor_stop(h) }

                var event: UnsafeMutablePointer<IdeviceNetworkEvent>?
                if let e = network_monitor_next_event(h, &event) {
                    throw NSError(domain: "net", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: "next: \(ideviceErrorString(e) ?? "?")"])
                }
                defer { if let event { network_monitor_event_free(event) } }
                guard let event else { return "<nil>" }
                let e = event.pointee
                let iface = stringFromC(e.interface_name) ?? "?"
                let localAddr = stringFromC(e.local_addr.addr) ?? "?"
                let remoteAddr = stringFromC(e.remote_addr.addr) ?? "?"
                return """
                type: \(e.event_type.rawValue) (\(e.event_type))
                iface: \(iface) idx=\(e.interface_index)
                pid: \(e.pid)
                local: \(localAddr):\(e.local_addr.port)
                remote: \(remoteAddr):\(e.remote_addr.port)
                rx: \(e.rx_packets) pkts / \(e.rx_bytes) b
                tx: \(e.tx_packets) pkts / \(e.tx_bytes) b
                rtt: min=\(e.min_rtt) avg=\(e.avg_rtt)
                retx: \(e.tx_retx)
                """
            }
        }
    }

    // MARK: Live — OS Trace

    func liveOSTraceOne() {
        run("OS Trace next…") {
            try JITEnableContext.shared.withFreshDebugTunnel(hostname: "StikDebugLiveTrace") { adapter, handshake in
                var client: OpaquePointer?
                if let e = os_trace_relay_connect_rsd(adapter, handshake, &client) {
                    throw NSError(domain: "trace", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: "connect: \(ideviceErrorString(e) ?? "?")"])
                }
                guard let client else {
                    throw NSError(domain: "trace", code: -1, userInfo: [NSLocalizedDescriptionKey: "client nil"])
                }
                // start_trace CONSUMES client — do NOT free client afterwards
                var receiver: OpaquePointer?
                if let e = os_trace_relay_start_trace(client, &receiver, nil) {
                    // if start failed, we still own client
                    os_trace_relay_free(client)
                    throw NSError(domain: "trace", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: "start_trace: \(ideviceErrorString(e) ?? "?")"])
                }
                guard let receiver else {
                    throw NSError(domain: "trace", code: -1, userInfo: [NSLocalizedDescriptionKey: "receiver nil"])
                }
                defer { os_trace_relay_receiver_free(receiver) }

                var log: UnsafeMutablePointer<OsTraceLog>?
                if let e = os_trace_relay_next(receiver, &log) {
                    throw NSError(domain: "trace", code: Int(e.pointee.code),
                                  userInfo: [NSLocalizedDescriptionKey: "next: \(ideviceErrorString(e) ?? "?")"])
                }
                defer { if let log { os_trace_relay_free_log(log) } }
                guard let log else { return "<nil>" }
                let l = log.pointee
                let image = stringFromC(l.image_name) ?? "?"
                let file = stringFromC(l.filename) ?? "?"
                let msg = stringFromC(l.message) ?? "?"
                let sub = l.label.flatMap { stringFromC($0.pointee.subsystem) } ?? ""
                let cat = l.label.flatMap { stringFromC($0.pointee.category) } ?? ""
                return """
                ts: \(l.timestamp)
                pid: \(l.pid) tid: \(l.thread_id)
                level: \(l.level)
                image: \(image) (\(l.image_offset))
                file: \(file)
                label: \(sub)/\(cat)
                msg: \(msg)
                """
            }
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

                let names = ["cpu_usage", "phys_footprint", "vm_pages"]
                var cStrs: [UnsafeMutablePointer<CChar>?] = names.map { strdup($0) }
                defer { cStrs.forEach { if let p = $0 { free(p) } } }
                var ptrs: [UnsafePointer<CChar>?] = cStrs.map { $0.map { UnsafePointer($0) } }

                var config = IdeviceSysmontapConfig()
                config.interval_ms = 500
                config.process_attributes = nil
                config.process_attributes_count = 0
                config.system_attributes = ptrs.withUnsafeBufferPointer { $0.baseAddress }
                config.system_attributes_count = UInt(ptrs.count)

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
                Text("Process").tag(9)
                Text("Monitor").tag(10)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) { content }
                    .padding(.horizontal, 12).padding(.top, 8)
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
        case 9: processTab
        case 10: monitorTab
        default: EmptyView()
        }
    }

    @ViewBuilder private var cmdTab: some View {
        TextField("command", text: $m.command, axis: .vertical)
            .font(.system(.body, design: .monospaced))
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .lineLimit(1...4).textFieldStyle(.roundedBorder)
        Toggle("Shell mode (platform shell)", isOn: $m.shellMode)
        btn("Run command") { m.runRawCommand() }
        ForEach(m.history.prefix(5), id: \.self) { h in
            Button(h) { m.command = h; m.runRawCommand() }
                .font(.caption).buttonStyle(.bordered)
        }
    }

    @ViewBuilder private var systemTab: some View {
        TextField("MobileGestalt keys (comma-separated)", text: $m.mgKeys)
            .font(.system(.caption, design: .monospaced)).textFieldStyle(.roundedBorder)
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
            .font(.system(.caption, design: .monospaced)).textFieldStyle(.roundedBorder)
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
        TextField("Bundle ID (for AFC / App domain)", text: $m.bundleID)
            .font(.system(.caption, design: .monospaced)).textFieldStyle(.roundedBorder)
        TextField("Path", text: $m.filePath)
            .font(.system(.caption, design: .monospaced)).textFieldStyle(.roundedBorder)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(["/", "/var/mobile", "/var/mobile/Media",
                         "/var/mobile/Library/Logs/CrashReporter",
                         "/var/containers/Bundle/Application",
                         "/private/etc"], id: \.self) { p in
                    Button(p) { m.filePath = p }
                        .font(.caption2).buttonStyle(.bordered)
                }
            }
        }
        HStack {
            Text("DVT domain:").font(.caption).foregroundStyle(.secondary)
            Picker("", selection: $m.dvtDomainRaw) {
                Text("AppData").tag(1)
                Text("AppGroup").tag(2)
                Text("Temp").tag(3)
                Text("CrashLogs").tag(5)
            }.pickerStyle(.segmented)
        }
        btn("List directory (DVT)") { m.devDirListing() }
        btn("Read file (DVT)", color: .green) { m.readFileDVT() }
        btn("Create empty file (DVT)", color: .purple) { m.proposeEmptyFileDVT() }
        Divider().padding(.vertical, 4)
        Text("Advanced (raw domain + identifier)").font(.caption).foregroundStyle(.secondary)
        HStack {
            TextField("Domain #", text: $m.dvtDomainText)
                .keyboardType(.numbersAndPunctuation)
                .font(.system(.caption, design: .monospaced))
                .textFieldStyle(.roundedBorder)
            TextField("Identifier (override)", text: $m.dvtIdentifierOverride)
                .font(.system(.caption, design: .monospaced))
                .textFieldStyle(.roundedBorder)
        }
        Toggle("Pass nil identifier", isOn: $m.dvtUseNilIdentifier)
            .font(.caption)
        TextField("Path (raw)", text: $m.dvtPathRaw)
            .font(.system(.caption, design: .monospaced))
            .textFieldStyle(.roundedBorder)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(["0", "4", "6", "7"], id: \.self) { n in
                    Button("dom=\(n)") { m.dvtDomainText = n }
                        .font(.caption2).buttonStyle(.bordered)
                }
                ForEach(["/private/etc/hosts", "/private/etc/passwd",
                         "/private/var/mobile/Library/Preferences"],
                        id: \.self) { p in
                    Button(p) { m.dvtPathRaw = p }
                        .font(.caption2).buttonStyle(.bordered)
                }
            }
        }
        btn("Read file (DVT raw)", color: .green) { m.readFileDVTRaw() }
        btn("Create empty (DVT raw)", color: .purple) { m.proposeEmptyFileDVTRaw() }
        Divider().padding(.vertical, 4)
        Text("AFC (own container only)").font(.caption).foregroundStyle(.secondary)
        btn("Read file (AFC)", color: .blue) { m.readFileAFC() }
        TextField("Content to write (AFC)", text: $m.fileContent, axis: .vertical)
            .font(.system(.caption, design: .monospaced))
            .textFieldStyle(.roundedBorder)
            .lineLimit(2...6)
        btn("Write file (AFC)", color: .orange) { m.writeFileAFC() }
    }

    @ViewBuilder private var appsTab: some View {
        btn("Browse installed apps") { m.appList() }
    }

    @ViewBuilder private var processTab: some View {
        // Common fields
        TextField("Bundle ID", text: $m.launchBundle)
            .font(.system(.caption, design: .monospaced)).textFieldStyle(.roundedBorder)
        HStack {
            TextField("PID", text: $m.pid).keyboardType(.numberPad).textFieldStyle(.roundedBorder)
            TextField("Signal", text: $m.signal).keyboardType(.numberPad).textFieldStyle(.roundedBorder)
        }

        // launch options
        TextField("Env (KEY=VAL per line)", text: $m.launchEnv, axis: .vertical)
            .font(.system(.caption, design: .monospaced)).textFieldStyle(.roundedBorder)
            .lineLimit(2...6)
        TextField("Arguments (one per line)", text: $m.launchArgs, axis: .vertical)
            .font(.system(.caption, design: .monospaced)).textFieldStyle(.roundedBorder)
            .lineLimit(1...4)
        HStack {
            Toggle("start_suspended", isOn: $m.startSuspended)
            Toggle("kill_existing", isOn: $m.killExisting)
        }

        // process_control
        Text("process_control").font(.caption).foregroundStyle(.secondary)
        btn("Launch (PC)", color: .green) { m.pcLaunchApp() }
        btn("Kill PID (PC)", color: .red) { m.pcKillApp() }
        btn("Disable memory limit (PC)", color: .orange) { m.pcDisableMemoryLimit() }

        // app_service
        Divider().padding(.vertical, 4)
        Text("app_service").font(.caption).foregroundStyle(.secondary)
        btn("Launch (AS)", color: .green) { m.asLaunchApp() }
        btn("Send signal (AS)", color: .red) { m.asSendSignal() }
        btn("Uninstall app (AS)", color: .pink) { m.asUninstall() }

        // JITEnableContext (classic)
        Divider().padding(.vertical, 4)
        Text("jit_enable").font(.caption).foregroundStyle(.secondary)
        btn("List processes") { m.listProcesses() }
        btn("Send signal (JIT)") { m.sendSignal() }
        btn("Kill process (JIT)", color: .red) { m.killProcess() }

        // live
        Divider().padding(.vertical, 4)
        Text("live (one-shot, may block up to 5s)").font(.caption).foregroundStyle(.secondary)
        btn("Notifications: next", color: .blue) { m.liveNotificationsOne() }
        btn("Network: next", color: .blue) { m.liveNetworkOne() }
        btn("OS Trace: next", color: .blue) { m.liveOSTraceOne() }

        if !m.lastLaunchedPID.isEmpty {
            Text("last launched pid: \(m.lastLaunchedPID)")
                .font(.caption).foregroundStyle(.secondary)
        }
        if !m.lastAuditToken.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("audit_token (\(m.lastAuditToken.count / 2) bytes)")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = m.lastAuditToken
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc").font(.caption)
                    }
                    .buttonStyle(.bordered)
                }
                Text(m.lastAuditToken)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(4)
            }
            .padding(.vertical, 4)
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
                Button { UIPasteboard.general.string = m.output }
                    label: { Label("Copy", systemImage: "doc.on.doc").font(.caption) }
                Button { m.output = ""; m.status = "" }
                    label: { Label("Clear", systemImage: "trash").font(.caption) }
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
                .padding(.vertical, 10).padding(.horizontal, 12)
                .background(color.opacity(0.15))
                .foregroundStyle(color)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(m.busy)
    }
}
