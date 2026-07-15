import Foundation
import Network

@MainActor
final class OscarClient: ObservableObject {
    @Published var host = "mutiny.v1rg.com"
    @Published var port = "9898"
    @Published var screenName = ""
    @Published var password = ""
    @Published var cookieHex = ""
    @Published var buddyName = ""
    @Published var roomName = ""
    @Published var recipient = ""
    @Published var draftMessage = ""
    @Published var roomDraftMessage = ""
    @Published private(set) var status = "Offline"
    @Published private(set) var isReady = false
    @Published private(set) var isConnecting = false
    @Published private(set) var buddies: [String] = []
    @Published private(set) var buddyPresence: [String: Bool] = [:]
    @Published private(set) var messages: [IncomingMessage] = []
    @Published private(set) var chatRooms: [ChatRoom] = []
    @Published private(set) var chatRoomMessages: [ChatRoomMessage] = []

    private var authConnection: FlapConnection?
    private var bosConnection: FlapConnection?
    private var tocConnection: TocConnection?
    private var requestId: UInt32 = 1

    init() {
        loadLocalState()
    }

    func connect() {
        guard !isConnecting else { return }

        Task {
            await MainActor.run {
                status = "Authenticating"
                isReady = false
                isConnecting = true
                appendSystemMessage("Connecting to \(host):\(port)...")
            }

            do {
                try await connectToc()
            } catch {
                await MainActor.run {
                    status = "Offline"
                    isConnecting = false
                    appendSystemMessage(error.userMessage)
                }
            }
        }
    }

    func disconnect() {
        authConnection?.close()
        bosConnection?.close()
        tocConnection?.close()
        authConnection = nil
        bosConnection = nil
        tocConnection = nil
        isConnecting = false
        isReady = false
        buddyPresence.removeAll()
        status = "Offline"
        appendSystemMessage("Disconnected")
    }

    func addBuddy() {
        let buddy = buddyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !buddy.isEmpty else { return }

        if !buddies.contains(where: { $0.caseInsensitiveCompare(buddy) == .orderedSame }) {
            buddies.append(buddy)
            buddies.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            buddyPresence[buddyKey(buddy)] = false
            saveLocalState()
        }

        recipient = buddy
        buddyName = ""

        if isReady {
            tocConnection?.sendCommand("toc_add_buddy \(tocQuote(buddy))")
        }
    }

    func removeBuddy(_ buddy: String) {
        buddies.removeAll { $0.caseInsensitiveCompare(buddy) == .orderedSame }
        buddyPresence.removeValue(forKey: buddyKey(buddy))
        saveLocalState()
        if recipient.caseInsensitiveCompare(buddy) == .orderedSame {
            recipient = ""
        }

        if isReady {
            tocConnection?.sendCommand("toc_remove_buddy \(tocQuote(buddy))")
        }
    }

    func isBuddyOnline(_ buddy: String) -> Bool {
        buddyPresence[buddyKey(buddy)] ?? false
    }

    func messages(with buddy: String) -> [IncomingMessage] {
        let key = buddyKey(buddy)
        return messages.filter { message in
            switch message.direction {
            case .incoming:
                return buddyKey(message.from) == key
            case .outgoing:
                return buddyKey(message.to) == key
            case .system:
                return false
            }
        }
    }

    func chooseBuddy(_ buddy: String) {
        recipient = buddy
    }

    func sendMessage() {
        let to = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !to.isEmpty, !text.isEmpty else { return }

        guard isReady else {
            if isConnecting {
                appendSystemMessage("Still connecting. Wait until status says Online before sending to \(to).")
            } else {
                appendSystemMessage("Connect first, then send to \(to).")
            }
            return
        }

        tocConnection?.sendCommand("toc_send_im \(tocQuote(to)) \(tocQuote(text))")
        appendMessage(IncomingMessage(direction: .outgoing, from: screenName, to: to, text: text))
        saveLocalState()
        draftMessage = ""
    }

    func joinRoom() {
        let room = roomName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !room.isEmpty else { return }

        guard isReady else {
            appendSystemMessage("Connect first, then join \(room).")
            return
        }

        tocConnection?.sendCommand("toc_chat_join 4 \(tocQuote(room))")
        appendSystemMessage("Joining room \(room)")
        roomName = ""
    }

    func leaveRoom(_ room: ChatRoom) {
        tocConnection?.sendCommand("toc_chat_leave \(room.id)")
        chatRooms.removeAll { $0.id == room.id }
        saveLocalState()
    }

    func sendRoomMessage(room: ChatRoom) {
        let text = roomDraftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        guard isReady else {
            appendSystemMessage("Connect first, then send to \(room.name).")
            return
        }

        tocConnection?.sendCommand("toc_chat_send \(room.id) \(tocQuote(text))")
        chatRoomMessages.append(ChatRoomMessage(roomId: room.id, roomName: room.name, from: screenName, text: text, isOutgoing: true))
        trimRoomMessages()
        saveLocalState()
        roomDraftMessage = ""
    }

    func messages(in room: ChatRoom) -> [ChatRoomMessage] {
        chatRoomMessages.filter { $0.roomId == room.id }
    }

    private func connectToc() async throws {
        let tocPort = UInt16(port) ?? 9898
        let connection = TocConnection(host: host, port: tocPort)
        tocConnection = connection

        connection.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handleTocEvent(event)
            }
        }
        connection.onClose = { [weak self] in
            Task { @MainActor in
                self?.isReady = false
                self?.isConnecting = false
                self?.status = "Offline"
                self?.appendSystemMessage("TOC connection closed")
            }
        }
        connection.onError = { [weak self] error in
            Task { @MainActor in
                self?.isConnecting = false
                self?.status = "Offline"
                self?.appendSystemMessage(error.userMessage)
            }
        }

        try await connection.connect()
        appendSystemMessage("TOC TCP connected")

        let roasted = tocRoastedPassword(password)
        connection.sendCommand("toc_signon \(tocQuote(host)) 5190 \(tocQuote(screenName)) \(roasted) english \(tocQuote("Away iOS"))")
        appendSystemMessage("Sent TOC sign-on as \(screenName)")
    }

    private func handleTocEvent(_ event: String) {
        if event.hasPrefix("SIGN_ON:") {
            tocConnection?.sendCommand("toc_init_done")
            for buddy in buddies {
                tocConnection?.sendCommand("toc_add_buddy \(tocQuote(buddy))")
            }
            isConnecting = false
            isReady = true
            status = "Online"
            appendSystemMessage("TOC sign-on complete")
            return
        }

        if event.hasPrefix("ERROR:") {
            isConnecting = false
            isReady = false
            status = "Offline"
            appendSystemMessage("TOC error: \(event)")
            return
        }

        if event.hasPrefix("IM_IN:") {
            let parts = event.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            if parts.count >= 4 {
                rememberBuddy(parts[1], online: true)
                appendMessage(IncomingMessage(direction: .incoming, from: parts[1], to: screenName, text: stripHtml(parts[3])))
                saveLocalState()
            }
            return
        }

        if event.hasPrefix("CHAT_JOIN:") {
            handleChatJoin(event)
            return
        }

        if event.hasPrefix("CHAT_IN:") {
            handleChatMessage(event)
            return
        }

        if event.hasPrefix("CHAT_UPDATE_BUDDY:") {
            handleChatBuddyUpdate(event)
            return
        }

        if event.hasPrefix("CONFIG:") {
            handleTocConfig(event)
            return
        }

        if event.hasPrefix("UPDATE_BUDDY:") {
            handleBuddyUpdate(event)
            return
        }

        if event.hasPrefix("NICK:") {
            return
        }

        appendSystemMessage(event)
    }

    private func resolveBosAuth() async throws -> (host: String, port: UInt16, cookie: Data) {
        let trimmedCookie = cookieHex.trimmingCharacters(in: .whitespacesAndNewlines)
        let authPort = UInt16(port) ?? 5190
        let configuredHost = host
        let authScreenName = screenName
        let authPassword = password

        if !trimmedCookie.isEmpty {
            return (host: configuredHost, port: authPort, cookie: Data(hexString: trimmedCookie))
        }

        return try await authenticatePassword(authPassword, host: configuredHost, port: authPort, screenName: authScreenName, profile: .aim51)
    }

    private func authenticatePassword(_ candidatePassword: String, host configuredHost: String, port authPort: UInt16, screenName authScreenName: String, profile: AuthProfile) async throws -> (host: String, port: UInt16, cookie: Data) {
        let connection = FlapConnection(host: configuredHost, port: authPort)
        authConnection = connection

        return try await withCheckedThrowingContinuation { continuation in
            var didResume = false
            var didSendAuthRequest = false
            var authFrameCount = 0
            var lastAuthFrame = "none"

            connection.onFrame = { [weak self] frame in
                authFrameCount += 1
                lastAuthFrame = "channel \(frame.channel.rawValue), \(frame.payload.count) byte(s)"

                do {
                    if frame.channel == .signon, !didSendAuthRequest {
                        didSendAuthRequest = true
                        connection.send(.signon, payload: buildAuthRequest(screenName: authScreenName, password: candidatePassword, profile: profile))
                        return
                    }

                    guard frame.channel == .close || frame.channel == .signon else {
                        return
                    }

                    let tlvs = try parseTlvs(frame.payload)
                    let types = tlvTypeSummary(tlvs)

                    if let hostData = tlvs[TlvType.bosHost]?.first,
                       let cookie = tlvs[TlvType.bosAuthCookie]?.first {
                        var advertisedHost = hostData.utf8String
                        var advertisedPort = authPort
                        if let parsed = parseBosAddress(advertisedHost, fallbackPort: authPort) {
                            advertisedHost = parsed.host
                            advertisedPort = parsed.port
                        }
                        if advertisedHost == "127.0.0.1", configuredHost != "127.0.0.1", configuredHost != "localhost" {
                            advertisedHost = configuredHost
                        }

                        Task { @MainActor in
                            self?.appendSystemMessage("Auth OK. BOS \(advertisedHost):\(advertisedPort). TLVs \(types)")
                        }
                        connection.close()
                        if !didResume {
                            didResume = true
                            continuation.resume(returning: (advertisedHost, advertisedPort, cookie))
                        }
                        return
                    }

                    throw OscarError.authenticationFailed(authFailureMessage(tlvs: tlvs, fallbackTypes: types, payload: frame.payload))
                } catch {
                    if !didResume {
                        didResume = true
                        continuation.resume(throwing: error)
                    }
                }
            }

            connection.onClose = {
                if !didResume {
                    didResume = true
                    continuation.resume(throwing: OscarError.connectionFailed("Authentication closed before a BOS cookie. Frames: \(authFrameCount). Last auth frame: \(lastAuthFrame)"))
                }
            }

            connection.onError = { error in
                if !didResume {
                    didResume = true
                    continuation.resume(throwing: error)
                }
            }

            Task {
                do {
                    try await connection.connect()
                } catch {
                    if !didResume {
                        didResume = true
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func connectBos(host: String, port: UInt16, cookie: Data) async {
        status = "Connecting to BOS"
        appendSystemMessage("BOS \(host):\(port)")

        let connection = FlapConnection(host: host, port: port)
        bosConnection = connection

        connection.onFrame = { [weak self] frame in
            Task { @MainActor in
                self?.handleBosFrame(frame, cookie: cookie)
            }
        }
        connection.onClose = { [weak self] in
            Task { @MainActor in
                self?.isReady = false
                self?.isConnecting = false
                self?.status = "Offline"
                self?.appendSystemMessage("Connection closed")
            }
        }
        connection.onError = { [weak self] error in
            Task { @MainActor in
                self?.appendSystemMessage(error.userMessage)
            }
        }

        do {
            try await connection.connect()
        } catch {
            status = "Offline"
            isConnecting = false
            appendSystemMessage(error.userMessage)
        }
    }

    private func handleBosFrame(_ frame: FlapFrame, cookie: Data) {
        do {
            if frame.channel == .signon {
                sendBosSignon(cookie: cookie)
                return
            }

            if frame.channel == .data {
                let snac = try parseSnac(frame.payload)
                handleSnac(snac)
                return
            }

            if frame.channel == .close {
                let tlvs = try parseTlvs(frame.payload)
                appendSystemMessage("Server closed with \(tlvs.count) TLV type(s)")
                disconnect()
            }
        } catch {
            appendSystemMessage(error.userMessage)
        }
    }

    private func handleSnac(_ snac: Snac) {
        if snac.family == SnacFamily.oservice.rawValue, snac.subtype == 0x0003 {
            requestServiceRights()
            sendClientReady()
            setAvailable()
            for buddy in buddies {
                sendSnac(.buddy, subtype: 0x0004, payload: screenNameBuffer(buddy))
            }
            isConnecting = false
            isReady = true
            status = "Online"
            appendSystemMessage("OSCAR services are ready")
            return
        }

        if snac.family == SnacFamily.icbm.rawValue, snac.subtype == 0x0007 {
            do {
                let incoming = try parseIncomingInstantMessage(snac.payload)
                appendMessage(IncomingMessage(direction: .incoming, from: incoming.from, to: screenName, text: incoming.text))
            } catch {
                appendSystemMessage(error.userMessage)
            }
        }
    }

    private func sendBosSignon(cookie: Data) {
        var payload = ByteWriter()
        payload.u32(0x00000001)
        payload.tlv(TlvType.screenName, screenName)
        payload.tlv(TlvType.bosAuthCookie, cookie)
        bosConnection?.send(.signon, payload: payload.data)
    }

    private func requestServiceRights() {
        sendSnac(.oservice, subtype: 0x0006)
        sendSnac(.icbm, subtype: 0x0004)
        sendSnac(.buddy, subtype: 0x0002)
    }

    private func sendClientReady() {
        var payload = ByteWriter()
        for family in [SnacFamily.oservice, .location, .buddy, .icbm, .bos] {
            payload.u16(family.rawValue)
            payload.u16(family == .oservice ? 0x0003 : 0x0001)
            payload.u16(0x0110)
            payload.u16(0x047b)
        }
        sendSnac(.oservice, subtype: 0x0002, payload: payload.data)
    }

    private func setAvailable() {
        sendSnac(.oservice, subtype: 0x001e)
    }

    private func sendSnac(_ family: SnacFamily, subtype: UInt16, payload: Data = Data()) {
        let snac = buildSnac(family: family.rawValue, subtype: subtype, payload: payload, requestId: requestId)
        requestId += 1
        bosConnection?.send(.data, payload: snac)
    }

    private func systemMessage(_ text: String) -> IncomingMessage {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return IncomingMessage(direction: .system, from: "System", to: screenName, text: cleaned.isEmpty ? "Unknown error" : cleaned)
    }

    private func appendSystemMessage(_ text: String) {
        appendMessage(systemMessage(text))
    }

    private func appendMessage(_ message: IncomingMessage) {
        let cleaned = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }

        messages.append(message)
        if messages.count > 1000 {
            messages.removeFirst(messages.count - 1000)
        }
    }

    private func rememberBuddy(_ buddy: String, online: Bool? = nil) {
        let cleaned = buddy.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }

        if !buddies.contains(where: { $0.caseInsensitiveCompare(cleaned) == .orderedSame }) {
            buddies.append(cleaned)
            buddies.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            saveLocalState()
        }

        if let online {
            buddyPresence[buddyKey(cleaned)] = online
        } else if buddyPresence[buddyKey(cleaned)] == nil {
            buddyPresence[buddyKey(cleaned)] = false
        }
    }

    private func handleTocConfig(_ event: String) {
        let config = String(event.dropFirst("CONFIG:".count))
        for line in config.components(separatedBy: CharacterSet.newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("b ") {
                rememberBuddy(String(trimmed.dropFirst(2)))
            }
        }
    }

    private func handleBuddyUpdate(_ event: String) {
        let parts = event.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3 else { return }

        let buddy = parts[1]
        let onlineValue = parts[2].lowercased()
        let online = onlineValue == "t" || onlineValue == "true" || onlineValue == "1"
        rememberBuddy(buddy, online: online)
    }

    private func handleChatJoin(_ event: String) {
        let parts = event.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, let roomId = Int(parts[1]) else { return }
        let name = parts[2]

        if let index = chatRooms.firstIndex(where: { $0.id == roomId }) {
            chatRooms[index].name = name
        } else {
            chatRooms.append(ChatRoom(id: roomId, name: name))
            chatRooms.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        saveLocalState()
    }

    private func handleChatMessage(_ event: String) {
        let parts = event.split(separator: ":", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 5, let roomId = Int(parts[1]) else { return }

        let from = parts[2]
        let text = stripHtml(parts[4])
        let room = chatRooms.first { $0.id == roomId }
        let roomName = room?.name ?? "Room \(roomId)"
        chatRoomMessages.append(ChatRoomMessage(roomId: roomId, roomName: roomName, from: from, text: text, isOutgoing: buddyKey(from) == buddyKey(screenName)))
        trimRoomMessages()
        saveLocalState()
    }

    private func handleChatBuddyUpdate(_ event: String) {
        let parts = event.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 4, let roomId = Int(parts[1]) else { return }

        let action = parts[2].lowercased()
        let names = parts[3]
            .split(separator: ":")
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        if chatRooms.firstIndex(where: { $0.id == roomId }) == nil {
            chatRooms.append(ChatRoom(id: roomId, name: "Room \(roomId)"))
        }

        guard let index = chatRooms.firstIndex(where: { $0.id == roomId }) else { return }
        if action == "in" {
            for name in names where !chatRooms[index].participants.contains(where: { buddyKey($0) == buddyKey(name) }) {
                chatRooms[index].participants.append(name)
            }
        } else if action == "out" {
            chatRooms[index].participants.removeAll { existing in
                names.contains { buddyKey($0) == buddyKey(existing) }
            }
        }
        chatRooms[index].participants.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        saveLocalState()
    }

    private func trimRoomMessages() {
        if chatRoomMessages.count > 1000 {
            chatRoomMessages.removeFirst(chatRoomMessages.count - 1000)
        }
    }

    private func saveLocalState() {
        let snapshot = LocalChatState(
            buddies: buddies,
            messages: messages.filter { $0.direction != .system },
            chatRooms: chatRooms,
            chatRoomMessages: chatRoomMessages
        )

        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: localStateURL, options: [.atomic])
        } catch {
            print("Failed to save chat state: \(error)")
        }
    }

    private func loadLocalState() {
        do {
            let data = try Data(contentsOf: localStateURL)
            let snapshot = try JSONDecoder().decode(LocalChatState.self, from: data)
            buddies = snapshot.buddies
            messages = snapshot.messages
            chatRooms = snapshot.chatRooms
            chatRoomMessages = snapshot.chatRoomMessages
            for buddy in buddies {
                buddyPresence[buddyKey(buddy)] = false
            }
        } catch {
            buddies = []
            messages = []
            chatRooms = []
            chatRoomMessages = []
        }
    }
}

private struct LocalChatState: Codable {
    var buddies: [String]
    var messages: [IncomingMessage]
    var chatRooms: [ChatRoom]
    var chatRoomMessages: [ChatRoomMessage]
}

private var localStateURL: URL {
    let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    return directory.appendingPathComponent("aim-chat-state.json")
}

private func buddyKey(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

private enum AuthProfile {
    case aim51
    case simple

    var label: String {
        switch self {
        case .aim51:
            return "AIM 5.1"
        case .simple:
            return "simple OSCAR"
        }
    }
}

private func buildAuthRequest(screenName: String, password: String, profile: AuthProfile) -> Data {
    var payload = ByteWriter()
    payload.u32(0x00000001)
    payload.tlv(TlvType.screenName, screenName)
    payload.tlv(TlvType.password, roastPassword(password))

    switch profile {
    case .aim51:
        payload.tlv(TlvType.clientId, "AOL Instant Messenger (SM), version 5.1.3030/WIN32")
        payload.tlv(0x0016, Data([0x01, 0x09]))
        payload.tlv(0x0017, Data([0x00, 0x05]))
        payload.tlv(0x0018, Data([0x00, 0x01]))
        payload.tlv(0x0019, Data([0x00, 0x00]))
        payload.tlv(0x001a, Data([0x0b, 0xd6]))
        payload.tlv(0x0014, Data([0x00, 0x00, 0x00, 0x55]))
    case .simple:
        payload.tlv(TlvType.clientId, "simple-oscar-client")
        payload.tlv(0x0016, Data([0x01, 0x10]))
        payload.tlv(0x0017, Data([0x00, 0x01]))
        payload.tlv(0x0018, Data([0x00, 0x00]))
        payload.tlv(0x0019, Data([0x00, 0x00]))
        payload.tlv(0x001a, Data([0x00, 0x01]))
        payload.tlv(0x0014, Data([0x00, 0x00, 0x00, 0x55]))
    }

    payload.tlv(0x000f, "en")
    payload.tlv(0x000e, "us")
    return payload.data
}

private final class FlapConnection {
    var onFrame: ((FlapFrame) -> Void)?
    var onClose: (() -> Void)?
    var onError: ((Error) -> Void)?

    private let host: String
    private let port: UInt16
    private var connection: NWConnection?
    private var sequence: UInt16 = 0
    private var buffer = Data()

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    func connect() async throws {
        let nwHost = NWEndpoint.Host(host)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw OscarError.connectionFailed("Invalid port")
        }

        let connection = NWConnection(host: nwHost, port: nwPort, using: .tcp)
        self.connection = connection

        try await withCheckedThrowingContinuation { continuation in
            var didResume = false
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if !didResume {
                        didResume = true
                        continuation.resume()
                    }
                    self?.receive()
                case .failed(let error):
                    if !didResume {
                        didResume = true
                        continuation.resume(throwing: error)
                    }
                    self?.onError?(error)
                case .cancelled:
                    self?.onClose?()
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    func send(_ channel: FlapChannel, payload: Data = Data()) {
        sequence = sequence &+ 1
        var frame = ByteWriter()
        frame.u8(0x2a)
        frame.u8(channel.rawValue)
        frame.u16(sequence)
        frame.u16(UInt16(payload.count))
        frame.bytes(payload)

        connection?.send(content: frame.data, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.onError?(error)
            }
        })
    }

    func close() {
        connection?.cancel()
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.emitFrames()
            }

            if let error {
                self.onError?(error)
                return
            }

            if isComplete {
                self.onClose?()
                return
            }

            self.receive()
        }
    }

    private func emitFrames() {
        while buffer.count >= 6 {
            guard buffer.uint8(at: 0) == 0x2a else {
                onError?(OscarError.protocolError("Invalid FLAP marker"))
                close()
                return
            }

            guard let channel = FlapChannel(rawValue: buffer.uint8(at: 1)) else {
                onError?(OscarError.protocolError("Unknown FLAP channel"))
                close()
                return
            }

            let sequence = buffer.uint16(at: 2)
            let length = Int(buffer.uint16(at: 4))
            guard buffer.count >= 6 + length else {
                return
            }

            let payload = buffer.slice(6, length)
            buffer.removeSubrange(0..<(6 + length))
            onFrame?(FlapFrame(channel: channel, sequence: sequence, payload: payload))
        }
    }
}

private final class TocConnection {
    var onEvent: ((String) -> Void)?
    var onClose: (() -> Void)?
    var onError: ((Error) -> Void)?

    private let host: String
    private let port: UInt16
    private var connection: NWConnection?
    private var sequence: UInt16 = 0
    private var buffer = Data()
    private var didSendTocSignon = false
    private var pendingCommands: [String] = []

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    func connect() async throws {
        let nwHost = NWEndpoint.Host(host)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw OscarError.connectionFailed("Invalid TOC port")
        }

        let connection = NWConnection(host: nwHost, port: nwPort, using: .tcp)
        self.connection = connection

        try await withCheckedThrowingContinuation { continuation in
            var didResume = false
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if !didResume {
                        didResume = true
                        continuation.resume()
                    }
                    self?.sendRaw(Data("FLAPON\r\n\r\n".utf8))
                    self?.receive()
                case .failed(let error):
                    if !didResume {
                        didResume = true
                        continuation.resume(throwing: error)
                    }
                    self?.onError?(error)
                case .cancelled:
                    self?.onClose?()
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    func sendCommand(_ command: String) {
        guard didSendTocSignon else {
            pendingCommands.append(command)
            return
        }

        send(.data, payload: Data(command.utf8))
    }

    func close() {
        connection?.cancel()
    }

    private func sendRaw(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.onError?(error)
            }
        })
    }

    private func send(_ channel: FlapChannel, payload: Data) {
        sequence = sequence &+ 1
        var frame = ByteWriter()
        frame.u8(0x2a)
        frame.u8(channel.rawValue)
        frame.u16(sequence)
        frame.u16(UInt16(payload.count))
        frame.bytes(payload)
        sendRaw(frame.data)
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.emitFrames()
            }

            if let error {
                self.onError?(error)
                return
            }

            if isComplete {
                self.onClose?()
                return
            }

            self.receive()
        }
    }

    private func emitFrames() {
        while buffer.count >= 6 {
            guard buffer.uint8(at: 0) == 0x2a else {
                onError?(OscarError.protocolError("Invalid TOC FLAP marker"))
                close()
                return
            }

            guard let channel = FlapChannel(rawValue: buffer.uint8(at: 1)) else {
                onError?(OscarError.protocolError("Unknown TOC FLAP channel"))
                close()
                return
            }

            let length = Int(buffer.uint16(at: 4))
            guard buffer.count >= 6 + length else {
                return
            }

            let payload = buffer.slice(6, length)
            buffer.removeSubrange(0..<(6 + length))

            if channel == .signon, !didSendTocSignon {
                didSendTocSignon = true
                var signon = ByteWriter()
                signon.u32(0x00000001)
                send(.signon, payload: signon.data)
                flushPendingCommands()
                continue
            }

            if channel == .data {
                let text = payload.utf8String.trimmingCharacters(in: CharacterSet(charactersIn: "\0\r\n"))
                if !text.isEmpty {
                    onEvent?(text)
                }
            }
        }
    }

    private func flushPendingCommands() {
        let commands = pendingCommands
        pendingCommands.removeAll()
        for command in commands {
            send(.data, payload: Data(command.utf8))
        }
    }
}

private func parseBosAddress(_ value: String, fallbackPort: UInt16) -> (host: String, port: UInt16)? {
    let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
    guard let host = parts.first, !host.isEmpty else { return nil }
    let port = parts.count > 1 ? UInt16(parts[1]) ?? fallbackPort : fallbackPort
    return (host, port)
}

private func tocRoastedPassword(_ password: String) -> String {
    "0x" + roastPassword(password).map { String(format: "%02x", $0) }.joined()
}

private func tocQuote(_ value: String) -> String {
    let escaped = value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
}

private func stripHtml(_ value: String) -> String {
    var result = ""
    var insideTag = false
    for character in value {
        if character == "<" {
            insideTag = true
            continue
        }
        if character == ">" {
            insideTag = false
            continue
        }
        if !insideTag {
            result.append(character)
        }
    }
    return result
        .replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&amp;", with: "&")
        .replacingOccurrences(of: "&quot;", with: "\"")
}

private func tlvTypeSummary(_ tlvs: [UInt16: [Data]]) -> String {
    tlvs.keys.sorted()
        .map { "0x" + String($0, radix: 16) }
        .joined(separator: ", ")
}

private func authFailureMessage(tlvs: [UInt16: [Data]], fallbackTypes: String, payload: Data) -> String {
    let screenName = tlvs[TlvType.screenName]?.first?.utf8String
    let errorCode = tlvs[0x0008]?.first.flatMap { value -> UInt16? in
        guard value.count >= 2 else { return nil }
        return value.uint16(at: 0)
    }

    if let errorCode {
        let who = screenName.map { " for \($0)" } ?? ""
        if errorCode == 0x0005 {
            return "Authentication failed\(who). The server rejected this login. If the password is correct, sign out of any other AIM client using this screen name or use a second account."
        }

        return "Authentication failed\(who). Server error code 0x\(String(errorCode, radix: 16)). Check that the login screen name and password are correct."
    }

    return "Authentication failed. Server returned TLV types: \(fallbackTypes.isEmpty ? "none" : fallbackTypes). Payload: \(payload.hexSummary)"
}

private extension Data {
    init(hexString: String) {
        var bytes = Data()
        var buffer = ""

        for character in hexString where character.isHexDigit {
            buffer.append(character)
            if buffer.count == 2 {
                bytes.append(UInt8(buffer, radix: 16) ?? 0)
                buffer = ""
            }
        }

        self = bytes
    }
}

private extension Error {
    var userMessage: String {
        let message = localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "Unknown error" : message
    }
}
