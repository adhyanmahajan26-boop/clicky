//
//  SpokenLineGate.swift
//  ClickyCore
//
//  One-off spoken lines ("stopped: you pressed a key.", "done.", a refusal) wait until Clicky has stopped talking and
//  then speak. Escape stops the talking, so every line already waiting played right after it: Clicky "kept speaking
//  after Escape" (Air, 2026-11-13). Each line takes a ticket when it's queued; Escape silences every ticket handed
//  out before it, so those lines are dropped instead of spoken. Lines queued after Escape speak as usual. Pure.
//

import Foundation

public struct SpokenLineGate: Equatable, Sendable {
    private var silencedGeneration = 0

    public init() {}

    /// Taken when a line is queued.
    public func ticket() -> Int { silencedGeneration }

    /// Escape (or "stop"): every line queued so far is dropped.
    public mutating func silenceQueuedLines() { silencedGeneration += 1 }

    /// Whether a line queued with `ticket` may still be spoken.
    public func allows(_ ticket: Int) -> Bool { ticket == silencedGeneration }
}
