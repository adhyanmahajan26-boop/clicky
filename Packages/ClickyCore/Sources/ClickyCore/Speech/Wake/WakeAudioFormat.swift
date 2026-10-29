//
//  WakeAudioFormat.swift
//  ClickyCore
//
//  P8: the wake recognizer always gets 48 kHz mono float32, whatever the mic
//  delivers (a USB webcam at 16 kHz, a stereo interface, Int16 files). A
//  16 kHz Int16 file feed recognized nothing in testing while the same
//  speech as 48 kHz float worked, so every input goes through one
//  AVAudioConverter (downmixing extra channels) unless it is already in the
//  target format. The decision is pure (WakeAudioFormatPlan); the converter
//  keeps its state between buffers of one stream.
//

import AVFoundation
import Foundation

public struct WakeAudioInputDescription: Equatable, Sendable {
    public var sampleRate: Double
    public var channelCount: Int
    public var isFloat32: Bool
    public var isInterleaved: Bool

    public init(sampleRate: Double, channelCount: Int, isFloat32: Bool, isInterleaved: Bool) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.isFloat32 = isFloat32
        self.isInterleaved = isInterleaved
    }

    public init(_ format: AVAudioFormat) {
        self.init(sampleRate: format.sampleRate, channelCount: Int(format.channelCount),
                  isFloat32: format.commonFormat == .pcmFormatFloat32, isInterleaved: format.isInterleaved)
    }

    /// "48000 Hz × 1 float32".
    public var displayText: String {
        "\(Int(sampleRate)) Hz × \(channelCount) \(isFloat32 ? "float32" : "int")\(isInterleaved && channelCount > 1 ? " interleaved" : "")"
    }
}

public enum WakeAudioFormatPlan: Equatable, Sendable {
    case passThrough
    case convert(reasons: [String])
    case unusable

    public static let targetSampleRate: Double = 48_000

    public static func plan(for input: WakeAudioInputDescription) -> WakeAudioFormatPlan {
        guard input.sampleRate > 0, input.channelCount > 0 else { return .unusable }
        var reasons: [String] = []
        if abs(input.sampleRate - targetSampleRate) > 0.5 { reasons.append("resample \(Int(input.sampleRate))→\(Int(targetSampleRate))") }
        if input.channelCount != 1 { reasons.append("downmix \(input.channelCount)→1") }
        if !input.isFloat32 { reasons.append("to float32") }
        if input.isInterleaved && input.channelCount > 1 { reasons.append("deinterleave") }
        return reasons.isEmpty ? .passThrough : .convert(reasons: reasons)
    }

    /// Output frames for `inputFrames` at `inputSampleRate` (rounded up, plus slack for the converter's filter).
    public static func outputCapacity(inputFrames: Int, inputSampleRate: Double) -> Int {
        guard inputSampleRate > 0 else { return 0 }
        return Int((Double(inputFrames) * targetSampleRate / inputSampleRate).rounded(.up)) + 64
    }
}

/// One stream's converter to 48 kHz mono float32. Not thread-safe: use it
/// from one queue (the pipeline's).
public final class WakeAudioFormatConverter {
    public static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: WakeAudioFormatPlan.targetSampleRate,
                                                   channels: 1, interleaved: false)!

    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    public private(set) var lastInput: WakeAudioInputDescription?
    public private(set) var lastPlan: WakeAudioFormatPlan?

    public init() {}

    /// The buffer in the target format (the same object when it already is); nil if it can't be converted.
    public func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let input = WakeAudioInputDescription(buffer.format)
        let plan = WakeAudioFormatPlan.plan(for: input)
        lastInput = input
        lastPlan = plan
        switch plan {
        case .unusable: return nil
        case .passThrough: return buffer
        case .convert: break
        }
        if converterInputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: Self.targetFormat)
            converter?.downmix = true
            converterInputFormat = buffer.format
        }
        guard let converter else { return nil }
        let capacity = WakeAudioFormatPlan.outputCapacity(inputFrames: Int(buffer.frameLength), inputSampleRate: buffer.format.sampleRate)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: AVAudioFrameCount(capacity)) else { return nil }
        let inputState = WakeConverterInputState(buffer: buffer)
        var conversionError: NSError?
        // .noDataNow (not .endOfStream) keeps the resampler's history for the next buffer.
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if inputState.wasConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputState.wasConsumed = true
            outStatus.pointee = .haveData
            return inputState.buffer
        }
        guard status != .error, outputBuffer.frameLength > 0 else { return status == .error ? nil : outputBuffer }
        return outputBuffer
    }

    /// A new stream (the mic restarted): forget the resampler history.
    public func reset() {
        converter?.reset()
    }
}

private final class WakeConverterInputState: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var wasConsumed = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}
