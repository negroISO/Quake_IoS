import Foundation
@preconcurrency import Network

final class DebugTelemetry: @unchecked Sendable {
    static let shared = DebugTelemetry()

    private let queue = DispatchQueue(label: "com.quake3ios.debug.telemetry")
    private var connection: NWConnection?
    private var pending: [Data] = []
    private var isReady = false

    private init() {}

    func connect(host: String, port: UInt16 = 8765, source: String) {
#if DEBUG
        queue.async {
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port)!,
                using: .tcp
            )

            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                self.queue.async {
                    switch state {
                    case .ready:
                        NSLog("[Q3-TELEMETRY] connected to %@:%d", host, Int32(port))
                        self.isReady = true
                        self.enqueue(source: source, type: "client_ready", message: nil, fields: [
                            "host": host,
                            "port": Int(port)
                        ])
                        self.flushPending()
                    case .failed(let error):
                        NSLog("[Q3-TELEMETRY] connection failed: %@", String(describing: error))
                        self.isReady = false
                    case .cancelled:
                        NSLog("[Q3-TELEMETRY] connection cancelled")
                        self.isReady = false
                    default:
                        break
                    }
                }
            }

            self.connection?.cancel()
            self.connection = connection
            self.isReady = false
            self.enqueue(source: source, type: "connect_start", message: "\(host):\(port)", fields: [
                "host": host,
                "port": Int(port)
            ])
            connection.start(queue: self.queue)
        }
#endif
    }

    func log(source: String, type: String = "log", message: String? = nil, fields: [String: Any] = [:]) {
#if DEBUG
        guard let data = Self.encode(source: source, type: type, message: message, fields: fields) else {
            NSLog("[Q3-TELEMETRY] dropped invalid JSON event: %@", type)
            return
        }
        queue.async {
            self.send(data)
        }
#endif
    }

    private func enqueue(source: String, type: String, message: String?, fields: [String: Any]) {
        guard let data = Self.encode(source: source, type: type, message: message, fields: fields) else {
            NSLog("[Q3-TELEMETRY] dropped invalid JSON event: %@", type)
            return
        }

        send(data)
    }

    private static func encode(source: String, type: String, message: String?, fields: [String: Any]) -> Data? {
        var event = fields
        event["source"] = source
        event["type"] = type
        if let message {
            event["message"] = message
        }
        event["ts"] = Date().timeIntervalSince1970

        guard JSONSerialization.isValidJSONObject(event),
              var data = try? JSONSerialization.data(withJSONObject: event) else {
            return nil
        }

        data.append(0x0a)
        return data
    }

    private func send(_ data: Data) {
        guard isReady, let connection else {
            pending.append(data)
            if pending.count > 500 {
                pending.removeFirst(pending.count - 500)
            }
            return
        }

        connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                NSLog("[Q3-TELEMETRY] send failed: %@", String(describing: error))
            }
        })
    }

    private func flushPending() {
        let buffered = pending
        pending.removeAll(keepingCapacity: true)
        buffered.forEach(send)
    }
}

@_cdecl("Q3DebugTelemetry_Log")
func Q3DebugTelemetry_Log(_ typePointer: UnsafePointer<CChar>?, _ messagePointer: UnsafePointer<CChar>?) {
#if DEBUG
    let type = typePointer.map { String(cString: $0) } ?? "native_log"
    let message = messagePointer.map { String(cString: $0) } ?? ""
    DebugTelemetry.shared.log(source: "quake3-ios", type: type, message: message)
#endif
}
