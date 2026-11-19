import Foundation

enum AgentRepairData {
    struct Runner: Decodable { let ready: Bool; let title: String; let detail: String }
    struct Source: Decodable, Identifiable { let id: String; let test: Bool }
    struct Project: Decodable, Identifiable { let id: String; let title: String; let files: [Source] }
    struct Catalog: Decodable { let runner: Runner; let projects: [Project]; let jobs: [Job]; let detail: String }
    struct Evidence: Decodable {
        let kind: String
        let title: String
        let report: String
        let lines: [String]
        let build: String?
        let incident: String?
        let nextCheck: String
        let redacted: Bool
    }
    struct TestRun: Decodable {
        let testsRun: Int
        let failures: Int
        let errors: Int
        let skipped: Int
        let passed: Bool
        let log: String
        let testDigest: String
        let sourceDigest: String
        let command: String
    }
    struct Handoff: Decodable {
        let id: String
        let state: String
        let repository: String
        let baseRevision: String
        let approvedRevision: String?
        let project: String?
        let scheme: String?
        let commands: [[String]]
        let steps: [String]
        let detail: String
        let ipaAvailable: Bool
    }
    struct Job: Decodable, Identifiable {
        let id: String
        let repository: String
        let state: String
        let summary: String
        let steps: [String]
        let evidence: Evidence
        let before: TestRun?
        let after: TestRun?
        let diff: String?
        let attempts: Int
        let baseRevision: String
        let branch: String?
        let commit: String?
        let handoff: Handoff?
        var active: Bool { ["reproducing", "fixing", "testing"].contains(state) }
        var stateTitle: String {
            switch state {
            case "reproducing": "Gentager fejlen"
            case "fixing": "Laver rettelsen"
            case "testing": "Tester samme kontrol igen"
            case "review": "Klar til din gennemgang"
            case "approved": "Godkendt på lokal gren"
            case "reviewOnMac": "Forslag klar · afventer Mac-test"
            case "approvedForMac": "Godkendt til Mac-test"
            case "needsMac": "Afventer Mac"
            case "needsEvidence": "Fejlen skal kunne gentages"
            case "needsInput": "Har brug for dit valg"
            case "interrupted": "Afbrudt · kan genoptages"
            default: "Ikke løst endnu"
            }
        }
    }
    struct Bundle: Decodable { let name: String; let data: Data; let handoff: Handoff }
}
