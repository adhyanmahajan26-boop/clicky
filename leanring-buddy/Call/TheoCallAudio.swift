//
//  TheoCallAudio.swift
//  leanring-buddy
//
//  The sound of a call. One engine with echo cancelling carries the mic and Theo's voice (AudioEngineHub, the same one
//  hands-free uses), so Theo's own voice doesn't count as Addy talking. The mic comes out as 16 kHz mono blocks with their
//  level. Voices hand in samples, whatever format they came in, and CallAudio plays them in order.
//
//  In the test profile there's no mic: a sound file goes in through `feed` and the voice plays at zero volume.
//

import AudioToolbox
import AVFoundation
import ClickyCore
import Foundation

/// 50 ms of mic audio.
struct CallAudioBlock {
    /// Mono 16-bit samples at 16 kHz.
    let pcm16: Data
    let levelDecibels: Double
    static let seconds = 0.05
    static let sampleRate = 16000
}

/// Turns any PCM into 16 kHz blocks. Fed from the audio thread, or the test file's.
final class CallMicConverter: @unchecked Sendable {
    private let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(CallAudioBlock.sampleRate), channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private var pending = Data()
    private let blockBytes = Int(Double(CallAudioBlock.sampleRate) * CallAudioBlock.seconds) * 2
    var onBlock: (@Sendable (CallAudioBlock) -> Void)?

    func append(_ input: AVAudioPCMBuffer) {
        guard let buffer = Self.firstChannel(of: input) else { return }
        if converter == nil || converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: output) }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * output.sampleRate / buffer.format.sampleRate) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return }
        var supplied = false
        var failure: NSError?
        converter.convert(to: converted, error: &failure) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard failure == nil, let channel = converted.int16ChannelData?[0], converted.frameLength > 0 else { return }
        pending.append(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
        while pending.count >= blockBytes {
            let block = pending.prefix(blockBytes)
            pending.removeFirst(blockBytes)
            onBlock?(CallAudioBlock(pcm16: Data(block), levelDecibels: Self.decibels(of: block)))
        }
    }

    /// Echo cancelling can hand over several channels; the voice is on the first.
    private static func firstChannel(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.format.channelCount > 1 else { return buffer }
        guard let source = buffer.floatChannelData?[0],
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate, channels: 1, interleaved: false),
              let copy = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength), let target = copy.floatChannelData?[0] else { return nil }
        target.update(from: source, count: Int(buffer.frameLength))
        copy.frameLength = buffer.frameLength
        return copy
    }

    static func decibels(of samples: Data) -> Double {
        let count = samples.count / 2
        guard count > 0 else { return -100 }
        let sum = samples.withUnsafeBytes { raw -> Double in
            var total = 0.0
            for value in raw.bindMemory(to: Int16.self) {
                let sample = Double(value) / 32768
                total += sample * sample
            }
            return total
        }
        return 20 * log10(max(sqrt(sum / Double(count)), 0.000_01))
    }
}

/// Pieces of a voice's audio, as they arrive, into samples for the speaker. Handles whole WAV headers, raw 16-bit samples
/// and MP3 frames split anywhere.
final class CallAudioDecoder {
    enum Format { case undecided, pcm16(sampleRate: Double), mp3 }

    private var format = Format.undecided
    private let fallbackSampleRate: Double
    private var mp3: MP3StreamDecoder?
    private var leftover = Data()

    init(sampleRate: Double) {
        fallbackSampleRate = sampleRate
    }

    func decode(_ data: Data, contentType: String) -> [AVAudioPCMBuffer] {
        let type = contentType.lowercased()
        if data.starts(with: Array("RIFF".utf8)) {
            guard let parsed = PCMWavHeader(data) else { return [] }
            format = .pcm16(sampleRate: parsed.sampleRate)
            return pcmBuffers(data.dropFirst(parsed.dataOffset), sampleRate: parsed.sampleRate)
        }
        if case .undecided = format {
            format = type.contains("mp3") || type.contains("mpeg") ? .mp3 : .pcm16(sampleRate: Self.rate(in: type) ?? fallbackSampleRate)
        }
        switch format {
        case .pcm16(let sampleRate): return pcmBuffers(data, sampleRate: sampleRate)
        case .mp3:
            if mp3 == nil { mp3 = MP3StreamDecoder() }
            return mp3?.decode(data) ?? []
        case .undecided: return []
        }
    }

    /// "audio/l16;rate=24000".
    private static func rate(in contentType: String) -> Double? {
        guard let range = contentType.range(of: "rate=") else { return nil }
        return Double(contentType[range.upperBound...].prefix { $0.isNumber })
    }

    private func pcmBuffers(_ samples: Data, sampleRate: Double) -> [AVAudioPCMBuffer] {
        var bytes = leftover + samples
        leftover = bytes.count % 2 == 1 ? Data([bytes.removeLast()]) : Data()
        guard !bytes.isEmpty, let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(bytes.count / 2)), let channel = buffer.floatChannelData?[0] else { return [] }
        let frames = bytes.count / 2
        bytes.withUnsafeBytes { raw in
            let values = raw.bindMemory(to: Int16.self)
            for index in 0..<frames { channel[index] = Float(Int16(littleEndian: values[index])) / 32768 }
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        return [buffer]
    }
}

/// Where the samples start in a WAV, and at what rate.
struct PCMWavHeader {
    let sampleRate: Double
    let dataOffset: Int

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, bytes.starts(with: Array("RIFF".utf8)) else { return nil }
        var offset = 12
        var rate: Double?
        while offset + 8 <= bytes.count {
            let id = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
            let size = Int(bytes[offset + 4]) | Int(bytes[offset + 5]) << 8 | Int(bytes[offset + 6]) << 16 | Int(bytes[offset + 7]) << 24
            if id == "fmt ", offset + 16 <= bytes.count {
                rate = Double(Int(bytes[offset + 12]) | Int(bytes[offset + 13]) << 8 | Int(bytes[offset + 14]) << 16 | Int(bytes[offset + 15]) << 24)
            }
            if id == "data" {
                guard let rate else { return nil }
                sampleRate = rate
                dataOffset = offset + 8
                return
            }
            offset += 8 + size
        }
        return nil
    }
}

/// MP3 in pieces to samples: AudioFileStream finds the frames (even split across pieces), AVAudioConverter decodes them.
final class MP3StreamDecoder {
    private var stream: AudioFileStreamID?
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?
    private let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
    private var decoded: [AVAudioPCMBuffer] = []

    init() {
        let userData = Unmanaged.passUnretained(self).toOpaque()
        AudioFileStreamOpen(userData, { userData, stream, property, _ in
            let decoder = Unmanaged<MP3StreamDecoder>.fromOpaque(userData).takeUnretainedValue()
            if property == kAudioFileStreamProperty_DataFormat { decoder.readFormat(stream) }
        }, { userData, byteCount, packetCount, bytes, descriptions in
            let decoder = Unmanaged<MP3StreamDecoder>.fromOpaque(userData).takeUnretainedValue()
            decoder.handlePackets(byteCount: byteCount, packetCount: packetCount, bytes: bytes, descriptions: descriptions)
        }, kAudioFileMP3Type, &stream)
    }

    deinit {
        if let stream { AudioFileStreamClose(stream) }
    }

    func decode(_ data: Data) -> [AVAudioPCMBuffer] {
        guard let stream else { return [] }
        decoded = []
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            AudioFileStreamParseBytes(stream, UInt32(raw.count), base, [])
        }
        return decoded
    }

    private func readFormat(_ stream: AudioFileStreamID) {
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_DataFormat, &size, &description) == noErr,
              let format = AVAudioFormat(streamDescription: &description) else { return }
        self.format = format
        converter = AVAudioConverter(from: format, to: output)
    }

    private func handlePackets(byteCount: UInt32, packetCount: UInt32, bytes: UnsafeRawPointer, descriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?) {
        guard let format, let converter, packetCount > 0, let descriptions else { return }
        let compressed = AVAudioCompressedBuffer(format: format, packetCapacity: packetCount, maximumPacketSize: Int(byteCount))
        memcpy(compressed.data, bytes, Int(byteCount))
        compressed.byteLength = byteCount
        compressed.packetCount = packetCount
        if let target = compressed.packetDescriptions { target.update(from: descriptions, count: Int(packetCount)) }
        let framesPerPacket = max(format.streamDescription.pointee.mFramesPerPacket, 1152)
        let capacity = AVAudioFrameCount(Double(packetCount * framesPerPacket) * output.sampleRate / format.sampleRate) + 64
        guard let pcm = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return }
        var supplied = false
        var failure: NSError?
        converter.convert(to: pcm, error: &failure) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return compressed
        }
        if failure == nil, pcm.frameLength > 0 { decoded.append(pcm) }
    }
}

/// The call's sound: open or close it, get the mic's blocks, and play samples in order.
@MainActor
final class CallAudio {
    private let hub: AudioEngineHub
    private let isLive: Bool
    private let converter = CallMicConverter()
    private let channel: SharedEnginePlayerChannel
    /// Its own engine, for a test file or a Mac where echo cancelling won't start.
    private var plainEngine: AVAudioEngine?
    /// Echo cancelling is on. Without it Theo's own voice reaches the mic, so only a much louder voice counts as a cut-in.
    private(set) var isEchoCancelled = false
    private static var liveChannel: SharedEnginePlayerChannel?
    private var generation = 0
    private var scheduled = 0
    private var segmentOpen = false
    private(set) var isOpen = false

    /// Mic blocks, on the main actor.
    var onBlock: ((CallAudioBlock) -> Void)?
    /// Everything handed in so far has played.
    var onDrained: (() -> Void)?
    /// How loud the voice is right now, for the avatar.
    private(set) var voiceLevel: CGFloat = 0

    init(hub: AudioEngineHub, isLive: Bool) {
        self.hub = hub
        self.isLive = isLive
        if isLive {
            // One player for every call: the hub keeps each channel it makes.
            let shared = Self.liveChannel ?? hub.makePlayerChannel()
            Self.liveChannel = shared
            channel = shared
        } else {
            channel = SharedEnginePlayerChannel()
        }
        converter.onBlock = { [weak self] block in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onBlock?(block) } }
        }
    }

    var isVoicePlaying: Bool { scheduled > 0 }

    func open() throws {
        guard !isOpen else { return }
        if isLive {
            let converter = self.converter
            do {
                _ = try hub.startVoiceProcessingCapture { buffer, _ in converter.append(buffer) }
                isEchoCancelled = true
            } catch {
                print("📞 Echo cancelling didn't start (\(error.localizedDescription)); the call goes on without it")
                try openPlain(withMicrophone: true)
            }
        } else {
            try openPlain(withMicrophone: false)
        }
        isOpen = true
    }

    private func openPlain(withMicrophone: Bool) throws {
        let engine = AVAudioEngine()
        engine.attach(channel.playerNode)
        engine.attach(channel.timePitchUnit)
        engine.connect(channel.playerNode, to: channel.timePitchUnit, format: SharedEnginePlayerChannel.playbackFormat)
        engine.connect(channel.timePitchUnit, to: engine.mainMixerNode, format: SharedEnginePlayerChannel.playbackFormat)
        if withMicrophone {
            let converter = self.converter
            engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: engine.inputNode.outputFormat(forBus: 0)) { buffer, _ in converter.append(buffer) }
        }
        engine.prepare()
        try engine.start()
        plainEngine = engine
    }

    func close() {
        stopVoice()
        if isEchoCancelled { hub.stopVoiceProcessingCapture() }
        plainEngine?.inputNode.removeTap(onBus: 0)
        plainEngine?.stop()
        if let plainEngine {
            plainEngine.detach(channel.playerNode)
            plainEngine.detach(channel.timePitchUnit)
        }
        plainEngine = nil
        isEchoCancelled = false
        isOpen = false
    }

    /// A test file in place of the mic.
    func feed(_ buffer: AVAudioPCMBuffer) { converter.append(buffer) }

    /// Plays this after what's already queued.
    func play(_ buffer: AVAudioPCMBuffer) {
        if !segmentOpen {
            channel.startSegment(rate: 1)
            segmentOpen = true
        }
        let turn = generation
        scheduled += 1
        voiceLevel = Self.level(of: buffer)
        let accepted = channel.schedule(buffer) { [weak self] in
            guard let self, self.generation == turn else { return }
            self.scheduled -= 1
            if self.scheduled == 0 {
                self.voiceLevel = 0
                self.onDrained?()
            }
        }
        if !accepted {
            scheduled -= 1
            if scheduled == 0 { onDrained?() }
        }
    }

    /// Silence, now. What was queued is dropped.
    func stopVoice() {
        generation += 1
        scheduled = 0
        segmentOpen = false
        voiceLevel = 0
        channel.stop()
    }

    private static func level(of buffer: AVAudioPCMBuffer) -> CGFloat {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0.4 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
        let rms = sqrt(sum / Float(buffer.frameLength))
        return CGFloat(min(max((20 * log10(max(rms, 0.000_01)) + 50) / 40, 0), 1))
    }
}
