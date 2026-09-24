import Foundation

enum PullRequestHookScenario: String {
    case anyFailures = "any_failures"
    case allSucceeded = "all_succeeded"
}

struct PullRequestHookContext {
    let scenario: PullRequestHookScenario
    let status: CheckState
    let id: String
    let nodeID: String
    let number: Int
    let title: String
    let repoFullName: String
    let htmlURL: URL
    let headSHA: String

    var environment: [String: String] {
        let repoParts = repoFullName.split(separator: "/", maxSplits: 1).map(String.init)
        var values = [
            "GITHUB_PANEL_HOOK_SCENARIO": scenario.rawValue,
            "GITHUB_PANEL_PR_STATUS": status.rawValue,
            "GITHUB_PANEL_PR_ID": id,
            "GITHUB_PANEL_PR_NODE_ID": nodeID,
            "GITHUB_PANEL_PR_NUMBER": String(number),
            "GITHUB_PANEL_PR_TITLE": title,
            "GITHUB_PANEL_REPO_FULL_NAME": repoFullName,
            "GITHUB_PANEL_PR_URL": htmlURL.absoluteString,
            "GITHUB_PANEL_PR_HEAD_SHA": headSHA
        ]
        if repoParts.count == 2 {
            values["GITHUB_PANEL_REPO_OWNER"] = repoParts[0]
            values["GITHUB_PANEL_REPO_NAME"] = repoParts[1]
        }
        return values
    }
}

protocol PullRequestHookRunning {
    func run(script: String, context: PullRequestHookContext)
}

struct SystemPullRequestHookRunner: PullRequestHookRunning {
    func run(script: String, context: PullRequestHookContext) {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", trimmed]
            var environment = ProcessInfo.processInfo.environment
            context.environment.forEach { environment[$0.key] = $0.value }
            process.environment = environment

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                NSLog("GithubPanel hook failed to start: \(error.localizedDescription)")
            }
        }
    }
}
