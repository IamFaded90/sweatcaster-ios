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
    var agentActionShortcuts: some View {
        Button("Giv mig en opgave", systemImage: "sparkle.magnifyingglass") {
            composerFocused = false
            showAgentShortcuts = true
        }
        .disabled(running != nil)
    }

    @ViewBuilder var advancedAgentShortcuts: some View {
        agentShortcut("Kamerahjælp · vis mig stedet", icon: "viewfinder") { interactiveTool = .cameraGuide(cleanDraft, attachedPhoto) }
        agentShortcut("Find ting fra et billede", icon: "viewfinder") { interactiveTool = .productHunt("", attachedPhoto) }
        agentShortcut("Skift stemning i landsbyen", icon: "sun.haze") { interactiveTool = .ambience }
        agentShortcut("Følg en sag til dørs", icon: "checkmark.bubble") { interactiveTool = .caseTracker }
        agentShortcut("Dit kreative hold", icon: "paintbrush.pointed") { interactiveTool = .creative(nil) }
        agentShortcut("Tag dig af en returvare", icon: "shippingbox.and.arrow.backward") { interactiveTool = .taskJourney }
        agentShortcut("Gør min aften god", icon: "moon.stars") { interactiveTool = .evening(.init()) }
        agentShortcut("Spil et mysterium", icon: "moon.stars") { interactiveTool = .mystery }
        ForEach(AgentMilestone.allCases) { kind in
            agentShortcut(kind.title, icon: kind.icon) { startAgentAction(.milestone(kind), prompt: kind.title) }
        }
        agentShortcut("Sælg noget for mig", icon: "tag") {
            startAgentAction(.sales, prompt: "")
        }
        agentShortcut("Skab noget til landsbyen", icon: "sparkles") {
            startAgentAction(.surprise, prompt: "")
        }
        agentShortcut("Lav Instagram-opslag", icon: "camera") {
            startAgentAction(.action(.instagramPost), prompt: "Lav et Instagram-opslag")
        }
        agentShortcut("Planlagte Instagram-opslag", icon: "calendar.badge.clock") {
            startAgentAction(.action(.instagramPlans), prompt: "Vis mine planlagte Instagram-opslag")
        }
        agentShortcut("Hold øje med en pris", icon: "tag") {
            startAgentAction(.action(.traderaWatch), prompt: "Opret en prisvagt")
        }
    }

    @ViewBuilder var agentComputerShortcuts: some View {
        agentShortcut("Planlæg min dag", icon: "calendar.badge.clock") { interactiveTool = .dayPlan }
        agentShortcut("Scan dokument, kvittering eller QR", icon: "doc.viewfinder") { interactiveTool = .scanDocument }
        agentShortcut("Optagelser og dansk transskription", icon: "waveform") { interactiveTool = .audioJournal }
        agentShortcut("Fang tekst, foto eller lyd", icon: "square.and.pencil") { interactiveTool = .capture }
        agentShortcut("Agentens hukommelse", icon: "brain") { interactiveTool = .memory([]) }
        agentShortcut("Lav et lokalt værktøj", icon: "curlybraces") { interactiveTool = .localCode(cleanDraft) }
        agentShortcut("Færdigheder og telefonværktøjer", icon: "sparkles.rectangle.stack") { interactiveTool = .skills }
        agentShortcut("Agentbrowser på iPhone", icon: "globe") { interactiveTool = .browser(cleanDraft) }
        agentShortcut("Find i mit univers", icon: "magnifyingglass") { interactiveTool = .personalSearch("") }
        agentShortcut("Personlighed og samtalestil", icon: "person.crop.circle.badge.sparkles") { interactiveTool = .personality }
        agentShortcut("Lav eller redigér billeder", icon: "photo.badge.plus") {
            interactiveTool = .images(cleanDraft, attachedPhoto)
        }
        agentShortcut("Arbejdsrum · filer, opgaver og genveje", icon: "laptopcomputer.and.iphone") {
            interactiveTool = .workspace(nil, "")
        }
        agentShortcut("Del min iPhone-skærm", icon: "iphone") {
            startAgentAction(.phoneScreen, prompt: "Se lige min skærm")
        }
        agentShortcut("Se mit PC-vindue", icon: "macwindow") {
            startAgentAction(.windowHelp, prompt: "Se lige min skærm")
        }
        agentShortcut("Åbn agentens computer", icon: "desktopcomputer") {
            startAgentAction(.agentComputer(""), prompt: "Åbn din egen computer")
        }
        agentShortcut("Tjek billedmotoren på PC", icon: "wrench.and.screwdriver") {
            startAgentAction(.pcRepair, prompt: "Tjek billedmotoren på PC")
        }
        agentShortcut("Byg og brug værktøjer", icon: "hammer") {
            startAgentAction(.builtTools, prompt: "vis agentværktøjer")
        }
    }
}
