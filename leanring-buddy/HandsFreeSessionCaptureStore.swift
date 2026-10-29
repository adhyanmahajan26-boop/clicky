//
//  HandsFreeSessionCaptureStore.swift
//  leanring-buddy
//
//  Saves the screenshots taken during one hands-free session into their own
//  folder: ~/Pictures/Clicky/Session 2026-10-25 at 14.03.12/capture-01.png.
//  The folder is only created when the first capture is saved, so sessions
//  without captures leave nothing behind.
//

import AppKit
import Foundation

final class HandsFreeSessionCaptureStore {
    let sessionStartDate: Date
    private(set) var savedCaptureFileURLs: [URL] = []

    init(sessionStartDate: Date = Date()) {
        self.sessionStartDate = sessionStartDate
    }

    var sessionFolderURL: URL {
        let sessionFolderDateFormatter = DateFormatter()
        sessionFolderDateFormatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let sessionFolderName = "Session \(sessionFolderDateFormatter.string(from: sessionStartDate))"

        let picturesFolderURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures")
        return picturesFolderURL
            .appendingPathComponent("Clicky", isDirectory: true)
            .appendingPathComponent(sessionFolderName, isDirectory: true)
    }

    /// Takes a full-resolution screenshot of the cursor's screen and saves it.
    /// Returns the saved file's URL.
    @discardableResult
    func captureCursorScreenAndSave() async throws -> URL {
        let pngData = try await PointerScreenShot.capturePNG()

        try FileManager.default.createDirectory(at: sessionFolderURL, withIntermediateDirectories: true)

        let captureNumber = savedCaptureFileURLs.count + 1
        let captureFileURL = sessionFolderURL.appendingPathComponent(String(format: "capture-%02d.png", captureNumber))
        try pngData.write(to: captureFileURL)

        savedCaptureFileURLs.append(captureFileURL)
        print("📸 Hands-free: saved \(captureFileURL.lastPathComponent) (\(pngData.count / 1024)KB)")
        return captureFileURL
    }

    /// Opens the session folder in Finder with the captures selected.
    func revealCapturesInFinder() {
        guard !savedCaptureFileURLs.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(savedCaptureFileURLs)
    }
}
