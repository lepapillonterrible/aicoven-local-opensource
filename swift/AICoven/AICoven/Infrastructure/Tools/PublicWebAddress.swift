import Darwin
import Foundation

/// Whether an address a model gives `web_browse` is on the public web: not
/// this device, not the network it is on, and not a name only that network
/// knows. A page a model was told to read can say "browse this address":
/// what answers on the person's own network (a router, a printer, a server
/// still being built, its `.env`) is not read and handed to the model.
nonisolated enum PublicWebAddress {
    /// Whether `url` reads as a public address: http or https, no user or
    /// password, a host that is a public IP address or a name with a dot
    /// in it that is not one of the names a local network uses.
    static func reads(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        guard url.user == nil, url.password == nil else { return false }
        guard var host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return false }
        if host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if let address = IPAddress(host) { return address.isPublic }
        // A name: with a dot in it, and not one only a local network knows.
        guard host.contains("."), !host.hasPrefix("."), !host.contains("..") else { return false }
        let localSuffixes = [".localhost", ".local", ".internal", ".intranet", ".lan", ".home", ".corp", ".home.arpa", ".localdomain", ".test", ".invalid"]
        return host != "localhost" && !localSuffixes.contains { host.hasSuffix($0) }
    }

    /// Whether every address `url`'s host names is public, as this device
    /// resolves it now. An IP address is itself; a name that does not
    /// resolve is not public. (A name can resolve differently a moment
    /// later; what is fetched is checked again at each redirect.)
    @concurrent
    static func resolvesPublicly(_ url: URL) async -> Bool {
        guard reads(url), let host = url.host(percentEncoded: false) else { return false }
        let written = IPAddress(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
        let addresses = written.map { [$0] } ?? addresses(of: host)
        // A public address can still be this device's own, or one on the
        // network it is on (an IPv6 network gives every device one).
        let local = LocalNetwork.current()
        return !addresses.isEmpty && addresses.allSatisfy { $0.isPublic && !local.contains($0) }
    }

    /// This device's own addresses and the networks they are on, as its
    /// interfaces say now.
    struct LocalNetwork {
        /// (address, netmask) of each interface, as bytes.
        let interfaces: [(address: [UInt8], mask: [UInt8])]

        func contains(_ address: IPAddress) -> Bool {
            let bytes = address.bytes
            return interfaces.contains { interface in
                guard interface.address.count == bytes.count, interface.mask.count == bytes.count else { return false }
                return zip(zip(interface.address, interface.mask), bytes).allSatisfy { pair, byte in pair.0 & pair.1 == byte & pair.1 }
            }
        }

        static func current() -> LocalNetwork {
            var first: UnsafeMutablePointer<ifaddrs>?
            guard getifaddrs(&first) == 0, let list = first else { return LocalNetwork(interfaces: []) }
            defer { freeifaddrs(list) }
            var found: [(address: [UInt8], mask: [UInt8])] = []
            var next: UnsafeMutablePointer<ifaddrs>? = list
            while let entry = next {
                // An interface with no mask (some tunnels) says nothing of
                // a network: it would take in every address.
                if let address = entry.pointee.ifa_addr, let mask = entry.pointee.ifa_netmask,
                   let one = bytes(of: address), let other = bytes(of: mask), one.count == other.count, other.contains(where: { $0 != 0 }) {
                    found.append((one, other))
                }
                next = entry.pointee.ifa_next
            }
            return LocalNetwork(interfaces: found)
        }

        private static func bytes(of address: UnsafeMutablePointer<sockaddr>) -> [UInt8]? {
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) } }
            case AF_INET6:
                address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) } }
            default:
                nil
            }
        }
    }

    /// The addresses `host` resolves to on this device.
    private static func addresses(of host: String) -> [IPAddress] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return [] }
        defer { freeaddrinfo(first) }
        var found: [IPAddress] = []
        var next: UnsafeMutablePointer<addrinfo>? = first
        while let entry = next {
            if let address = entry.pointee.ai_addr {
                switch Int32(address.pointee.sa_family) {
                case AF_INET:
                    address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { found.append(.v4(UInt32(bigEndian: $0.pointee.sin_addr.s_addr))) }
                case AF_INET6:
                    address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                        let bytes = withUnsafeBytes(of: pointer.pointee.sin6_addr) { Array($0) }
                        found.append(.v6(bytes))
                    }
                default:
                    break
                }
            }
            next = entry.pointee.ai_next
        }
        return found
    }

    /// An IP address, as a host is written or as it resolves.
    enum IPAddress: Equatable {
        case v4(UInt32)
        case v6([UInt8])

        /// Reads `text` as an IP address: IPv6, or IPv4 in any form a
        /// system takes (dotted, a single number, hexadecimal or octal
        /// parts), so that `2130706433` or `0x7f.1` is known as 127.0.0.1.
        init?(_ text: String) {
            var v6 = in6_addr()
            if text.contains(":"), inet_pton(AF_INET6, text, &v6) == 1 {
                self = .v6(withUnsafeBytes(of: v6) { Array($0) })
                return
            }
            // Only what is made of digits, dots and hexadecimal is tried
            // as IPv4: a name is not.
            let allowed = CharacterSet(charactersIn: "0123456789abcdefxABCDEFX.")
            guard !text.isEmpty, text.unicodeScalars.allSatisfy(allowed.contains), text.first?.isNumber == true else { return nil }
            var v4 = in_addr()
            guard inet_aton(text, &v4) == 1 else { return nil }
            self = .v4(UInt32(bigEndian: v4.s_addr))
        }

        /// Its bytes, in network order.
        var bytes: [UInt8] {
            switch self {
            case let .v4(value):
                withUnsafeBytes(of: value.bigEndian) { Array($0) }
            case let .v6(bytes):
                bytes
            }
        }

        /// Whether it is an address of the public internet.
        var isPublic: Bool {
            switch self {
            case let .v4(value):
                Self.isPublicV4(value)
            case let .v6(bytes):
                Self.isPublicV6(bytes)
            }
        }

        private static func isPublicV4(_ value: UInt32) -> Bool {
            // (network, prefix length) of what is not the public internet.
            let reserved: [(UInt32, UInt32)] = [
                (0x0000_0000, 8), // this network
                (0x0A00_0000, 8), // private
                (0x6440_0000, 10), // carrier-grade NAT
                (0x7F00_0000, 8), // loopback
                (0xA9FE_0000, 16), // link-local (and cloud metadata)
                (0xAC10_0000, 12), // private
                (0xC000_0000, 24), // IETF protocol assignments
                (0xC000_0200, 24), // documentation
                (0xC058_6300, 24), // 6to4 relay
                (0xC0A8_0000, 16), // private
                (0xC612_0000, 15), // benchmarking
                (0xC633_6400, 24), // documentation
                (0xCB00_7100, 24), // documentation
                (0xE000_0000, 4), // multicast
                (0xF000_0000, 4), // reserved, and broadcast
            ]
            return !reserved.contains { network, length in
                let mask: UInt32 = length == 0 ? 0 : ~UInt32(0) << (32 - length)
                return value & mask == network
            }
        }

        private static func isPublicV6(_ bytes: [UInt8]) -> Bool {
            guard bytes.count == 16 else { return false }
            // An IPv4 address written as IPv6 (::ffff:a.b.c.d, and the
            // NAT64 prefix 64:ff9b::) is its IPv4 address.
            if bytes[0 ..< 10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
                return isPublicV4(bytes[12 ..< 16].reduce(0) { $0 << 8 | UInt32($1) })
            }
            if bytes[0 ..< 12] == [0x00, 0x64, 0xFF, 0x9B, 0, 0, 0, 0, 0, 0, 0, 0] {
                return isPublicV4(bytes[12 ..< 16].reduce(0) { $0 << 8 | UInt32($1) })
            }
            if bytes.allSatisfy({ $0 == 0 }) { return false } // ::
            if bytes[0 ..< 15].allSatisfy({ $0 == 0 }), bytes[15] == 1 { return false } // ::1
            if bytes[0] & 0xFE == 0xFC { return false } // unique local fc00::/7
            if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 { return false } // link-local fe80::/10
            if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0xC0 { return false } // site-local fec0::/10
            if bytes[0] == 0xFF { return false } // multicast
            // IETF protocol assignments 2001::/23 (benchmarking, ORCHID,
            // documentation 2001:db8::/32 among them) and documentation
            // 3fff::/20 are no one's public address.
            if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] & 0xFE == 0x00 { return false }
            if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x0D, bytes[3] == 0xB8 { return false }
            if bytes[0] == 0x3F, bytes[1] == 0xFF, bytes[2] & 0xF0 == 0x00 { return false }
            // 6to4 2002::/16 carries an IPv4 address: it is that address.
            if bytes[0] == 0x20, bytes[1] == 0x02 {
                return isPublicV4(bytes[2 ..< 6].reduce(0) { $0 << 8 | UInt32($1) })
            }
            // Only global unicast (2000::/3) is the public internet.
            return bytes[0] & 0xE0 == 0x20
        }
    }
}
