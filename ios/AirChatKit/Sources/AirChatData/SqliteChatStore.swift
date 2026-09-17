import Foundation
import SQLite3
import AirChatProtocol

/// SQLite-backed `ChatStore`.
///
/// Table and column names follow `docs/protocol.md` section 12 exactly, so the schema matches the
/// Android Room database and either side can be inspected with the same SQL.
///
/// The store is synchronous by design: the node runs on a serial queue and SQLite access is local,
/// so there is no benefit to pretending otherwise, and a synchronous contract removes a whole
/// class of ordering bugs.
public final class SqliteChatStore: ChatStore {

    private let db: SqliteDatabase

    public init(path: String) throws {
        db = try SqliteDatabase(path: path)
        try migrate()
    }

    /// Default on-disk location: Application Support, so the database is excluded from user-visible
    /// documents and survives app updates.
    public static func defaultPath(fileName: String = "airchat.db") throws -> String {
        let manager = FileManager.default
        let base = try manager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        try manager.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent(fileName).path
    }

    private func migrate() throws {
        try db.execute("""
        CREATE TABLE IF NOT EXISTS identity (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            device_id BLOB NOT NULL,
            private_key BLOB NOT NULL,
            public_key BLOB NOT NULL,
            nickname TEXT NOT NULL,
            created_ms INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS peers (
            device_id BLOB PRIMARY KEY,
            nickname TEXT NOT NULL,
            public_key BLOB NOT NULL,
            trust_state INTEGER NOT NULL,
            last_seen_ms INTEGER NOT NULL,
            created_ms INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS messages (
            msg_id BLOB PRIMARY KEY,
            conversation_id TEXT NOT NULL,
            kind INTEGER NOT NULL,
            direction INTEGER NOT NULL,
            sender_id BLOB NOT NULL,
            recipient_id BLOB,
            text TEXT NOT NULL,
            timestamp_ms INTEGER NOT NULL,
            received_ms INTEGER NOT NULL,
            status INTEGER NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_messages_conversation ON messages(conversation_id, received_ms);
        CREATE INDEX IF NOT EXISTS idx_messages_status ON messages(status);
        CREATE INDEX IF NOT EXISTS idx_messages_kind ON messages(kind, received_ms);

        CREATE TABLE IF NOT EXISTS sessions (
            peer_device_id BLOB PRIMARY KEY,
            session_key BLOB NOT NULL,
            peer_public_key BLOB NOT NULL,
            verified INTEGER NOT NULL,
            created_ms INTEGER NOT NULL,
            last_used_ms INTEGER NOT NULL
        );
        """)
    }

    // ------------------------------------------------------------- identity

    public func loadIdentity() throws -> IdentityRecord? {
        var record: IdentityRecord?
        try db.query("SELECT device_id, private_key, public_key, nickname FROM identity WHERE id = 1") { row in
            record = IdentityRecord(
                deviceId: SqliteColumn.blob(row, 0),
                privateKeyRaw: SqliteColumn.blob(row, 1),
                publicKey: SqliteColumn.blob(row, 2),
                nickname: SqliteColumn.text(row, 3)
            )
        }
        return record
    }

    public func saveIdentity(_ record: IdentityRecord) throws {
        guard record.deviceId.count == AirChatProtocol.deviceIdBytes else {
            throw AirChatError.format("device_id must be \(AirChatProtocol.deviceIdBytes) bytes")
        }
        guard record.publicKey.count == AirChatProtocol.publicKeyBytes else {
            throw AirChatError.format("public_key must be \(AirChatProtocol.publicKeyBytes) bytes")
        }
        // Preserve the original creation time across nickname updates.
        var createdMs = Int64(Date().timeIntervalSince1970 * 1000)
        try db.query("SELECT created_ms FROM identity WHERE id = 1") { row in
            createdMs = SqliteColumn.integer(row, 0)
        }
        try db.run(
            """
            INSERT OR REPLACE INTO identity (id, device_id, private_key, public_key, nickname, created_ms)
            VALUES (1, ?, ?, ?, ?, ?)
            """,
            [
                .blob(record.deviceId),
                .blob(record.privateKeyRaw),
                .blob(record.publicKey),
                .text(record.nickname),
                .integer(createdMs),
            ]
        )
    }

    // ---------------------------------------------------------------- peers

    public func upsertPeer(_ record: PeerRecord) throws {
        try db.run(
            """
            INSERT OR REPLACE INTO peers
                (device_id, nickname, public_key, trust_state, last_seen_ms, created_ms)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            [
                .blob(record.deviceId),
                .text(record.nickname),
                .blob(record.publicKey),
                .integer(Int64(record.trustState)),
                .integer(record.lastSeenMs),
                .integer(record.createdMs),
            ]
        )
    }

    public func getPeer(_ deviceId: Data) throws -> PeerRecord? {
        var record: PeerRecord?
        try db.query(
            "SELECT device_id, nickname, public_key, trust_state, last_seen_ms, created_ms FROM peers WHERE device_id = ?",
            [.blob(deviceId)]
        ) { row in
            record = PeerRecord(
                deviceId: SqliteColumn.blob(row, 0),
                nickname: SqliteColumn.text(row, 1),
                publicKey: SqliteColumn.blob(row, 2),
                trustState: Int(SqliteColumn.integer(row, 3)),
                lastSeenMs: SqliteColumn.integer(row, 4),
                createdMs: SqliteColumn.integer(row, 5)
            )
        }
        return record
    }

    public func listPeers() throws -> [PeerRecord] {
        var records: [PeerRecord] = []
        try db.query(
            "SELECT device_id, nickname, public_key, trust_state, last_seen_ms, created_ms FROM peers ORDER BY last_seen_ms DESC"
        ) { row in
            records.append(
                PeerRecord(
                    deviceId: SqliteColumn.blob(row, 0),
                    nickname: SqliteColumn.text(row, 1),
                    publicKey: SqliteColumn.blob(row, 2),
                    trustState: Int(SqliteColumn.integer(row, 3)),
                    lastSeenMs: SqliteColumn.integer(row, 4),
                    createdMs: SqliteColumn.integer(row, 5)
                )
            )
        }
        return records
    }

    public func setTrustState(_ deviceId: Data, trustState: Int) throws {
        guard (0...2).contains(trustState) else {
            throw AirChatError.format("invalid trust state \(trustState)")
        }
        try db.run(
            "UPDATE peers SET trust_state = ? WHERE device_id = ?",
            [.integer(Int64(trustState)), .blob(deviceId)]
        )
    }

    // ------------------------------------------------------------- messages

    public func insertMessage(_ record: MessageRecord) throws -> Bool {
        guard record.msgId.count == AirChatProtocol.msgIdBytes else {
            throw AirChatError.format("msg_id must be \(AirChatProtocol.msgIdBytes) bytes")
        }
        try db.run(
            """
            INSERT OR IGNORE INTO messages
                (msg_id, conversation_id, kind, direction, sender_id, recipient_id, text,
                 timestamp_ms, received_ms, status)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .blob(record.msgId),
                .text(record.conversationId),
                .integer(Int64(record.kind)),
                .integer(Int64(record.direction)),
                .blob(record.senderId),
                record.recipientId.map { SqliteValue.blob($0) } ?? .null,
                .text(record.text),
                .integer(record.timestampMs),
                .integer(record.receivedMs),
                .integer(Int64(record.status)),
            ]
        )
        // INSERT OR IGNORE changes zero rows when the msgId already existed.
        return db.lastChangeCount > 0
    }

    public func getMessage(_ msgId: Data) throws -> MessageRecord? {
        var record: MessageRecord?
        try db.query(
            """
            SELECT msg_id, conversation_id, kind, direction, sender_id, recipient_id, text,
                   timestamp_ms, received_ms, status
            FROM messages WHERE msg_id = ?
            """,
            [.blob(msgId)]
        ) { row in
            record = Self.readMessage(row)
        }
        return record
    }

    public func updateMessageStatus(_ msgId: Data, status: Int) throws -> Bool {
        try db.run(
            "UPDATE messages SET status = ? WHERE msg_id = ?",
            [.integer(Int64(status)), .blob(msgId)]
        )
        return db.lastChangeCount > 0
    }

    public func listMessages(conversationId: String, limit: Int) throws -> [MessageRecord] {
        var records: [MessageRecord] = []
        try db.query(
            """
            SELECT * FROM (
                SELECT msg_id, conversation_id, kind, direction, sender_id, recipient_id, text,
                       timestamp_ms, received_ms, status
                FROM messages WHERE conversation_id = ?
                ORDER BY received_ms DESC, msg_id DESC LIMIT ?
            ) ORDER BY received_ms ASC, msg_id ASC
            """,
            [.text(conversationId), .integer(Int64(limit))]
        ) { row in
            records.append(Self.readMessage(row))
        }
        return records
    }

    public func historySince(_ sinceMs: Int64, limit: Int) throws -> [MessageRecord] {
        var records: [MessageRecord] = []
        try db.query(
            """
            SELECT msg_id, conversation_id, kind, direction, sender_id, recipient_id, text,
                   timestamp_ms, received_ms, status
            FROM messages
            WHERE kind = \(MessageKind.channel) AND received_ms >= ?
            ORDER BY received_ms ASC, msg_id ASC LIMIT ?
            """,
            [.integer(sinceMs), .integer(Int64(limit))]
        ) { row in
            records.append(Self.readMessage(row))
        }
        return records
    }

    // ------------------------------------------------------------- sessions

    public func saveSession(_ record: SessionRecord) throws {
        try db.run(
            """
            INSERT OR REPLACE INTO sessions
                (peer_device_id, session_key, peer_public_key, verified, created_ms, last_used_ms)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            [
                .blob(record.peerDeviceId),
                .blob(record.sessionKey),
                .blob(record.peerPublicKey),
                .integer(record.verified ? 1 : 0),
                .integer(record.createdMs),
                .integer(record.lastUsedMs),
            ]
        )
    }

    public func getSession(_ peerDeviceId: Data) throws -> SessionRecord? {
        var record: SessionRecord?
        try db.query(
            """
            SELECT peer_device_id, session_key, peer_public_key, verified, created_ms, last_used_ms
            FROM sessions WHERE peer_device_id = ?
            """,
            [.blob(peerDeviceId)]
        ) { row in
            record = SessionRecord(
                peerDeviceId: SqliteColumn.blob(row, 0),
                sessionKey: SqliteColumn.blob(row, 1),
                peerPublicKey: SqliteColumn.blob(row, 2),
                verified: SqliteColumn.integer(row, 3) != 0,
                createdMs: SqliteColumn.integer(row, 4),
                lastUsedMs: SqliteColumn.integer(row, 5)
            )
        }
        return record
    }

    // ------------------------------------------------------------ retention

    /// Drops channel messages that fall outside both retention rules. Private conversations are
    /// never pruned.
    public func pruneChannel(retainCount: Int, retainDays: Int) throws {
        let cutoff = Int64(Date().timeIntervalSince1970 * 1000) - Int64(retainDays) * 24 * 60 * 60 * 1000
        try db.run(
            """
            DELETE FROM messages
            WHERE kind = \(MessageKind.channel) AND (
                received_ms < ?
                OR msg_id NOT IN (
                    SELECT msg_id FROM messages WHERE kind = \(MessageKind.channel)
                    ORDER BY received_ms DESC LIMIT ?
                )
            )
            """,
            [.integer(cutoff), .integer(Int64(retainCount))]
        )
    }

    private static func readMessage(_ row: OpaquePointer) -> MessageRecord {
        MessageRecord(
            msgId: SqliteColumn.blob(row, 0),
            conversationId: SqliteColumn.text(row, 1),
            kind: Int(SqliteColumn.integer(row, 2)),
            direction: Int(SqliteColumn.integer(row, 3)),
            senderId: SqliteColumn.blob(row, 4),
            recipientId: SqliteColumn.optionalBlob(row, 5),
            text: SqliteColumn.text(row, 6),
            timestampMs: SqliteColumn.integer(row, 7),
            receivedMs: SqliteColumn.integer(row, 8),
            status: Int(SqliteColumn.integer(row, 9))
        )
    }
}
