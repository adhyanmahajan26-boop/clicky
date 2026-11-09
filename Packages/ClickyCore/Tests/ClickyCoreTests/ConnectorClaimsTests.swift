import Testing
@testable import ClickyCore

struct ConnectorClaimsTests {
    @Test func theEveningMailboxClaimIsCaught() {
        let reply = "The evening mailbox run didn't happen: the Gmail connector has disconnected again, so I can't search. The Hostinger connector is also disconnected now."
        #expect(ConnectorClaims.saysMissing(reply, names: ["Gmail", "Google Drive", "Hostinger"]) == ["Gmail", "Hostinger"])
        #expect(ConnectorClaims.saysMissing("Google Drive isn't available in this session.", names: ["Gmail", "Google Drive"]) == ["Google Drive"])
    }

    @Test func normalRepliesAreLeftAlone() {
        let reply = "The evening run found two new Motocare invoices in Gmail since 6 Nov. Hostinger connector is back, and the site is up."
        #expect(ConnectorClaims.saysMissing(reply, names: ["Gmail", "Hostinger"]).isEmpty)
        #expect(ConnectorClaims.saysMissing("Nothing is due today.", names: ["Gmail"]).isEmpty)
    }
}
