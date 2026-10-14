// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation

/// Why a CSV file could not be used as a whole. Carries a line number or nothing: never a field, a header or the
/// system's own error text, since any of them can contain a password.
nonisolated enum CredentialCSVError: Error, Equatable, Sendable {
    case tooLarge
    case notUTF8
    /// A quote that is never closed, or a quote in the middle of an unquoted field; `line` is where the field began.
    case unreadable(line: Int)
    /// The chosen file could not be opened or read.
    case cannotRead
    /// The header lacks the URL, Username or Password column.
    case missingColumns
    /// The header names the URL, Username, Password, title, notes or code column twice: there is no single right one to read.
    case ambiguousColumns
    case tooManyAccounts
    case notWritten
}

/// RFC 4180 CSV, which is what Passwords imports and exports. Pure except `read` and `save`, the only file access.
nonisolated enum CredentialCSV {
    struct Row: Equatable, Sendable {
        /// The physical line the row began on, for reports.
        let line: Int
        let fields: [String]
    }

    /// Splits `data` into rows. A UTF-8 byte order mark, CRLF, LF or CR line ends and quoted fields (commas, line breaks and
    /// doubled quotes inside) are accepted; empty lines are skipped. Anything else that is not CSV rejects the whole file.
    static func parse(_ data: Data) throws -> [Row] {
        guard data.count <= CredentialVaultLimits.payloadBytes else { throw CredentialCSVError.tooLarge }
        guard let text = String(validating: data, as: UTF8.self) else { throw CredentialCSVError.notUTF8 }
        // One pass over the string's own scalar view: no second copy of the file is made.
        let scalars = text.unicodeScalars
        let end = scalars.endIndex
        var index = scalars.startIndex
        while index != end, scalars[index] == "\u{FEFF}" { index = scalars.index(after: index) }

        var rows: [Row] = []
        var fields: [String] = []
        var field = String.UnicodeScalarView()
        var line = 1
        var rowLine = 1
        var fieldLine = 1
        var quoted = false, inQuotes = false, closed = false

        func endField() {
            fields.append(String(field))
            field = String.UnicodeScalarView()
            quoted = false
            closed = false
        }
        func endRow() {
            // An empty line is one empty unquoted field.
            if !(fields.isEmpty && field.isEmpty && !quoted) {
                endField()
                rows.append(Row(line: rowLine, fields: fields))
            }
            fields = []
        }

        while index != end {
            let scalar = scalars[index]
            index = scalars.index(after: index)
            let next: Unicode.Scalar? = index != end ? scalars[index] : nil
            if inQuotes {
                if scalar == "\"" {
                    if next == "\"" {
                        field.append(scalar)
                        index = scalars.index(after: index)
                    } else {
                        inQuotes = false
                        closed = true
                    }
                } else {
                    if scalar == "\n" || (scalar == "\r" && next != "\n") { line += 1 }
                    field.append(scalar)
                }
                continue
            }
            switch scalar {
            case ",":
                endField()
                fieldLine = line
            case "\n", "\r":
                if scalar == "\r", next == "\n" { index = scalars.index(after: index) }
                endRow()
                line += 1
                rowLine = line
                fieldLine = line
            case "\"":
                guard field.isEmpty, !quoted else { throw CredentialCSVError.unreadable(line: fieldLine) }
                quoted = true
                inQuotes = true
            default:
                guard !closed else { throw CredentialCSVError.unreadable(line: fieldLine) }
                field.append(scalar)
            }
        }
        guard !inQuotes else { throw CredentialCSVError.unreadable(line: fieldLine) }
        endRow()
        return rows
    }

    /// CRLF-terminated rows; a field is quoted only when it has to be.
    static func encode(_ rows: [[String]]) -> Data {
        func field(_ value: String) -> String {
            let plain = !value.isEmpty && !value.unicodeScalars.contains(where: { $0 == "," || $0 == "\"" || $0 == "\r" || $0 == "\n" })
                && value.first != " " && value.last != " "
            return plain || value.isEmpty ? value : "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return Data(rows.map { $0.map(field).joined(separator: ",") + "\r\n" }.joined().utf8)
    }

    /// Writes `data` to `url` in one step: a private (0600) sibling file that only this call created, renamed over the
    /// destination, so a failure leaves whatever was at `url` exactly as it was and the data is never readable by others.
    /// The sibling is removed on failure ONLY once this call created it: the exclusive create (`O_EXCL`, never following
    /// a link) is what makes it ours, so a file that was already there under that name is never touched. The caller owns
    /// the user's confirmation to replace (the save panel). `temporaryName` exists for tests that stage that collision.
    static func save(_ data: Data, to url: URL, temporaryName: String = ".wsurf-csv-\(UUID().uuidString).tmp") throws {
        let temporary = url.deletingLastPathComponent().appending(path: temporaryName).path
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CredentialCSVError.notWritten }
        // From here the file is ours: every way out but the rename removes it.
        var renamed = false
        defer { if !renamed { unlink(temporary) } }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            _ = close(descriptor)
            throw CredentialCSVError.notWritten
        }
        guard close(descriptor) == 0, rename(temporary, url.path) == 0 else { throw CredentialCSVError.notWritten }
        renamed = true
    }

    /// The file's bytes. Only a regular file is read (a pipe or device could block or never end), its size is checked on the
    /// open descriptor and the read is bounded one byte past the limit, so a file that grows or lies about its size is never
    /// loaded whole. The file is opened read-only and never changed.
    static func read(_ url: URL) throws -> Data {
        let limit = CredentialVaultLimits.payloadBytes
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw CredentialCSVError.cannotRead }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw CredentialCSVError.cannotRead }
        guard info.st_size <= limit else { throw CredentialCSVError.tooLarge }
        let data: Data
        do { data = try handle.read(upToCount: limit + 1) ?? Data() } catch { throw CredentialCSVError.cannotRead }
        guard data.count <= limit else { throw CredentialCSVError.tooLarge }
        return data
    }
}
