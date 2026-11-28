import Foundation
import Testing
@testable import ClickyCore

struct TeamLiveViewTests {
    @Test func findsTheTeamsCategoryAndItsNumberedCopies() {
        let names = ["Daily Drivers", "Research Desk 3", "research desk ", "Research Desk 2", "Research", "Research Desk Two", "Research Desk 1"]
        #expect(TeamLiveView.categoryIndices(teamName: "Research Desk", categoryNames: names) == [2, 3, 1])
        #expect(TeamLiveView.categoryIndices(teamName: "Code Crew", categoryNames: names).isEmpty)
        #expect(TeamLiveView.categoryIndices(teamName: "  ", categoryNames: names).isEmpty)
    }

    @Test func matchesEachMemberToOneBot() {
        let bots = ["Web Scout", "Research Lead 2", "Fact Checker", "Web Scout 2"]
        let found = TeamLiveView.members(["Research Lead", "Web Scout", "Brief Writer", "Web Scout"], among: bots)
        #expect(found == [1, 0, nil, 3])
    }

    @Test func tallyPutsWhatNeedsYouFirstAndSkipsZeros() {
        let tally = TeamLiveView.Tally([.working, .thinking, .needs, .idle, .awake, .done])
        #expect(tally == TeamLiveView.Tally(working: 2, needsYou: 1, failed: 0, done: 1, resting: 2))
        #expect(tally.words == "1 needs you · 2 working · 1 done · 2 resting")
        #expect(TeamLiveView.Tally([.needs, .needs, .failed]).words == "2 need you · 1 failed")
        #expect(TeamLiveView.Tally([.idle, .off, .awake]).words == "All 3 resting")
        #expect(TeamLiveView.Tally([.idle]).words == "Resting")
        #expect(TeamLiveView.Tally([]).words == "No bots")
    }
}
