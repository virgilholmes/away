import Foundation

enum FlapChannel: UInt8 {
    case signon = 0x01
    case data = 0x02
    case error = 0x03
    case close = 0x04
    case keepalive = 0x05
}

enum SnacFamily: UInt16 {
    case oservice = 0x0001
    case location = 0x0002
    case buddy = 0x0003
    case icbm = 0x0004
    case bos = 0x0009
}

enum TlvType {
    static let screenName: UInt16 = 0x0001
    static let password: UInt16 = 0x0002
    static let clientId: UInt16 = 0x0003
    static let bosHost: UInt16 = 0x0005
    static let bosAuthCookie: UInt16 = 0x0006
}

struct FlapFrame {
    let channel: FlapChannel
    let sequence: UInt16
    let payload: Data
}

struct Snac {
    let family: UInt16
    let subtype: UInt16
    let payload: Data
}

struct IncomingMessage: Identifiable, Codable {
    let id = UUID()
    let direction: MessageDirection
    let from: String
    let to: String
    let text: String
    let date = Date()
}

struct ChatRoom: Identifiable, Codable {
    let id: Int
    var name: String
    var participants: [String] = []
}

struct ChatRoomMessage: Identifiable, Codable {
    let id = UUID()
    let roomId: Int
    let roomName: String
    let from: String
    let text: String
    let isOutgoing: Bool
    let date = Date()
}

enum MessageDirection: Codable {
    case incoming
    case outgoing
    case system
}

struct ByteWriter {
    private(set) var data = Data()

    mutating func u8(_ value: UInt8) {
        data.append(value)
    }

    mutating func u16(_ value: UInt16) {
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    mutating func u32(_ value: UInt32) {
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    mutating func u64(_ value: UInt64) {
        u32(UInt32((value >> 32) & 0xffff_ffff))
        u32(UInt32(value & 0xffff_ffff))
    }

    mutating func bytes(_ value: Data) {
        data.append(value)
    }

    mutating func string(_ value: String) {
        data.append(Data(value.utf8))
    }

    mutating func tlv(_ type: UInt16, _ value: Data) {
        u16(type)
        u16(UInt16(value.count))
        bytes(value)
    }

    mutating func tlv(_ type: UInt16, _ value: String) {
        tlv(type, Data(value.utf8))
    }
}

extension Data {
    func uint8(at offset: Int) -> UInt8 {
        self[startIndex + offset]
    }

    func uint16(at offset: Int) -> UInt16 {
        (UInt16(uint8(at: offset)) << 8) | UInt16(uint8(at: offset + 1))
    }

    func uint32(at offset: Int) -> UInt32 {
        (UInt32(uint16(at: offset)) << 16) | UInt32(uint16(at: offset + 2))
    }

    func slice(_ offset: Int, _ length: Int) -> Data {
        subdata(in: offset..<(offset + length))
    }

    var utf8String: String {
        String(data: self, encoding: .utf8) ?? ""
    }

    var hexSummary: String {
        map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}

func parseTlvs(_ data: Data) throws -> [UInt16: [Data]] {
    var result: [UInt16: [Data]] = [:]
    var offset = 0

    while offset + 4 <= data.count {
        let type = data.uint16(at: offset)
        let length = Int(data.uint16(at: offset + 2))
        offset += 4

        guard offset + length <= data.count else {
            throw OscarError.protocolError("TLV length exceeds payload")
        }

        result[type, default: []].append(data.slice(offset, length))
        offset += length
    }

    return result
}

func roastPassword(_ password: String) -> Data {
    let key = Array("Tic/Toc".utf8)
    let bytes = Array(password.utf8)
    return Data(bytes.enumerated().map { index, byte in
        byte ^ key[index % key.count]
    })
}

func screenNameBuffer(_ screenName: String) -> Data {
    var writer = ByteWriter()
    let bytes = Data(screenName.utf8)
    writer.u8(UInt8(bytes.count))
    writer.bytes(bytes)
    return writer.data
}

func parseSnac(_ payload: Data) throws -> Snac {
    guard payload.count >= 10 else {
        throw OscarError.protocolError("SNAC payload is too short")
    }

    return Snac(
        family: payload.uint16(at: 0),
        subtype: payload.uint16(at: 2),
        payload: payload.subdata(in: 10..<payload.count)
    )
}

func buildSnac(family: UInt16, subtype: UInt16, payload: Data = Data(), requestId: UInt32) -> Data {
    var writer = ByteWriter()
    writer.u16(family)
    writer.u16(subtype)
    writer.u16(0)
    writer.u32(requestId)
    writer.bytes(payload)
    return writer.data
}

func parseIncomingInstantMessage(_ payload: Data) throws -> (from: String, text: String) {
    guard payload.count >= 10 else {
        throw OscarError.protocolError("ICBM payload is too short")
    }

    var offset = 10
    let parsed = try parseScreenName(payload, offset: offset)
    offset = parsed.offset

    guard offset + 4 <= payload.count else {
        throw OscarError.protocolError("Incoming message missing user metadata")
    }

    offset += 2
    let userTlvCount = Int(payload.uint16(at: offset))
    offset += 2

    for _ in 0..<userTlvCount {
        guard offset + 4 <= payload.count else {
            throw OscarError.protocolError("User TLV exceeds payload")
        }
        let length = Int(payload.uint16(at: offset + 2))
        offset += 4 + length
    }

    let tlvs = try parseTlvs(payload.subdata(in: offset..<payload.count))
    let text = (tlvs[0x0002] ?? [])
        .map(extractMessageText)
        .filter { !$0.isEmpty }
        .joined(separator: "\n")

    return (from: parsed.value, text: text)
}

private func parseScreenName(_ data: Data, offset: Int) throws -> (value: String, offset: Int) {
    guard offset < data.count else {
        throw OscarError.protocolError("Missing screen name")
    }

    let length = Int(data.uint8(at: offset))
    let start = offset + 1
    let end = start + length
    guard end <= data.count else {
        throw OscarError.protocolError("Screen name exceeds payload")
    }

    return (data.slice(start, length).utf8String, end)
}

private func extractMessageText(_ block: Data) -> String {
    var offset = 0
    var text = ""

    while offset + 4 <= block.count {
        let fragmentId = block.uint16(at: offset)
        let length = Int(block.uint16(at: offset + 2))
        offset += 4

        guard offset + length <= block.count else {
            break
        }

        let value = block.slice(offset, length)
        offset += length

        if fragmentId == 0x0101, value.count >= 4 {
            text += value.subdata(in: 4..<value.count).utf8String
        }
    }

    return text
}

enum OscarError: LocalizedError {
    case connectionFailed(String)
    case protocolError(String)
    case authenticationFailed(String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let message), .protocolError(let message), .authenticationFailed(let message):
            message
        }
    }
}
