internal import CPCSC
import Foundation

public final class PCSCTransport: APDUTransport, @unchecked Sendable {
    private static let scopeSystem: UInt32 = 0x0002
    private static let shareShared: UInt32 = 0x0002
    private static let protocolT0T1: UInt32 = 0x0003
    private static let leaveCard: UInt32 = 0x0000
    private static let noReadersAvailable: UInt32 = 0x8010_002E
    /// Card removed, reset or absent: later operations on this connection cannot succeed.
    private static let cardGone: Set<UInt32> = [0x8010_0069, 0x8010_0068, 0x8010_000C]
    /// Extended-length response (65535 data bytes) + SW1SW2.
    private static let receiveBufferSize = 65_538

    public let atr: Data

    /// PC/SC calls block, so they run on this serial queue; the vars below are touched only there.
    private let queue = DispatchQueue(label: "io.wsagency.cardcore.pcsc")
    private var context: SCARDCONTEXT
    private var handle: SCARDHANDLE
    private let activeProtocol: UInt32
    private var connected = true
    private var receiveBuffer = [UInt8](repeating: 0, count: PCSCTransport.receiveBufferSize)

    public static func readers() throws -> [String] {
        var context: SCARDCONTEXT = 0
        try check(SCardEstablishContext(scopeSystem, nil, nil, &context))
        defer { SCardReleaseContext(context) }

        var length: UInt32 = 0
        var rc = SCardListReaders(context, nil, nil, &length)
        if UInt32(bitPattern: rc) == noReadersAvailable { return [] }
        try check(rc)
        guard length > 1 else { return [] }

        var buffer = [CChar](repeating: 0, count: Int(length))
        rc = SCardListReaders(context, nil, &buffer, &length)
        if UInt32(bitPattern: rc) == noReadersAvailable { return [] }
        try check(rc)
        return buffer.split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
    }

    public init(readerName: String) throws {
        var context: SCARDCONTEXT = 0
        try Self.check(SCardEstablishContext(Self.scopeSystem, nil, nil, &context))

        var handle: SCARDHANDLE = 0
        var activeProtocol: UInt32 = 0
        var rc = SCardConnect(context, readerName, Self.shareShared, Self.protocolT0T1, &handle, &activeProtocol)
        guard rc == 0 else {
            SCardReleaseContext(context)
            throw Self.error(rc)
        }

        var names = [CChar](repeating: 0, count: 256)
        var namesLength = UInt32(names.count)
        var state: UInt32 = 0
        var statusProtocol: UInt32 = 0
        var atrBuffer = [UInt8](repeating: 0, count: 33)
        var atrLength = UInt32(atrBuffer.count)
        rc = SCardStatus(handle, &names, &namesLength, &state, &statusProtocol, &atrBuffer, &atrLength)
        guard rc == 0 else {
            SCardDisconnect(handle, Self.leaveCard)
            SCardReleaseContext(context)
            throw Self.error(rc)
        }

        self.atr = Data(atrBuffer.prefix(Int(atrLength)))
        self.context = context
        self.handle = handle
        self.activeProtocol = activeProtocol
    }

    deinit { disconnect() }

    public func transmit(_ apdu: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try self.transmitBlocking(apdu) }) }
        }
    }

    public func close() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.disconnect()
                continuation.resume()
            }
        }
    }

    private func transmitBlocking(_ apdu: Data) throws -> Data {
        guard connected else { throw CardError.transport("reader connection closed") }
        var sendPci = SCARD_IO_REQUEST(dwProtocol: activeProtocol, cbPciLength: UInt32(MemoryLayout<SCARD_IO_REQUEST>.size))
        var received = UInt32(receiveBuffer.count)
        let rc = apdu.withUnsafeBytes { raw in
            SCardTransmit(handle, &sendPci, raw.bindMemory(to: UInt8.self).baseAddress, UInt32(apdu.count), nil, &receiveBuffer, &received)
        }
        guard rc == 0 else { throw Self.error(rc) }
        return Data(receiveBuffer.prefix(Int(received)))
    }

    private func disconnect() {
        guard connected else { return }
        connected = false
        SCardDisconnect(handle, Self.leaveCard)
        SCardReleaseContext(context)
    }

    private static func check(_ rc: Int32) throws {
        if rc != 0 { throw error(rc) }
    }

    private static func error(_ rc: Int32) -> CardError {
        let code = UInt32(bitPattern: rc)
        return cardGone.contains(code) ? .cardRemoved : .transport(String(format: "PC/SC error 0x%08X", code))
    }
}
