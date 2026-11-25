import Foundation

extension AgentPhoneChat {
    var hasStandaloneAgentCommand: Bool {
        guard keepHistory else { return false }
        return PersonalHubRecall.command(cleanDraft) != nil || VillageMystery.command(cleanDraft)
            || SongDraft.request(cleanDraft) != nil
            || ProductHunt.command(cleanDraft)
            || VillageAmbience.command(cleanDraft)
            || CaseTracker.command(cleanDraft)
            || CameraGuide.command(cleanDraft)
            || BrowserWork.command(cleanDraft)
            || AgentPhoneContext.contactQuery(cleanDraft) != nil
            || LocalCode.command(cleanDraft) != nil
            || AgentMemory.command(cleanDraft)
            || CapturedInsight.command(cleanDraft)
            || AudioTranscript.command(cleanDraft)
            || ScanDocument.command(cleanDraft)
            || DayPlan.command(cleanDraft)
            || CreativeProject.request(cleanDraft, botID: bot.id) != nil || AgentTaskJourney.matches(cleanDraft)
            || MusicMix.command(cleanDraft) || EveningPlan.Request.parse(cleanDraft) != nil
            || AgentWorkspace.command(cleanDraft) != nil || AgentImageWorkbench.request(cleanDraft) != nil
    }
}
