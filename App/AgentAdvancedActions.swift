import SwiftUI

enum AgentToolBuildIntent {
    static func matches(_ text: String) -> Bool {
        let clean = AgentChatIntent.normalize(text)
        return ["vis agentværktøjer", "mine agentværktøjer"].contains(clean) ||
            clean.range(of: #"^(?:(?:kan|vil) du (?:lige )?)?(?:byg(?:ge)?|lav(?:e)?) (?:mig )?(?:et|et nyt|et lille) (?:pc-)?værktøj\b"#,
                        options: .regularExpression) != nil
    }
}

enum AgentPCRepairIntent {
    static func matches(_ input: String) -> Bool {
        let text = AgentChatIntent.normalize(input)
        let engine = #"\b(?:billedmotor\w*|comfyui|billedgenerering\w*)\b"#
        let action = #"\b(?:repar\w*|fix\w*|fejl\w*|få.{0,15}i gang|start\w*|tjek\w*|virker ikke|stoppet|står stille)\b"#
        return text.range(of: engine, options: .regularExpression) != nil &&
            text.range(of: action, options: .regularExpression) != nil
    }
}

enum AgentComputerIntent {
    static func goal(_ input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^(?:(?:kan|vil) du (?:lige )?)?(?:brug(?:e)?|åbn(?:e)?|arbejd(?:e)? på) (?:lige )?din (?:egen )?(?:pc|computer)\b(?:\s+til\b|\s*[:,.?!])?\s*"#
        guard let command = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return String(text[command.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension AgentPhoneChat {
    @ViewBuilder var advancedAgentShortcuts: some View {
        ForEach(AgentMilestone.allCases) { kind in
            Button(kind.title, systemImage: kind.icon) { startAgentAction(.milestone(kind), prompt: kind.title) }
        }
        Button("Åbn agentens computer", systemImage: "desktopcomputer") {
            startAgentAction(.agentComputer(""), prompt: "Åbn din egen computer")
        }
        Button("Ret en flyttet aftale", systemImage: "calendar.badge.clock") {
            startAgentAction(.appointmentChange, prompt: "Ret en flyttet aftale")
        }
        Button("Ryd op i Gmail", systemImage: "tray.full") {
            startAgentAction(.gmailCleanup, prompt: "Ryd op i Gmail")
        }
        Button("Tjek billedmotoren på PC", systemImage: "wrench.and.screwdriver") {
            startAgentAction(.pcRepair, prompt: "Tjek billedmotoren på PC")
        }
        Button("Del min iPhone-skærm", systemImage: "iphone") {
            startAgentAction(.phoneScreen, prompt: "Se lige min skærm")
        }
        Button("Sælg noget for mig", systemImage: "tag") {
            startAgentAction(.sales, prompt: "")
        }
        Button("Skab noget til landsbyen", systemImage: "sparkles") {
            startAgentAction(.surprise, prompt: "")
        }
        Button("Byg og brug værktøjer", systemImage: "hammer") {
            startAgentAction(.builtTools, prompt: "vis agentværktøjer")
        }
    }
}
