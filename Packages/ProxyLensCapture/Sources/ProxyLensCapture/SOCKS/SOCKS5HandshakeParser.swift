import Foundation

struct SOCKS5HandshakeParser {
    static let maximumNegotiationBytes = 512
    static let successReply: [UInt8] = [0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]

    enum Action: Equatable {
        case write([UInt8])
        case connect(ConnectTarget, leftover: [UInt8])
        case close
    }

    private enum State {
        case greeting
        case request
        case established
        case closed
    }

    private var state = State.greeting
    private var buffer: [UInt8] = []
    private var consumedNegotiationBytes = 0

    static func failureReply(code: UInt8) -> [UInt8] {
        [0x05, code, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
    }

    mutating func receive(_ bytes: [UInt8]) -> [Action] {
        guard !bytes.isEmpty, state != .closed, state != .established else { return [] }
        buffer.append(contentsOf: bytes)

        var actions: [Action] = []
        while true {
            let progressed: Bool
            switch state {
            case .greeting:
                progressed = parseGreeting(into: &actions)
            case .request:
                progressed = parseRequest(into: &actions)
            case .established, .closed:
                return actions
            }

            if state != .established, state != .closed,
                consumedNegotiationBytes + buffer.count > Self.maximumNegotiationBytes
            {
                state = .closed
                buffer.removeAll(keepingCapacity: false)
                actions.append(.close)
                return actions
            }
            if !progressed { return actions }
        }
    }

    private mutating func parseGreeting(into actions: inout [Action]) -> Bool {
        guard buffer.count >= 2 else { return false }
        guard buffer[0] == 0x05 else {
            close(into: &actions)
            return true
        }

        let methodCount = Int(buffer[1])
        let byteCount = 2 + methodCount
        guard buffer.count >= byteCount else { return false }
        let methods = buffer[2..<byteCount]
        consume(byteCount)

        guard methods.contains(0x00) else {
            actions.append(.write([0x05, 0xff]))
            close(into: &actions)
            return true
        }

        actions.append(.write([0x05, 0x00]))
        state = .request
        return true
    }

    private mutating func parseRequest(into actions: inout [Action]) -> Bool {
        guard buffer.count >= 4 else { return false }
        guard buffer[0] == 0x05, buffer[2] == 0x00 else {
            fail(code: 0x01, into: &actions)
            return true
        }
        guard buffer[1] == 0x01 else {
            fail(code: 0x07, into: &actions)
            return true
        }

        let addressStart = 4
        let addressByteCount: Int
        switch buffer[3] {
        case 0x01:
            addressByteCount = 4
        case 0x03:
            guard buffer.count >= 5 else { return false }
            guard buffer[4] > 0 else {
                fail(code: 0x01, into: &actions)
                return true
            }
            addressByteCount = 1 + Int(buffer[4])
        case 0x04:
            addressByteCount = 16
        default:
            fail(code: 0x08, into: &actions)
            return true
        }

        let byteCount = addressStart + addressByteCount + 2
        guard buffer.count >= byteCount else { return false }
        guard consumedNegotiationBytes + byteCount <= Self.maximumNegotiationBytes else {
            close(into: &actions)
            return true
        }

        let host: String?
        switch buffer[3] {
        case 0x01:
            host = buffer[addressStart..<(addressStart + 4)].map(String.init).joined(separator: ".")
        case 0x03:
            let domainStart = addressStart + 1
            let domainEnd = domainStart + Int(buffer[addressStart])
            host = String(bytes: buffer[domainStart..<domainEnd], encoding: .utf8)
        case 0x04:
            host = stride(from: addressStart, to: addressStart + 16, by: 2).map { index in
                String(format: "%x", UInt16(buffer[index]) << 8 | UInt16(buffer[index + 1]))
            }.joined(separator: ":")
        default:
            host = nil
        }

        let portIndex = byteCount - 2
        let port = Int(UInt16(buffer[portIndex]) << 8 | UInt16(buffer[portIndex + 1]))
        guard let host, port > 0, let target = try? ConnectTarget(host: host, port: port) else {
            fail(code: 0x01, into: &actions)
            return true
        }

        consumedNegotiationBytes += byteCount
        buffer.removeFirst(byteCount)
        let leftover = buffer
        buffer.removeAll(keepingCapacity: false)
        state = .established
        actions.append(.write(Self.successReply))
        actions.append(.connect(target, leftover: leftover))
        return true
    }

    private mutating func consume(_ byteCount: Int) {
        consumedNegotiationBytes += byteCount
        buffer.removeFirst(byteCount)
    }

    private mutating func fail(code: UInt8, into actions: inout [Action]) {
        actions.append(.write(Self.failureReply(code: code)))
        close(into: &actions)
    }

    private mutating func close(into actions: inout [Action]) {
        state = .closed
        buffer.removeAll(keepingCapacity: false)
        actions.append(.close)
    }
}
