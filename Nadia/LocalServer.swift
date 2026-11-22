import Foundation
import Network

/// Minimal static HTTP server bound to the loopback interface.
/// Serves files from `root`, supports HEAD and Range requests (needed for video/audio on iOS).
/// A fixed port is used on purpose: localStorage (where RPG Maker MV keeps saves in a browser)
/// is tied to the origin, and the origin includes the port.
final class LocalServer {
    static let preferredPort: UInt16 = 38080

    private(set) var port: UInt16 = 0
    private var listener: NWListener?
    private let root: URL
    private let listenerQueue = DispatchQueue(label: "nadia.server.listener")
    private let connectionQueue = DispatchQueue(label: "nadia.server.connections", attributes: .concurrent)

    private static let mimeTypes: [String: String] = [
        "html": "text/html; charset=utf-8", "htm": "text/html; charset=utf-8",
        "js": "application/javascript; charset=utf-8", "json": "application/json",
        "css": "text/css; charset=utf-8", "txt": "text/plain; charset=utf-8",
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
        "svg": "image/svg+xml", "webp": "image/webp", "ico": "image/x-icon",
        "mp4": "video/mp4", "m4v": "video/mp4", "webm": "video/webm",
        "ogg": "audio/ogg", "m4a": "audio/mp4", "mp3": "audio/mpeg", "wav": "audio/wav",
        "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf", "otf": "font/otf"
    ]

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    // MARK: - Start

    func start(completion: @escaping (Result<UInt16, Error>) -> Void) {
        attempt(fixed: true, completion: completion)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func attempt(fixed: Bool, completion: @escaping (Result<UInt16, Error>) -> Void) {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback

        let l: NWListener
        do {
            if fixed, let p = NWEndpoint.Port(rawValue: LocalServer.preferredPort) {
                l = try NWListener(using: params, on: p)
            } else {
                l = try NWListener(using: params)
            }
        } catch {
            if fixed {
                attempt(fixed: false, completion: completion)
            } else {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
            return
        }

        var reported = false
        l.stateUpdateHandler = { [weak self, weak l] state in
            switch state {
            case .ready:
                guard !reported, let p = l?.port?.rawValue else { return }
                reported = true
                self?.port = p
                DispatchQueue.main.async { completion(.success(p)) }
            case .failed(let error):
                l?.cancel()
                guard !reported else { return }
                reported = true
                if fixed {
                    self?.attempt(fixed: false, completion: completion)
                } else {
                    DispatchQueue.main.async { completion(.failure(error)) }
                }
            default:
                break
            }
        }
        l.newConnectionHandler = { [weak self] connection in
            guard let self = self else { connection.cancel(); return }
            connection.start(queue: self.connectionQueue)
            self.receive(connection, buffer: Data())
        }
        listener = l
        l.start(queue: listenerQueue)
    }

    // MARK: - Request handling

    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, isComplete, error in
            guard let self = self else { c.cancel(); return }
            var buf = buffer
            if let data = data { buf.append(data) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[buf.startIndex..<end.lowerBound], as: UTF8.self)
                self.respond(to: c, head: head)
            } else if error != nil || isComplete || buf.count > 65536 {
                c.cancel()
            } else {
                self.receive(c, buffer: buf)
            }
        }
    }

    private func respond(to c: NWConnection, head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2 else { return sendSimple(c, 400, "Bad Request") }

        let method = String(parts[0])
        guard method == "GET" || method == "HEAD" else { return sendSimple(c, 405, "Method Not Allowed") }

        var headers = [String: String]()
        for line in lines.dropFirst() {
            if let idx = line.firstIndex(of: ":") {
                let key = line[..<idx].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        var path = String(parts[1])
        if let q = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = String(path[..<q]) }
        path = path.removingPercentEncoding ?? path

        var url = root
        for comp in path.split(separator: "/", omittingEmptySubsequences: true) {
            if comp == ".." { return sendSimple(c, 403, "Forbidden") }
            if comp == "." { continue }
            url.appendPathComponent(String(comp))
        }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            url.appendPathComponent("index.html")
        }
        url = url.standardizedFileURL
        guard url.path.hasPrefix(root.path) else { return sendSimple(c, 403, "Forbidden") }

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value else {
            return sendSimple(c, 404, "Not Found")
        }

        let mime = LocalServer.mimeTypes[url.pathExtension.lowercased()] ?? "application/octet-stream"
        let isHead = (method == "HEAD")

        var start: Int64 = 0
        var end: Int64 = size - 1
        var status = 200

        if size > 0, let range = headers["range"], range.hasPrefix("bytes=") {
            let spec = range.dropFirst(6).split(separator: ",").first.map(String.init) ?? ""
            let bits = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            if bits.count == 2 {
                if bits[0].isEmpty, let n = Int64(bits[1]) {
                    start = max(0, size - n)
                } else if let s = Int64(bits[0]) {
                    start = s
                    if let e = Int64(bits[1]) { end = min(e, size - 1) }
                }
                status = 206
            }
        }

        if size > 0 && (start > end || start >= size) {
            return sendSimple(c, 416, "Range Not Satisfiable")
        }

        let length: Int64 = size > 0 ? (end - start + 1) : 0
        var header = "HTTP/1.1 \(status) \(status == 206 ? "Partial Content" : "OK")\r\n"
        header += "Content-Type: \(mime)\r\n"
        header += "Content-Length: \(length)\r\n"
        header += "Accept-Ranges: bytes\r\n"
        if status == 206 { header += "Content-Range: bytes \(start)-\(end)/\(size)\r\n" }
        header += "Cache-Control: no-cache\r\nConnection: close\r\n\r\n"

        if isHead || length == 0 {
            c.send(content: Data(header.utf8), contentContext: .finalMessage, isComplete: true,
                   completion: .contentProcessed { _ in c.cancel() })
            return
        }

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return sendSimple(c, 500, "Cannot open file")
        }
        do { try handle.seek(toOffset: UInt64(start)) } catch {
            try? handle.close()
            return sendSimple(c, 500, "Cannot read file")
        }

        c.send(content: Data(header.utf8), contentContext: .defaultMessage, isComplete: false,
               completion: .contentProcessed { [weak self] err in
            if err != nil { try? handle.close(); c.cancel(); return }
            self?.stream(c, handle: handle, remaining: length)
        })
    }

    private func stream(_ c: NWConnection, handle: FileHandle, remaining: Int64) {
        var chunk: Data?
        autoreleasepool {
            chunk = try? handle.read(upToCount: Int(min(remaining, 512 * 1024)))
        }
        guard let data = chunk, !data.isEmpty else {
            try? handle.close()
            c.cancel()
            return
        }
        let left = remaining - Int64(data.count)
        let last = left <= 0
        c.send(content: data,
               contentContext: last ? .finalMessage : .defaultMessage,
               isComplete: last,
               completion: .contentProcessed { [weak self] err in
            if err != nil || last {
                try? handle.close()
                c.cancel()
                return
            }
            self?.stream(c, handle: handle, remaining: left)
        })
    }

    private func sendSimple(_ c: NWConnection, _ code: Int, _ text: String) {
        let body = text
        let response = "HTTP/1.1 \(code) \(text)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        c.send(content: Data(response.utf8), contentContext: .finalMessage, isComplete: true,
               completion: .contentProcessed { _ in c.cancel() })
    }
}
