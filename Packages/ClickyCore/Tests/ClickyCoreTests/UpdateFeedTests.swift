import Foundation
import Testing
@testable import ClickyCore

struct UpdateFeedTests {
    @Test func parsesAGitHubRelease() throws {
        let json = """
        {"tag_name":"build-202610271800","body":"Side whiteboard and research fixes\\r\\n\\r\\nsha256: \(String(repeating: "ab", count: 32))",
         "assets":[{"name":"Clicky-202610271800.zip","url":"https://api.github.com/repos/x/y/releases/assets/1",
                    "browser_download_url":"https://github.com/x/y/releases/download/build-202610271800/Clicky-202610271800.zip"}]}
        """
        let release = try #require(UpdateFeed.parseRelease(Data(json.utf8)))
        #expect(release.build == 202610271800)
        #expect(release.sha256 == String(repeating: "ab", count: 32))
        #expect(release.zipURL.lastPathComponent == "Clicky-202610271800.zip")
        #expect(release.notes == "Side whiteboard and research fixes")
        #expect(UpdateFeed.isNewer(release, thanBuild: 1))
        #expect(!UpdateFeed.isNewer(release, thanBuild: 202610271800))
    }

    @Test func refusesReleasesWithoutChecksumOrZip() {
        #expect(UpdateFeed.parseRelease(Data(#"{"tag_name":"build-5","body":"no hash","assets":[{"name":"a.zip","browser_download_url":"https://x/a.zip"}]}"#.utf8)) == nil)
        #expect(UpdateFeed.parseRelease(Data(#"{"tag_name":"build-5","body":"sha256: \#(String(repeating: "0", count: 64))","assets":[]}"#.utf8)) == nil)
        #expect(UpdateFeed.parseRelease(Data(#"{"tag_name":"latest","body":"","assets":[]}"#.utf8)) == nil)
    }
}
