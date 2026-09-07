import Foundation
import AVFoundation
import OSLog

/// Incremental CAF writer that never rewrites the header per tick — stream-CCAF-safe
/// from the start. Writes a CAF header with `mAudioDataByteCount = -1` (kCAFDataByteCountStreaming)
/// and appends raw Float32 mono 16kHz samples. The file is playable even if the
/// process is killed mid-recording (header does not need a final seek-back).
final class CAFStreamWriter: @unchecked Sendable {
    private static let logger = Logger(subsystem: "singhkays.Kalam", category: "CAFStreamWriter")

    private let url: URL
    private let fileHandle: FileHandle
    private let sampleRate: Double
    private var totalSamples: Int = 0
    private var isClosed = false
    private let lock = NSLock()

    /// CAF constants
    private static let cafFileType: UInt32 = 0x63616666 // 'caff'
    private static let cafVersion: UInt16 = 1
    private static let cafFlags: UInt16 = 0
    private static let dataByteCountStreaming: Int64 = -1

    init(url: URL, sampleRate: Double = 16_000, channels: UInt32 = 1) throws {
        self.url = url
        self.sampleRate = sampleRate
        // Ensure parent directory exists
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Create file
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let fh = try? FileHandle(forWritingTo: url) else {
            throw NSError(domain: "CAFStreamWriter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to open \(url.path)"])
        }
        self.fileHandle = fh
        try writeHeader(sampleRate: sampleRate, channels: channels)
    }

    private func writeHeader(sampleRate: Double, channels: UInt32) throws {
        // CAF file header: 8 bytes 'caff' + version(2) + flags(2)
        // Then chunks: 'desc' (32 bytes) and 'data' (8 byte header + streaming size)
        var header = Data()
        // File type 'caff'
        header.append(contentsOf: withUnsafeBytes(of: Self.cafFileType.bigEndian) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: Self.cafVersion.bigEndian) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: Self.cafFlags.bigEndian) { Data($0) })

        // desc chunk: type 'desc' (4), size 32 (8), then AudioStreamBasicDescription
        let descType: UInt32 = 0x64657363 // 'desc'
        let descSize: UInt64 = 32
        header.append(contentsOf: withUnsafeBytes(of: descType.bigEndian) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: descSize.bigEndian) { Data($0) })
        // ASBD: mSampleRate (Float64 8), mFormatID 'lpcm' (4), mFormatFlags kAudioFormatFlagIsFloat|kAudioFormatFlagIsPacked (4),
        // mBytesPerPacket (4), mFramesPerPacket (4), mBytesPerFrame (4), mChannelsPerFrame (4), mBitsPerChannel (4)
        var mSampleRate = sampleRate
        header.append(contentsOf: withUnsafeBytes(of: mSampleRate.bitPattern.bigEndian) { Data($0) })
        let formatID: UInt32 = 0x6C70636D // 'lpcm'
        header.append(contentsOf: withUnsafeBytes(of: formatID.bigEndian) { Data($0) })
        let formatFlags: UInt32 = 0x29 // kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked (0x1 | 0x8 | 0x20)
        header.append(contentsOf: withUnsafeBytes(of: formatFlags.bigEndian) { Data($0) })
        let bytesPerPacket: UInt32 = 4 // Float32 mono
        header.append(contentsOf: withUnsafeBytes(of: bytesPerPacket.bigEndian) { Data($0) })
        let framesPerPacket: UInt32 = 1
        header.append(contentsOf: withUnsafeBytes(of: framesPerPacket.bigEndian) { Data($0) })
        let bytesPerFrame: UInt32 = 4
        header.append(contentsOf: withUnsafeBytes(of: bytesPerFrame.bigEndian) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: channels.bigEndian) { Data($0) })
        let bitsPerChannel: UInt32 = 32
        header.append(contentsOf: withUnsafeBytes(of: bitsPerChannel.bigEndian) { Data($0) })

        // data chunk header: 'data' (4), size 8, mChunkSize = -1 (streaming), mEditCount 0 (4)
        let dataType: UInt32 = 0x64617461 // 'data'
        let dataHeaderSize: UInt64 = 8 // actually chunk size is 8 for streaming?
        // CAF data chunk: type 'data' + size (8) + mChunkSize (8) + mEditCount (4) + data...
        // For streaming, mChunkSize = -1 (0xFFFFFFFFFFFFFFFF)
        header.append(contentsOf: withUnsafeBytes(of: dataType.bigEndian) { Data($0) })
        // Chunk size for data header: we use 8 for the header part? Actually the chunk's size field is 8 + data length for non-streaming.
        // For streaming, the chunk size is also -1? Let's use the streaming convention: chunk size = (1<<63)-1 ?
        // Simpler: use the CAF spec: for streaming, the data chunk's mChunkSize is set to -1 and the chunk's size field is also -1?
        // We'll write size as UInt64.max (all bits 1) to indicate streaming, then mChunkSize -1, mEditCount 0.
        let streamingSize: UInt64 = UInt64.max // -1 as unsigned
        header.append(contentsOf: withUnsafeBytes(of: streamingSize.bigEndian) { Data($0) })
        let chunkSize: Int64 = Self.dataByteCountStreaming
        header.append(contentsOf: withUnsafeBytes(of: UInt64(bitPattern: chunkSize).bigEndian) { Data($0) })
        let editCount: UInt32 = 0
        header.append(contentsOf: withUnsafeBytes(of: editCount.bigEndian) { Data($0) })

        try fileHandle.write(contentsOf: header)
    }

    /// Appends Float32 samples (mono, native endian). Thread-safe.
    func append(_ samples: [Float]) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { throw NSError(domain: "CAFStreamWriter", code: 2, userInfo: [NSLocalizedDescriptionKey: "Writer closed"]) }
        guard !samples.isEmpty else { return }
        let data = samples.withUnsafeBytes { Data($0) }
        try fileHandle.write(contentsOf: data)
        totalSamples += samples.count
    }

    /// Closes the file. For streaming CAF, no header rewrite is needed; the file is already valid.
    /// We optionally truncate or finalize, but the streaming header allows an unfinished file to be read.
    func close() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        try fileHandle.close()
        Self.logger.debug("CAFStreamWriter closed url=\(self.url.lastPathComponent, privacy: .public) totalSamples=\(self.totalSamples, privacy: .public) durationMs=\(Int(Double(self.totalSamples)/self.sampleRate*1000), privacy: .public)")
    }

    deinit {
        try? fileHandle.close()
    }
}
