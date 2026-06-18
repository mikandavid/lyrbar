import Foundation
import Network

/// A throwaway HTTP server that listens on 127.0.0.1:<port> just long enough
/// to catch the OAuth redirect, extract the `code`, and show a "you can close
/// this tab" page in the browser.
final class LoopbackServer {
    enum ServerError: Error { case listenerFailed, authError(String), cancelled }

    private var listener: NWListener?
    private var continuation: CheckedContinuation<String, Error>?
    private var finished = false

    func waitForCode(port: UInt16) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            self.continuation = cont
            do {
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
                self.listener = listener
                listener.newConnectionHandler = { [weak self] conn in
                    self?.handle(conn)
                }
                listener.stateUpdateHandler = { [weak self] state in
                    if case .failed = state { self?.finish(.failure(ServerError.listenerFailed)) }
                }
                listener.start(queue: .global())
            } catch {
                self.finish(.failure(error))
            }
        }
    }

    func cancel() { finish(.failure(ServerError.cancelled)) }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global())
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else { return }
            guard let data, let request = String(data: data, encoding: .utf8),
                  let line = request.split(separator: "\r\n").first else {
                self.respond(conn, body: htmlBody("Invalid request."))
                return
            }
            // Request line: "GET /callback?code=... HTTP/1.1"
            let parts = line.split(separator: " ")
            guard parts.count >= 2, let comps = URLComponents(string: "http://127.0.0.1" + parts[1]) else {
                self.respond(conn, body: htmlBody("Invalid request."))
                return
            }
            let items = comps.queryItems ?? []
            if let err = items.first(where: { $0.name == "error" })?.value {
                self.respond(conn, body: htmlBody("Authorization failed: \(err). You can close this tab."))
                self.finish(.failure(ServerError.authError(err)))
                return
            }
            if let code = items.first(where: { $0.name == "code" })?.value {
                self.respond(conn, body: htmlBody("✅ lyrbar is connected to Spotify. You can close this tab."))
                self.finish(.success(code))
                return
            }
            // Probably a /favicon.ico or stray request — keep waiting.
            self.respond(conn, body: htmlBody("Waiting for Spotify authorization…"))
        }
    }

    private func respond(_ conn: NWConnection, body: String) {
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n" +
                       "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
        conn.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private func finish(_ result: Result<String, Error>) {
        guard !finished else { return }
        finished = true
        listener?.cancel()
        listener = nil
        let cont = continuation
        continuation = nil
        cont?.resume(with: result)
    }
}

private func htmlBody(_ message: String) -> String {
    """
    <!doctype html><html><head><meta charset="utf-8"><title>lyrbar</title>
    <style>body{font-family:-apple-system,system-ui,sans-serif;background:#121212;color:#fff;
    display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
    .card{text-align:center;padding:2rem 3rem;background:#1db95422;border-radius:16px}
    h1{color:#1db954;margin:0 0 .5rem}</style></head>
    <body><div class="card"><h1>lyrbar</h1><p>\(message)</p></div></body></html>
    """
}
