import Darwin
import Foundation

struct NetworkSpeedSample: Equatable {
    let uploadBytesPerSecond: UInt64
    let downloadBytesPerSecond: UInt64
}

@MainActor
final class NetworkSpeedMonitor {
    var onUpdate: ((NetworkSpeedSample) -> Void)?

    private var timer: Timer?
    private var previousCounters: NetworkByteCounters?
    private var previousDate: Date?

    func start() {
        stop()
        previousCounters = readCounters()
        previousDate = Date()
        publishSample()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.publishSample()
            }
        }
        timer?.tolerance = 0.15
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        previousCounters = nil
        previousDate = nil
    }

    private func publishSample() {
        let now = Date()
        let counters = readCounters()
        defer {
            previousCounters = counters
            previousDate = now
        }

        guard let previousCounters, let previousDate else {
            onUpdate?(.init(uploadBytesPerSecond: 0, downloadBytesPerSecond: 0))
            return
        }

        let interval = max(now.timeIntervalSince(previousDate), 0.001)
        let uploadDelta = counters.uploadBytes >= previousCounters.uploadBytes
            ? counters.uploadBytes - previousCounters.uploadBytes
            : 0
        let downloadDelta = counters.downloadBytes >= previousCounters.downloadBytes
            ? counters.downloadBytes - previousCounters.downloadBytes
            : 0
        onUpdate?(
            .init(
                uploadBytesPerSecond: UInt64(Double(uploadDelta) / interval),
                downloadBytesPerSecond: UInt64(Double(downloadDelta) / interval)
            )
        )
    }

    private func readCounters() -> NetworkByteCounters {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let interfaces else {
            return .zero
        }
        defer { freeifaddrs(interfaces) }

        var uploadBytes: UInt64 = 0
        var downloadBytes: UInt64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = interfaces
        while let interface = cursor?.pointee {
            defer { cursor = interface.ifa_next }

            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK) else {
                continue
            }
            let flags = Int32(interface.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else {
                continue
            }
            guard let dataPointer = interface.ifa_data else { continue }

            let data = dataPointer.assumingMemoryBound(to: if_data.self).pointee
            uploadBytes += UInt64(data.ifi_obytes)
            downloadBytes += UInt64(data.ifi_ibytes)
        }
        return NetworkByteCounters(uploadBytes: uploadBytes, downloadBytes: downloadBytes)
    }
}

private struct NetworkByteCounters {
    let uploadBytes: UInt64
    let downloadBytes: UInt64

    static let zero = NetworkByteCounters(uploadBytes: 0, downloadBytes: 0)
}
