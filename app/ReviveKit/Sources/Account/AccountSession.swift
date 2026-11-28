// The signed-in state and the token dance (prd.md §7.1): the access token is refreshed before it
// runs out or when the server says it has; one refresh at a time, retried with the same
// Idempotency-Key after a lost answer, so the server never sees a spent refresh token twice
// (that would revoke this sign-in's refresh-token family).

import Foundation

public actor AccountSession {
    public nonisolated let client: AccountClient
    private let store: any SessionStoring
    private let now: @Sendable () -> Date

    /// The account, nil when signed out.
    public var user: AccountUser? { saved?.user }
    private var saved: SavedSession?
    private var access: (token: String, expires: Date)?
    private var refreshing: Task<String, Error>?
    /// Changes when a sign-in is replaced or forgotten, including another login by the same user.
    private var signInID = UUID()

    /// Refreshes this long before the access token runs out, against clock drift.
    static let margin: TimeInterval = 60

    public init(client: AccountClient, store: any SessionStoring, now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.store = store
        self.now = now
        saved = try? store.load()
    }

    public var isSignedIn: Bool { saved != nil }

    /// Keeps a new sign-in (any sign-in call, a password change).
    public func adopt(_ tokens: AccountTokens) throws {
        try storeTokens(tokens)
        signInID = UUID()
        refreshing = nil
    }

    private func storeTokens(_ tokens: AccountTokens) throws {
        let session = SavedSession(refreshToken: tokens.refreshToken, user: tokens.user)
        try store.save(session)
        saved = session
        access = (tokens.accessToken, now().addingTimeInterval(TimeInterval(tokens.expiresIn) - Self.margin))
    }

    /// Runs `call` with a valid access token. When the server says the token has run out, refreshes
    /// once and tries again. Throws `.signedOut` (and forgets the sign-in) when the sign-in ended.
    public func authorized<T: Sendable>(_ call: @Sendable (String) async throws -> T) async throws -> T {
        try await authorized(for: signInID, call)
    }

    private func authorized<T: Sendable>(for owner: UUID, _ call: @Sendable (String) async throws -> T) async throws -> T {
        try requireCurrent(owner)
        var retried = false
        while true {
            let token = try await accessToken()
            try requireCurrent(owner)
            do {
                let result = try await call(token)
                try requireCurrent(owner)
                return result
            } catch let error as AccountError {
                try requireCurrent(owner)
                if !retried && error.code == "token_expired" {
                    retried = true
                    if access?.token == token { access = nil }
                    continue
                }
                if error.code == "invalid_token" || error.code == "unauthorized" {
                    try? forget()
                    throw AccountError.signedOut
                }
                throw error
            }
        }
    }

    /// The account as the server has it now; also keeps the stored copy current.
    @discardableResult
    public func reloadUser() async throws -> AccountUser {
        let owner = signInID
        let client = client
        let fresh = try await authorized(for: owner) { try await client.me(accessToken: $0) }
        try requireCurrent(owner)
        if var session = saved {
            session.user = fresh
            saved = session
            try? store.save(session)
        }
        return fresh
    }

    public func changePassword(current: String, new: String) async throws {
        let owner = signInID
        let client = client
        let tokens = try await authorized(for: owner) {
            try await client.changePassword(accessToken: $0, current: current, new: new)
        }
        try requireCurrent(owner)
        try adopt(tokens)
    }

    /// Deletes the account on the server, then forgets it here. Recordings on this phone stay.
    public func deleteAccount() async throws {
        let owner = signInID
        let client = client
        try await authorized(for: owner) { try await client.deleteAccount(accessToken: $0) }
        try requireCurrent(owner)
        try forget()
    }

    /// 意见反馈. The same key goes with the retry after a refreshed token: the server keeps no
    /// answer for a retryable error such as `token_expired` (prd.md §7.1), so the retry runs.
    public func sendFeedback(_ content: String, appVersion: String, idempotencyKey: String) async throws {
        let client = client
        try await authorized {
            try await client.sendFeedback(accessToken: $0, content: content, appVersion: appVersion,
                                          idempotencyKey: idempotencyKey)
        }
    }

    // MARK: 用闻笺账号转写 (AccountCloud.swift)

    /// Puts the audio on the server and returns the server's id for the recording. Parts the
    /// server already has are not sent again, so calling this again after an interruption picks
    /// up where it stopped. `audio` must be the bytes `new.sha256` and `new.size` describe.
    /// `progress` gets the bytes the server holds and the total, after each part.
    public func upload(_ new: NewRecording, audio: Data, idempotencyKey: String,
                       progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> UUID {
        guard audio.count == new.size else { throw AccountError.badResponse(0) }
        let client = client
        var recording = try await authorized {
            try await client.createRecording(accessToken: $0, new, idempotencyKey: idempotencyKey)
        }
        // A lapsed upload (the store forgot it) or a part that did not arrive: fresh URLs, once.
        for attempt in 0..<2 {
            if recording.audio?.uploaded == true { return recording.id }
            if recording.upload == nil {
                let id = recording.id
                recording = try await authorized { try await client.resumeUpload(accessToken: $0, recordingId: id) }
                if recording.audio?.uploaded == true { return recording.id }
            }
            guard let plan = recording.upload else { throw AccountError.badResponse(200) }
            var etags: [(number: Int, etag: String)] = []
            var held = plan.parts.filter(\.done).reduce(0) { $0 + $1.size }
            progress(held, new.size)
            for part in plan.parts.sorted(by: { $0.partNumber < $1.partNumber }) {
                try Task.checkCancellation()
                if part.done, let etag = part.etag {
                    etags.append((part.partNumber, etag))
                    continue
                }
                guard part.offset >= 0, part.size > 0, part.offset + part.size <= audio.count else {
                    throw AccountError.badResponse(200)
                }
                let start = audio.startIndex + part.offset
                let bytes = audio.subdata(in: start..<start + part.size)
                etags.append((part.partNumber, try await client.putPart(bytes, to: part.url)))
                held += part.size
                progress(held, new.size)
            }
            let id = recording.id
            let parts = etags
            do {
                recording = try await authorized {
                    try await client.completeUpload(accessToken: $0, recordingId: id, parts: parts)
                }
                if recording.audio?.uploaded == true { return recording.id }
            } catch let error as AccountError
                where attempt == 0 && ["upload_expired", "upload_incomplete", "upload_mismatch"].contains(error.code ?? "") {
                recording = try await authorized { try await client.resumeUpload(accessToken: $0, recordingId: id) }
            }
        }
        throw AccountError.badResponse(409)
    }

    /// Starts transcribing a recording the server has, or joins the task already running.
    public func transcribe(recordingId: UUID, language: String, idempotencyKey: String) async throws -> RemoteTask {
        let client = client
        return try await authorized {
            try await client.transcribe(accessToken: $0, recordingId: recordingId, language: language,
                                        idempotencyKey: idempotencyKey)
        }
    }

    /// Asks every 2 s, then less often up to every 30 s (prd.md §7.4), until the task ends.
    /// Throws `.taskFailed` with the server's reason when it fails; cancel to stop waiting.
    public func waitForTask(_ id: UUID,
                            sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) })
        async throws -> RemoteTask {
        let client = client
        var delay = Self.firstPoll
        while true {
            let task = try await authorized { try await client.task(accessToken: $0, id: id) }
            switch task.status {
            case .succeeded:
                return task
            case .failed:
                throw AccountError.taskFailed(code: task.error?.code ?? "failed", message: task.error?.message ?? "")
            case .queued, .running:
                try await sleep(delay)
                delay = min(delay * 3 / 2, Self.lastPoll)
            }
        }
    }

    static let firstPoll: Duration = .seconds(2)
    static let lastPoll: Duration = .seconds(30)

    public func transcript(recordingId: UUID) async throws -> RemoteTranscript {
        let client = client
        return try await authorized { try await client.transcript(accessToken: $0, recordingId: recordingId) }
    }

    /// The scenes a summary can be written for.
    public func templates() async throws -> [SummaryTemplate] {
        let client = client
        return try await authorized { try await client.templates(accessToken: $0) }
    }

    /// Starts a summary of a recording that has a transcript on the server; wait on the task,
    /// then read `summaries`.
    public func summarize(recordingId: UUID, templateId: String?, profession: String,
                          idempotencyKey: String) async throws -> RemoteTask {
        let client = client
        return try await authorized {
            try await client.summarize(accessToken: $0, recordingId: recordingId, templateId: templateId,
                                       profession: profession, idempotencyKey: idempotencyKey)
        }
    }

    /// Newest first.
    public func summaries(recordingId: UUID) async throws -> [RemoteSummary] {
        let client = client
        return try await authorized { try await client.summaries(accessToken: $0, recordingId: recordingId) }
    }

    /// Starts a retitle; the finished task's `result?.title` is the new title.
    public func retitle(recordingId: UUID, currentTitle: String?, idempotencyKey: String) async throws -> RemoteTask {
        let client = client
        return try await authorized {
            try await client.retitle(accessToken: $0, recordingId: recordingId, currentTitle: currentTitle,
                                     idempotencyKey: idempotencyKey)
        }
    }

    public func usage() async throws -> RemoteUsage {
        let client = client
        return try await authorized { try await client.usage(accessToken: $0) }
    }

    /// Signs out on the server when it can be reached, and always here.
    public func signOut() async {
        let refreshToken = saved?.refreshToken
        try? forget()
        if let refreshToken {
            try? await client.signOut(refreshToken)
        }
    }

    // MARK: Tokens

    func accessToken() async throws -> String {
        if let access, access.expires > now() { return access.token }
        // Everyone waiting shares one refresh: a second one would spend the token twice.
        if let refreshing { return try await refreshing.value }
        guard var session = saved else { throw AccountError.signedOut }
        let key = session.pendingRefreshKey ?? UUID().uuidString
        if session.pendingRefreshKey == nil {
            session.pendingRefreshKey = key
            try store.save(session)
            saved = session
        }
        let spent = session.refreshToken
        let owner = signInID
        let task = Task { try await self.refresh(spent, key: key, owner: owner) }
        refreshing = task
        defer { if signInID == owner { refreshing = nil } }
        return try await task.value
    }

    private func requireCurrent(_ owner: UUID) throws {
        guard signInID == owner else { throw CancellationError() }
    }

    private func refresh(_ spent: String, key: String, owner: UUID) async throws -> String {
        try requireCurrent(owner)
        do {
            let tokens = try await client.refresh(spent, idempotencyKey: key)
            try requireCurrent(owner)
            try storeTokens(tokens)
            return tokens.accessToken
        } catch let error as AccountError {
            try requireCurrent(owner)
            if case .server(_, let code, _, _) = error, code.hasPrefix("refresh_") {
                try? forget()
                throw AccountError.signedOut
            }
            // Lost answer or server trouble: the pending key stays with the original token.
            throw error
        }
    }

    private func forget() throws {
        signInID = UUID()
        refreshing = nil
        saved = nil
        access = nil
        try store.save(nil)
    }
}
