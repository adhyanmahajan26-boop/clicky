import ClickyCore
import Testing

struct CodingPlacementTests {

    @Test func repoWithARemoteGetsItsOwnBranchAndIsPublished() {
        let placement = CodingPlacement.decide(folderNamed: true, isGitRepo: true, hasRemote: true)
        #expect(placement == .ownBranch(publishes: true))
        #expect(placement.hasOwnBranch)
        #expect(placement.publishes)
    }

    @Test func repoWithNoRemoteStillGetsItsOwnBranchButIsNotPushed() {
        let placement = CodingPlacement.decide(folderNamed: true, isGitRepo: true, hasRemote: false)
        #expect(placement == .ownBranch(publishes: false))
        #expect(placement.hasOwnBranch)
        #expect(!placement.publishes)
    }

    @Test func folderThatIsNotARepoIsWorkedOnInPlace() {
        let placement = CodingPlacement.decide(folderNamed: true, isGitRepo: false, hasRemote: false)
        #expect(placement == .inPlace)
        #expect(!placement.hasOwnBranch)
        #expect(!placement.publishes)
    }

    @Test func noFolderMeansANewProject() {
        #expect(CodingPlacement.decide(folderNamed: false, isGitRepo: false, hasRemote: false) == .newProject)
        #expect(!CodingPlacement.newProject.publishes)
    }

    @Test func noRemoteWordsNameTheBranchAndSayNothingWasPushed() {
        let words = CodingPlacement.localBranchWords(branch: "theo/fix-add-12345")
        #expect(words.contains("branch theo/fix-add-12345"))
        #expect(words.contains("Nothing was pushed because the repo has no remote"))
    }
}
