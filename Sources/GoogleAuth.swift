import AuthenticationServices
import CryptoKit
import Foundation
import Network
import UIKit

enum AuthError: LocalizedError {
    case missingClient, noRefreshToken, state, google(String), http(Int, String)
    var errorDescription: String? {
        switch self {
        case .missingClient: return "Falta el client_id de Google (GH_CLIENT_ID)."
        case .noRefreshToken: return "No hay sesión: inicia sesión con Google."
        case .state: return "El parámetro state no coincide."
        case .google(let m): return "Google devolvió error: \(m)"
        case .http(let c, let b): return "HTTP \(c): \(b.prefix(300))"
        }
    }
}

/// OAuth code + PKCE con dos modos, según haya `client_secret` en el Keychain:
/// - con secreto (cliente Web, el de `spikes/oauth_read/probe.py`): redirect loopback `http://127.0.0.1:8765/callback`; un NWListener
///   local recoge el código mientras ASWebAuthenticationSession muestra el navegador del sistema.
/// - sin secreto (cliente iOS, para el móvil real): redirect por esquema inverso
///   `com.googleusercontent.apps.<ID>:/oauth2redirect`, que la propia sesión devuelve.
@MainActor
final class GoogleAuth: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let scopes = [
        "https://www.googleapis.com/auth/googlehealth.activity_and_fitness.readonly",
        "https://www.googleapis.com/auth/googlehealth.health_metrics_and_measurements.readonly",
        "https://www.googleapis.com/auth/googlehealth.sleep.readonly",
        "https://www.googleapis.com/auth/googlehealth.settings.readonly",   // dispositivos emparejados (batería)
    ]
    private let port: UInt16 = 8765
    private var usesCustomScheme: Bool { Keychain.get("client_secret") == nil }
    private func reversedScheme(_ cid: String) -> String {
        "com.googleusercontent.apps." + cid.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
    }
    private func redirectURI(for cid: String) -> String {
        usesCustomScheme ? "\(reversedScheme(cid)):/oauth2redirect" : "http://127.0.0.1:\(port)/callback"
    }

    @Published private(set) var signedIn = false
    private var accessToken: String?
    private var accessExpiry = Date.distantPast
    private var session: ASWebAuthenticationSession?

    override init() {
        super.init()
        bootstrapFromEnvironment()
        signedIn = Keychain.get("refresh_token") != nil
    }

    /// Solo desarrollo en simulador: `SIMCTL_CHILD_GH_CLIENT_ID=… xcrun simctl launch …` guarda las credenciales
    /// en el Keychain para que la app funcione después sin variables. `GH_REFRESH_TOKEN` salta el login interactivo.
    private func bootstrapFromEnvironment() {
        let env = ProcessInfo.processInfo.environment
        if let v = env["GH_CLIENT_ID"], !v.isEmpty { Keychain.set(v, for: "client_id") }
        if let v = env["GH_CLIENT_SECRET"], !v.isEmpty { Keychain.set(v, for: "client_secret") }
        if let v = env["GH_REFRESH_TOKEN"], !v.isEmpty { Keychain.set(v, for: "refresh_token") }
        // Móvil real: client_id del cliente iOS desde Resources/GoogleClient.plist (no versionado, sin secreto).
        if Keychain.get("client_id") == nil,
           let url = Bundle.main.url(forResource: "GoogleClient", withExtension: "plist"),
           let id = NSDictionary(contentsOf: url)?["CLIENT_ID"] as? String {
            Keychain.set(id, for: "client_id")
        }
    }

    /// Sube con cada cierre de sesión: una renovación en vuelo que termine después no debe reponer tokens ni `signedIn`.
    private var epoch = 0

    func signOut() {
        epoch += 1
        tokenTask?.cancel(); tokenTask = nil
        session?.cancel(); session = nil
        Keychain.set(nil, for: "refresh_token")
        accessToken = nil
        accessExpiry = .distantPast
        signedIn = false
    }

    /// Las peticiones llegan en paralelo: todas comparten la misma renovación en curso en vez de pedir un token cada una.
    private var tokenTask: Task<String, Error>?

    func validAccessToken() async throws -> String {
        if let t = accessToken, Date() < accessExpiry.addingTimeInterval(-60) { return t }
        if let task = tokenTask { return try await task.value }
        let task = Task { try await self.renewAccessToken() }
        tokenTask = task
        defer { tokenTask = nil }
        return try await task.value
    }

    private func renewAccessToken() async throws -> String {
        guard let refresh = Keychain.get("refresh_token") else { throw AuthError.noRefreshToken }
        var form = ["client_id": try clientID(), "refresh_token": refresh, "grant_type": "refresh_token"]
        if let s = Keychain.get("client_secret") { form["client_secret"] = s }
        let tok = try await postToken(form)
        return tok
    }

    func signIn() async throws {
        let cid = try clientID()
        let verifier = Self.randomURLSafe(64)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomURLSafe(16)
        let redirect = redirectURI(for: cid)
        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            .init(name: "client_id", value: cid), .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"), .init(name: "scope", value: Self.scopes.joined(separator: " ")),
            .init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent"),
            .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ]
        let query: [String: String]
        if usesCustomScheme {
            defer { session = nil }
            query = try await runSession(url: comps.url!, scheme: reversedScheme(cid))
        } else {
            let listener = try LoopbackListener(port: port)
            // El callback real es http://127.0.0.1; el esquema de la sesión no se usará: la cancelamos al recibir el código.
            let web = ASWebAuthenticationSession(url: comps.url!, callbackURLScheme: "healthspike-unused") { _, _ in }
            web.presentationContextProvider = self
            web.prefersEphemeralWebBrowserSession = false
            session = web
            web.start()
            defer { web.cancel(); session = nil; listener.stop() }
            query = try await listener.firstRequestQuery(timeout: 300)
        }
        guard query["state"] == state else { throw AuthError.state }
        if let e = query["error"] { throw AuthError.google(e) }
        guard let code = query["code"] else { throw AuthError.google("sin code") }
        var form = ["code": code, "client_id": cid, "redirect_uri": redirect,
                    "grant_type": "authorization_code", "code_verifier": verifier]
        if let s = Keychain.get("client_secret") { form["client_secret"] = s }
        _ = try await postToken(form)
    }

    // MARK: - Internos

    /// Modo cliente iOS: la sesión devuelve la URL de redirect con el esquema inverso.
    private func runSession(url: URL, scheme: String) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: String], Error>) in
            let web = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, error in
                if let error { cont.resume(throwing: error); return }
                guard let callback, let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems else {
                    cont.resume(throwing: AuthError.google("redirect sin parámetros")); return
                }
                cont.resume(returning: Dictionary(uniqueKeysWithValues: items.compactMap { i in i.value.map { (i.name, $0) } }))
            }
            web.presentationContextProvider = self
            web.prefersEphemeralWebBrowserSession = false
            session = web
            web.start()
        }
    }

    private func clientID() throws -> String {
        guard let c = Keychain.get("client_id") else { throw AuthError.missingClient }
        return c
    }

    private func postToken(_ form: [String: String]) async throws -> String {
        let startEpoch = epoch
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        req.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String else {
            throw AuthError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        guard startEpoch == epoch else { throw CancellationError() }
        accessToken = access
        accessExpiry = Date().addingTimeInterval((json["expires_in"] as? Double) ?? 3600)
        if let r = json["refresh_token"] as? String { Keychain.set(r, for: "refresh_token") }
        signedIn = Keychain.get("refresh_token") != nil
        return access
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            return scene?.keyWindow ?? ASPresentationAnchor()
        }
    }

    private static func randomURLSafe(_ n: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// Servidor HTTP mínimo en 127.0.0.1 que atiende una sola petición (el redirect de Google).
/// Todo su estado mutable se toca solo desde `queue`, por eso es seguro marcarlo `@unchecked Sendable`.
final class LoopbackListener: @unchecked Sendable {
    private let listener: NWListener
    private var continuation: CheckedContinuation<[String: String], Error>?
    private let queue = DispatchQueue(label: "loopback")

    init(port: UInt16) throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
    }

    func stop() { listener.cancel() }

    func firstRequestQuery(timeout: TimeInterval) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: String], Error>) in
            queue.async { [weak self] in
                guard let self else { return }
                self.continuation = cont
                self.listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
                self.listener.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.finish(.failure(AuthError.google("tiempo agotado esperando el callback")))
                }
            }
        }
    }

    private func finish(_ result: Result<[String: String], Error>) {
        guard let c = continuation else { return }
        continuation = nil
        c.resume(with: result)
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let text = String(data: data, encoding: .utf8) else { conn.cancel(); return }
            let line = text.split(separator: "\r\n").first.map(String.init) ?? ""
            let parts = line.split(separator: " ")
            guard parts.count >= 2, let url = URLComponents(string: String(parts[1])), url.path == "/callback" else {
                conn.send(content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                          completion: .contentProcessed { _ in conn.cancel() })
                return
            }
            let query = Dictionary(uniqueKeysWithValues: (url.queryItems ?? []).compactMap { i in i.value.map { (i.name, $0) } })
            let body = "<html><body style='font-family:-apple-system;text-align:center;margin-top:20vh'><h2>Listo</h2><p>Puedes volver a la app.</p></body></html>"
            let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in conn.cancel() })
            self.finish(.success(query))
        }
    }
}
