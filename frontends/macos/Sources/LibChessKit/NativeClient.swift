import CLibChess
import Foundation

private let nativeEventCallback: libchess_event_callback_t = { context, bytes, length in
    guard let context, let bytes else {
        return
    }

    let relay = Unmanaged<EventRelay>.fromOpaque(context).takeUnretainedValue()
    relay.receive(Data(bytes: bytes, count: length))
}

private final class EventRelay: @unchecked Sendable {
    private let handler: @MainActor @Sendable (Data) -> Void

    init(handler: @escaping @MainActor @Sendable (Data) -> Void) {
        self.handler = handler
    }

    func receive(_ data: Data) {
        Task { @MainActor [handler] in
            handler(data)
        }
    }
}

enum NativeClientError: LocalizedError {
    case couldNotCreate
    case sendFailed(Int32)
    case unsupportedAPIVersion(expected: UInt32, actual: UInt32)

    var errorDescription: String? {
        switch self {
        case .couldNotCreate:
            "LibChess could not start its worker."
        case let .sendFailed(code):
            "LibChess rejected a command with code \(code)."
        case let .unsupportedAPIVersion(expected, actual):
            "The native wrapper expects LibChess API \(expected), but loaded API \(actual)."
        }
    }
}

private final class NativeHandle: @unchecked Sendable {
    let pointer: OpaquePointer
    private let relay: EventRelay

    init(_ pointer: OpaquePointer, relay: EventRelay) {
        self.pointer = pointer
        self.relay = relay
    }

    deinit {
        libchess_client_destroy(pointer)
    }
}

@MainActor
final class NativeClient {
    private let handle: NativeHandle

    init(handler: @escaping @MainActor @Sendable (Data) -> Void) throws {
        let actualVersion = libchess_api_version()
        guard actualVersion == LIBCHESS_API_VERSION else {
            throw NativeClientError.unsupportedAPIVersion(
                expected: LIBCHESS_API_VERSION,
                actual: actualVersion
            )
        }

        let relay = EventRelay(handler: handler)
        guard let pointer = libchess_client_create(
            nativeEventCallback,
            Unmanaged.passUnretained(relay).toOpaque()
        ) else {
            throw NativeClientError.couldNotCreate
        }
        self.handle = NativeHandle(pointer, relay: relay)
    }

    func send<Command: Encodable>(_ command: Command) throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(command)
        let result = data.withUnsafeBytes { rawBuffer -> Int32 in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            return libchess_client_send(handle.pointer, bytes.baseAddress, bytes.count)
        }
        guard result == Int32(LIBCHESS_SEND_OK.rawValue) else {
            throw NativeClientError.sendFailed(result)
        }
    }
}
