import Foundation
import ZeronGenerated

/// Moves attachment bytes to the chat's host device in base64 chunks and
/// returns the durable path a `RunRequest` can reference.
public enum Attachments {
    static let chunkChars = 680_000

    public static func upload(_ data: Data, named name: String, to deviceId: String?, via connection: Connection) async throws -> String {
        let uploadId = UUID().uuidString.lowercased()
        let encoded = data.base64EncodedString()
        var seq = 0
        var start = encoded.startIndex
        repeat {
            let end = encoded.index(start, offsetBy: chunkChars, limitedBy: encoded.endIndex) ?? encoded.endIndex
            _ = try await connection.call(Rpc.uploadChunk, UploadChunkParams(
                uploadId: uploadId, seq: seq, data: String(encoded[start..<end]), targetDeviceId: deviceId
            ))
            start = end
            seq += 1
        } while start < encoded.endIndex
        return try await connection.call(Rpc.uploadCommit, UploadCommitParams(
            uploadId: uploadId, fileName: name, targetDeviceId: deviceId
        )).path
    }

    /// Reads a transcript image back from the device that owns it.
    public static func download(_ path: String, from deviceId: String?, via connection: Connection) async throws -> Data {
        var bytes = Data()
        var offset = 0
        while true {
            let chunk = try await connection.call(Rpc.readAttachmentChunk, ReadAttachmentChunkParams(
                path: path, offset: offset, targetDeviceId: deviceId
            ))
            bytes.append(Data(base64Encoded: chunk.data) ?? Data())
            if chunk.done || chunk.nextOffset <= offset { return bytes }
            offset = chunk.nextOffset
        }
    }
}
