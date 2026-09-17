import Foundation
import SQLite3
import AirChatProtocol

/// SQLITE_TRANSIENT tells SQLite to copy the bound bytes immediately, which is required because
/// Swift's buffers do not outlive the bind call.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A value that can be bound to a prepared statement.
enum SqliteValue {
    case blob(Data)
    case text(String)
    case integer(Int64)
    case null
}

/// Thin wrapper over the system SQLite C API.
///
/// AirChat deliberately avoids an ORM: the schema is small, the queries are fixed, and keeping the
/// dependency count at zero removes an entire class of build problems on a fresh checkout.
final class SqliteDatabase {

    private var handle: OpaquePointer?
    private let path: String

    init(path: String) throws {
        self.path = path
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(path, &handle, flags, nil)
        guard status == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let handle { sqlite3_close_v2(handle) }
            throw AirChatError.fatal("cannot open database at \(path): \(message)")
        }
        self.handle = handle
        // WAL keeps reads from blocking link threads while a write is in flight.
        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA foreign_keys = ON;")
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    var lastChangeCount: Int { Int(sqlite3_changes(handle)) }

    func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        guard status == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? "unknown error"
            if let errorPointer { sqlite3_free(errorPointer) }
            throw AirChatError.fatal("sqlite error: \(message)")
        }
    }

    /// Runs a statement that does not return rows.
    @discardableResult
    func run(_ sql: String, _ parameters: [SqliteValue] = []) throws -> Int {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(parameters, to: statement)
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else {
            throw failure(statement)
        }
        return Int(sqlite3_changes(handle))
    }

    /// Runs a query, invoking `row` for each returned row.
    func query(_ sql: String, _ parameters: [SqliteValue] = [], row: (OpaquePointer) -> Void) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(parameters, to: statement)
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_ROW {
                row(statement)
            } else if status == SQLITE_DONE {
                break
            } else {
                throw failure(statement)
            }
        }
    }

    // ------------------------------------------------------------- internals

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw AirChatError.fatal("cannot prepare statement: \(lastErrorMessage)")
        }
        return statement
    }

    private func bind(_ parameters: [SqliteValue], to statement: OpaquePointer) throws {
        // Reset first so a reused statement starts from a clean parameter set.
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)

        for (offset, value) in parameters.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case .null:
                status = sqlite3_bind_null(statement, index)
            case .integer(let number):
                status = sqlite3_bind_int64(statement, index, number)
            case .text(let text):
                status = text.withCString { pointer in
                    sqlite3_bind_text(statement, index, pointer, -1, sqliteTransient)
                }
            case .blob(let data):
                status = data.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(data.count), sqliteTransient)
                }
            }
            guard status == SQLITE_OK else {
                throw AirChatError.fatal("cannot bind parameter \(index): \(lastErrorMessage)")
            }
        }
    }

    private func failure(_ statement: OpaquePointer) -> AirChatError {
        AirChatError.fatal("sqlite step failed: \(lastErrorMessage)")
    }

    private var lastErrorMessage: String {
        guard let handle else { return "database is closed" }
        return String(cString: sqlite3_errmsg(handle))
    }
}

/// Column readers shared by the stores.
enum SqliteColumn {
    static func isNull(_ statement: OpaquePointer, _ index: Int32) -> Bool {
        sqlite3_column_type(statement, index) == SQLITE_NULL
    }

    static func blob(_ statement: OpaquePointer, _ index: Int32) -> Data {
        guard let pointer = sqlite3_column_blob(statement, index) else { return Data() }
        let count = Int(sqlite3_column_bytes(statement, index))
        return Data(bytes: pointer, count: count)
    }

    static func optionalBlob(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        isNull(statement, index) ? nil : blob(statement, index)
    }

    static func text(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: pointer)
    }

    static func integer(_ statement: OpaquePointer, _ index: Int32) -> Int64 {
        sqlite3_column_int64(statement, index)
    }
}
