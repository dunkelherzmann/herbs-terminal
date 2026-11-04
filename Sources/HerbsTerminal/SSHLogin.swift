import Darwin
import Foundation

struct SSHLogin: Equatable, Identifiable {
    struct ID: Hashable {
        let host: String
        let port: Int
        let username: String
    }

    let host: String
    let port: Int
    let username: String
    let password: String

    var id: ID { ID(host: host.lowercased(), port: port, username: username) }
    var label: String { "\(username)@\(host) (\(port))" }

    func validate() throws {
        var ipv6 = in6_addr()
        var ipv4 = in_addr()
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let dns = !host.isEmpty && host.utf8.count <= 253 && labels.allSatisfy { part in
            !part.isEmpty && part.count <= 63 && part.first != "-" && part.last != "-" &&
                part.utf8.allSatisfy { byte in
                    (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 45 || byte == 95
                }
        }
        let dottedNumber = host.contains(".") && host.utf8.allSatisfy { (48...57).contains($0) || $0 == 46 }
        guard !host.contains("\0"), inet_pton(AF_INET6, host, &ipv6) == 1 ||
                inet_pton(AF_INET, host, &ipv4) == 1 || (dns && !dottedNumber) else {
            throw LoginError("Enter a valid hostname, SSH alias, or IP address.")
        }
        guard (1...65535).contains(port) else { throw LoginError("Port must be between 1 and 65535.") }
        guard !username.isEmpty, username.first != "-", !username.contains("@"),
              !username.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) else {
            throw LoginError("Enter a valid SSH username.")
        }
    }
}

struct LoginError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

enum LoginCSV {
    static func encode(_ rows: [SSHLogin]) -> Data {
        let records = [["host", "port", "username", "password"]] + rows.map { [$0.host, String($0.port), $0.username, $0.password] }
        let formatted = records.map { record in
            record.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",")
        }
        return Data((formatted.joined(separator: "\r\n") + "\r\n").utf8)
    }

    static func decode(_ data: Data) throws -> [SSHLogin] {
        guard String(data: data, encoding: .utf8) != nil else { throw LoginError("CSV must be UTF-8.") }
        let bytes = Array(data)
        var index = bytes.starts(with: [0xef, 0xbb, 0xbf]) ? 3 : 0
        var records = [[String]]()
        var row = [String]()
        var field = [UInt8]()
        var quoted = false
        var closed = false
        func finishField() {
            row.append(String(decoding: field, as: UTF8.self))
            field.removeAll(keepingCapacity: true)
            closed = false
        }
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if quoted {
                if byte != 34 { field.append(byte); continue }
                if index < bytes.count, bytes[index] == 34 {
                    field.append(34)
                    index += 1
                } else { quoted = false; closed = true }
            } else if byte == 44 {
                finishField()
            } else if byte == 10 || byte == 13 {
                if byte == 13, index < bytes.count, bytes[index] == 10 { index += 1 }
                finishField()
                records.append(row)
                row.removeAll(keepingCapacity: true)
            } else if byte == 34 && field.isEmpty && !closed {
                quoted = true
            } else {
                guard !closed, byte != 34 else { throw LoginError("Invalid quotation in CSV record \(records.count + 1).") }
                field.append(byte)
            }
        }
        guard !quoted else { throw LoginError("Unclosed quotation in CSV.") }
        if !row.isEmpty || !field.isEmpty || closed { finishField(); records.append(row) }
        guard records.first == ["host", "port", "username", "password"] else {
            throw LoginError("Expected CSV header host,port,username,password.")
        }
        return try records.dropFirst().enumerated().map { offset, record in
            guard record.count == 4, let port = Int(record[1]) else { throw LoginError("Invalid CSV record \(offset + 2).") }
            let login = SSHLogin(host: record[0], port: port, username: record[2], password: record[3])
            do { try login.validate() } catch { throw LoginError("Record \(offset + 2): \(error.localizedDescription)") }
            return login
        }
    }
}
