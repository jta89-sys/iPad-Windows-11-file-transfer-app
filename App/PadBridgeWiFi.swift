import SwiftUI
import Foundation
import UniformTypeIdentifiers
import CryptoKit

private struct PadBridgeReceipt: Decodable {
    let filename: String
    let bytes: Int64
    let sha256: String
}

private struct PadBridgeFailure: LocalizedError {
    let explanation: String
    var errorDescription: String? { explanation }
}

private final class PadBridgeNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// Files from Files/iCloud are read through a coordinated, security-scoped URL.
// Stage one file at a time to keep memory usage bounded and hash its exact bytes.
private enum PadBridgeStager {
    static func stage(_ source: URL, to dest: URL) throws -> (hash: String, size: Int64) {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<(hash: String, size: Int64), Error>?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
            result = Result {
                try FileManager.default.copyItem(at: readable, to: dest)
                let handle = try FileHandle(forReadingFrom: dest)
                defer { try? handle.close() }
                var hasher = SHA256()
                var count: Int64 = 0
                while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
                    hasher.update(data: data)
                    count += Int64(data.count)
                }
                return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), count)
            }
        }
        if let error = coordinationError { throw error }
        guard let result else { throw PadBridgeFailure(explanation: "Unable to read the selected file.") }
        return try result.get()
    }
}

@MainActor
private final class PadBridgeWiFiModel: ObservableObject {
    @Published var address = ""
    @Published var pairingToken = ""
    @Published var status = "Run the PadBridge receiver on Windows, then enter its address and token."
    @Published var busy = false
    @Published var completed = 0
    @Published var total = 0
    @Published var sent: [String] = []

    private var job: Task<Void, Never>?
    private let redirects = PadBridgeNoRedirect()
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 3600
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: redirects, delegateQueue: nil)
    }()

    private func makeRequest(_ path: String) throws -> URLRequest {
        let raw = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URLComponents(string: raw),
              url.scheme == "http", let host = url.host,
              url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/",
              let port = url.port, (1...65535).contains(port),
              let root = url.url else {
            throw PadBridgeFailure(explanation: "Enter http://YOUR-PC-IP:8765 from the Windows receiver.")
        }
        let sections = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets = sections.compactMap { Int($0) }
        guard sections.count == 4, octets.count == 4,
              octets.allSatisfy({ (0...255).contains($0) }),
              octets[0] == 10 ||
              (octets[0] == 172 && (16...31).contains(octets[1])) ||
              (octets[0] == 192 && octets[1] == 168) ||
              (octets[0] == 169 && octets[1] == 254) else {
            throw PadBridgeFailure(explanation: "Enter your PC's private IPv4 address, not an internet address.")
        }
        let token = pairingToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw PadBridgeFailure(explanation: "Enter the receiver's pairing token.") }
        var request = URLRequest(url: root.appendingPathComponent(path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func validate(_ response: URLResponse, data: Data, code: Int) throws {
        guard let response = response as? HTTPURLResponse, response.statusCode == code else {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? String {
                throw PadBridgeFailure(explanation: error)
            }
            throw PadBridgeFailure(explanation: "Connection refused. Verify address, pairing token, and Windows firewall.")
        }
    }

    func test() {
        guard !busy else { return }
        busy = true
        job = Task {
            defer { busy = false; job = nil }
            do {
                let (data, response) = try await session.data(for: makeRequest("health"))
                try validate(response, data: data, code: 200)
                status = "Connected! Choose files to send to Windows."
            } catch {
                status = error.localizedDescription
            }
        }
    }

    func send(_ urls: [URL]) {
        guard !busy, !urls.isEmpty else { return }
        busy = true
        completed = 0
        total = urls.count
        job = Task {
            defer { busy = false; job = nil }
            do {
                let (healthData, healthResponse) = try await session.data(for: makeRequest("health"))
                try validate(healthResponse, data: healthData, code: 200)
                for url in urls {
                    try Task.checkCancellation()
                    let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    defer { try? FileManager.default.removeItem(at: staging) }
                    status = "Preparing \(url.lastPathComponent)…"
                    let file = try await Task.detached(priority: .userInitiated) {
                        try PadBridgeStager.stage(url, to: staging)
                    }.value
                    try Task.checkCancellation()
                    status = "Sending \(url.lastPathComponent) (\(completed + 1)/\(total))…"
                    var request = try makeRequest("upload")
                    request.httpMethod = "POST"
                    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                    request.setValue(String(file.size), forHTTPHeaderField: "Content-Length")
                    request.setValue(url.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "file",
                                     forHTTPHeaderField: "X-Filename")
                    request.setValue(file.hash, forHTTPHeaderField: "X-SHA256")
                    let (data, response) = try await session.upload(for: request, fromFile: staging)
                    try validate(response, data: data, code: 201)
                    let receipt = try JSONDecoder().decode(PadBridgeReceipt.self, from: data)
                    guard receipt.bytes == file.size && receipt.sha256 == file.hash else {
                        throw PadBridgeFailure(explanation: "Transfer integrity check failed.")
                    }
                    completed += 1
                    sent.insert("✓ \(receipt.filename) — SHA-256 verified", at: 0)
                }
                status = "Successfully sent \(completed) file(s)."
            } catch is CancellationError {
                status = "Cancelled. Already completed files remain on Windows."
            } catch {
                status = "\(error.localizedDescription) Completed: \(completed)/\(total)."
            }
        }
    }

    func cancel() { job?.cancel() }
}

struct PadBridgeWiFiView: View {
    @StateObject private var model = PadBridgeWiFiModel()
    @State private var picking = false

    var body: some View {
        Form {
            Section("Pair with Windows 11") {
                TextField("http://192.168.1.25:8765", text: $model.address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .disabled(model.busy)
                SecureField("Pairing token", text: $model.pairingToken)
                    .disabled(model.busy)
                Button("Test connection") { model.test() }.disabled(model.busy)
            }
            Section("Send files directly over Wi-Fi") {
                Button { picking = true } label: {
                    Label("Choose files and send", systemImage: "paperplane.fill")
                }.disabled(model.busy)
                if model.busy {
                    if model.total > 0 {
                        ProgressView(value: Double(model.completed), total: Double(model.total))
                    } else { ProgressView() }
                    Button("Cancel", role: .destructive) { model.cancel() }
                }
                Text(model.status).foregroundStyle(.secondary)
            }
            Section("Completed transfers") {
                if model.sent.isEmpty {
                    Text("Completed files will appear here.").foregroundStyle(.secondary)
                }
                ForEach(Array(model.sent.enumerated()), id: \.offset) { _, entry in
                    Text(entry)
                }
            }
            Section {
                Text("Both devices must use trusted private Wi-Fi. Transfers use HTTP, so file data and pairing token are not encrypted. Keep the app open until sending finishes.")
                    .font(.footnote)
            }
        }
        .navigationTitle("PadBridge Wi-Fi")
        .fileImporter(isPresented: $picking, allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let files): model.send(files)
            case .failure(let error): model.status = error.localizedDescription
            }
        }
    }
}
