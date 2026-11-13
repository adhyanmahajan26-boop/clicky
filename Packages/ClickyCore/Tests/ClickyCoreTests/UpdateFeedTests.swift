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

    @Test func readsTheReleasesRepoFromTheBuild() {
        #expect(UpdateFeed.releasesRepository(fromInfoValue: "someone/theo-releases") == "someone/theo-releases")
        #expect(UpdateFeed.releasesRepository(fromInfoValue: "  someone/theo.releases_2 \n") == "someone/theo.releases_2")
        // A build without THEO_RELEASES_REPO leaves the key empty or unexpanded: no feed, rather than a wrong one.
        #expect(UpdateFeed.releasesRepository(fromInfoValue: nil) == nil)
        #expect(UpdateFeed.releasesRepository(fromInfoValue: "") == nil)
        #expect(UpdateFeed.releasesRepository(fromInfoValue: "$(THEO_RELEASES_REPO)") == nil)
        #expect(UpdateFeed.releasesRepository(fromInfoValue: "no-slash") == nil)
        #expect(UpdateFeed.releasesRepository(fromInfoValue: "a/b/c") == nil)
        #expect(UpdateFeed.releasesRepository(fromInfoValue: "a/b?x=1") == nil)
        #expect(UpdateFeed.latestReleaseFeedURL(repository: "someone/theo-releases")?.absoluteString
                == "https://api.github.com/repos/someone/theo-releases/releases/latest")
        #expect(UpdateFeed.releasesPageURL(repository: "someone/theo-releases")?.absoluteString
                == "https://github.com/someone/theo-releases/releases/latest")
        #expect(UpdateFeed.latestReleaseFeedURL(repository: "") == nil)
    }

    @Test func aPrivateRepoIsSaidPlainly() {
        let withoutToken = UpdateFeed.checkFailureMessage(statusCode: 404, sentToken: false, repository: "someone/theo-releases")
        #expect(withoutToken.contains("This build's updates are private"))
        #expect(!withoutToken.contains("gh auth login"))
        #expect(UpdateFeed.checkFailureMessage(statusCode: 404, sentToken: true, repository: "someone/theo-releases").contains("can't read it"))
        #expect(UpdateFeed.checkFailureMessage(statusCode: 401, sentToken: true, repository: nil).contains("refused the saved token"))
        #expect(UpdateFeed.checkFailureMessage(statusCode: 403, sentToken: false, repository: nil).contains("limiting"))
        #expect(UpdateFeed.checkFailureMessage(statusCode: 500, sentToken: false, repository: nil) == "The update check answered 500.")
    }
}
