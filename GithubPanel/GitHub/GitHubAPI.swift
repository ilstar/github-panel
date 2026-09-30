import Foundation
final class GitHubAPI: GitHubAPIClient {
    private let transport: HTTPTransport

    init(transport: HTTPTransport = URLSession.shared) {
        self.transport = transport
    }

    func fetchCurrentUser(token: String) async throws -> GitHubUser {
        let request = makeRequest(path: "/user", token: token)
        return try await decode(GitHubUser.self, request: request)
    }

    /// Open pull requests load in pages of 50, up to this many pages.
    static let maxOpenPullRequestPages = 10

    func fetchOpenPRs(token: String) async throws -> OpenPullRequests {
        let query = """
        query($after: String) {
          viewer {
            login
            pullRequests(first: 50, after: $after, states: [OPEN], orderBy: {field: UPDATED_AT, direction: DESC}) {
              pageInfo { hasNextPage endCursor }
              nodes {
                id
                title
                number
                url
                updatedAt
                repository {
                  nameWithOwner
                  mergeCommitAllowed
                  squashMergeAllowed
                  rebaseMergeAllowed
                  viewerDefaultMergeMethod
                }
                headRefOid
                isDraft
                autoMergeRequest { enabledAt }
                viewerCanEnableAutoMerge
                viewerCanDisableAutoMerge
                isMergeQueueEnabled
                isInMergeQueue
                mergeStateStatus
                statusCheckRollup {
                  state
                  contexts(first: 1) { totalCount }
                }
                reviewDecision
                latestOpinionatedReviews(first: 20) { nodes { state author { login } } }
                reviewRequests(first: 20) {
                  nodes {
                    requestedReviewer {
                      ... on User { login }
                      ... on Bot { login }
                      ... on Mannequin { login }
                      ... on Team { combinedSlug }
                    }
                  }
                }
              }
            }
          }
        }
        """
        var login = ""
        var nodes: [PullRequestNode] = []
        var cursor: String?
        for _ in 0..<Self.maxOpenPullRequestPages {
            let variables: [String: Any] = cursor.map { ["after": $0] } ?? [:]
            let response = try await graphQL(OpenPullRequestsResponse.self,
                                             query: query, variables: variables, token: token)
            login = response.viewer.login
            nodes += response.viewer.pullRequests.nodes
            guard let pageInfo = response.viewer.pullRequests.pageInfo,
                  pageInfo.hasNextPage,
                  let next = pageInfo.endCursor else { break }
            cursor = next
        }
        // A pull request updated between two pages can come back on both; keep its first, newer copy.
        var seen: Set<String> = []
        let rows = nodes.filter { seen.insert($0.id).inserted }.map { pr in
            PullRequestRow(id: "\(pr.repository.nameWithOwner)#\(pr.number)",
                           nodeID: pr.id,
                           title: pr.title,
                           number: pr.number,
                           repoFullName: pr.repository.nameWithOwner,
                           htmlURL: pr.url,
                           headSHA: pr.headRefOid,
                           status: CheckState(githubStatus: pr.statusCheckRollup?.state,
                                              hasCheckContexts: pr.statusCheckRollup?.contexts.map { $0.totalCount > 0 }),
                           isDraft: pr.isDraft,
                           isAutoMergeEnabled: pr.autoMergeRequest != nil,
                           canEnableAutoMerge: pr.viewerCanEnableAutoMerge,
                           canDisableAutoMerge: pr.viewerCanDisableAutoMerge,
                           isMergeQueueEnabled: pr.isMergeQueueEnabled,
                           isInMergeQueue: pr.isInMergeQueue,
                           mergeStateStatus: pr.mergeStateStatus,
                           updatedAt: pr.updatedAt,
                           reviewStatus: pr.reviewStatus,
                           mergeMethods: pr.repository.mergeMethods)
        }
        return OpenPullRequests(login: login, rows: rows)
    }

    func fetchClosedPRs(token: String, username: String, page: Int, perPage: Int) async throws -> PullRequestHistoryPage {
        let query = "is:pr author:\(username) is:closed sort:updated-desc"
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let safePage = max(1, page)
        let safePerPage = max(1, min(perPage, 100))
        let request = makeRequest(path: "/search/issues?q=\(encoded)&page=\(safePage)&per_page=\(safePerPage)", token: token)
        let response = try await decode(SearchResponse.self, request: request)
        let rows = response.items.compactMap { item -> PullRequestHistoryRow? in
            guard let repoFullName = repoFullName(from: item) else { return nil }
            return PullRequestHistoryRow(id: "\(repoFullName)#\(item.number)",
                                         title: item.title,
                                         number: item.number,
                                         repoFullName: repoFullName,
                                         htmlURL: item.htmlURL,
                                         updatedAt: item.updatedAt,
                                         closedAt: item.closedAt,
                                         mergedAt: item.pullRequest?.mergedAt)
        }
        return PullRequestHistoryPage(rows: rows,
                                      page: safePage,
                                      perPage: safePerPage,
                                      totalCount: response.totalCount)
    }

    func fetchReviewRequests(token: String) async throws -> ReviewRequests {
        let query = """
        query {
          viewer { login }
          direct: search(query: "is:pr is:open archived:false user-review-requested:@me sort:updated-desc", type: ISSUE, first: 50) {
            nodes { ...ReviewRequestFields }
          }
          all: search(query: "is:pr is:open archived:false review-requested:@me sort:updated-desc", type: ISSUE, first: 50) {
            nodes { ...ReviewRequestFields }
          }
        }

        fragment ReviewRequestFields on PullRequest {
          id
          title
          number
          url
          updatedAt
          isDraft
          repository { nameWithOwner }
          author { login }
          additions
          deletions
          statusCheckRollup {
            state
            contexts(first: 1) { totalCount }
          }
          timelineItems(itemTypes: [REVIEW_REQUESTED_EVENT], last: 20) {
            nodes {
              ... on ReviewRequestedEvent {
                createdAt
                requestedReviewer {
                  __typename
                  ... on User { login }
                }
              }
            }
          }
        }
        """
        let response = try await graphQL(ReviewRequestsResponse.self,
                                         query: query, variables: [:], token: token)
        let login = response.viewer?.login
        // A direct request's wait starts when I was asked; a team request's when a team was.
        return ReviewRequests(direct: response.direct.rows { $0.typename == "User" && (login == nil || $0.login == login) },
                              all: response.all.rows { $0.typename == "Team" })
    }

    func enqueuePullRequest(token: String, pullRequestID: String) async throws {
        let query = """
        mutation($id: ID!) {
          enqueuePullRequest(input: { pullRequestId: $id }) {
            mergeQueueEntry { id }
          }
        }
        """
        struct Response: Decodable { let enqueuePullRequest: EnqueueResult? }
        struct EnqueueResult: Decodable { let mergeQueueEntry: MergeQueueEntry }
        struct MergeQueueEntry: Decodable { let id: String }
        _ = try await graphQL(Response.self, query: query, variables: ["id": pullRequestID], token: token)
    }

    func markPullRequestReadyForReview(token: String, pullRequestID: String) async throws {
        let query = """
        mutation($id: ID!) {
          markPullRequestReadyForReview(input: { pullRequestId: $id }) {
            pullRequest { id }
          }
        }
        """
        struct Response: Decodable { let markPullRequestReadyForReview: ReadyResult? }
        struct ReadyResult: Decodable { let pullRequest: PullRequestNode }
        struct PullRequestNode: Decodable { let id: String }
        _ = try await graphQL(Response.self, query: query, variables: ["id": pullRequestID], token: token)
    }

    func enableAutoMerge(token: String, pullRequestID: String, mergeMethod: MergeMethod) async throws {
        let query = """
        mutation($id: ID!, $method: PullRequestMergeMethod!) {
          enablePullRequestAutoMerge(input: { pullRequestId: $id, mergeMethod: $method }) {
            pullRequest { id }
          }
        }
        """
        struct Response: Decodable { let enablePullRequestAutoMerge: EnableResult? }
        struct EnableResult: Decodable { let pullRequest: PullRequestNode }
        struct PullRequestNode: Decodable { let id: String }
        _ = try await graphQL(Response.self, query: query,
                              variables: ["id": pullRequestID, "method": mergeMethod.rawValue], token: token)
    }

    func disableAutoMerge(token: String, pullRequestID: String) async throws {
        let query = """
        mutation($id: ID!) {
          disablePullRequestAutoMerge(input: { pullRequestId: $id }) {
            pullRequest { id }
          }
        }
        """
        struct Response: Decodable { let disablePullRequestAutoMerge: DisableResult? }
        struct DisableResult: Decodable { let pullRequest: PullRequestNode }
        struct PullRequestNode: Decodable { let id: String }
        _ = try await graphQL(Response.self, query: query, variables: ["id": pullRequestID], token: token)
    }

    func mergePullRequest(token: String, repoFullName: String, number: Int, method: MergeMethod) async throws -> Bool {
        let parts = repoFullName.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw URLError(.badURL) }
        var request = makeRequest(path: "/repos/\(parts[0])/\(parts[1])/pulls/\(number)/merge", token: token)
        request.httpMethod = "PUT"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["merge_method": method.restValue])

        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(http.statusCode) else {
            let raw = String(data: data, encoding: .utf8) ?? "<non-utf8 response>"
            throw GitHubAPIError(message: raw, documentationURL: nil, statusCode: http.statusCode)
        }
        struct MergeResponse: Decodable { let merged: Bool }
        if let decoded = try? JSONDecoder().decode(MergeResponse.self, from: data) {
            return decoded.merged
        }
        return true
    }

    func fetchPullRequestDetail(token: String, reference: PullRequestReference) async throws -> PullRequestDetailContent {
        let parts = reference.repoFullName.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw URLError(.badURL) }
        let pullPath = "/repos/\(parts[0])/\(parts[1])/pulls/\(reference.number)"

        // The three requests do not depend on each other, so they run at the same time.
        async let pullRequest = decode(PullResponse.self, request: makeRequest(path: pullPath, token: token))
        // GitHub caps this at 100 files per page; later pages are not loaded yet.
        async let fileList = decode([PullFileResponse].self, request: makeRequest(path: "\(pullPath)/files?per_page=100", token: token))
        // Viewed marks and edit rights are a nice-to-have; the diff still loads when GitHub does not return them.
        async let viewerState = try? fetchViewerState(token: token, owner: parts[0], name: parts[1], number: reference.number)
        let pull = try await pullRequest
        let files = try await fileList
        let viewer = await viewerState
        let viewed = viewer?.viewedFiles ?? []
        let ownership = try? await fetchCodeOwners(token: token, owner: parts[0], name: parts[1], baseRef: pull.base.ref,
                                                   paths: files.map { $0.filename })
        var detail = pull.detail(reference: reference)
        detail.canEdit = viewer?.canEdit ?? false
        detail.isViewerAuthor = viewer?.isAuthor ?? false
        detail.canUpdateBranch = (detail.state == .open || detail.state == .draft) && viewer?.canUpdateBranch == true
        return PullRequestDetailContent(detail: detail,
                                        files: files.map { file in
                                            var file = file.file
                                            file.isViewed = viewed.contains(file.filename)
                                            file.codeOwners = ownership?.owners.owners(for: file.filename) ?? []
                                            file.isOwnedByViewer = CodeOwners.isOwnedByViewer(file.codeOwners,
                                                login: ownership?.login ?? "", email: ownership?.email, teams: ownership?.teams ?? [])
                                            return file
                                        })
    }

    /// Read all supported locations in one request, using the base branch and GitHub's location precedence.
    private func fetchCodeOwners(token: String, owner: String, name: String, baseRef: String,
                                 paths: [String]) async throws -> (owners: CodeOwners, login: String, email: String?, teams: Set<String>) {
        let query = """
        query($owner: String!, $name: String!, $github: String!, $root: String!, $docs: String!) {
          viewer { login email }
          repository(owner: $owner, name: $name) {
            github: object(expression: $github) { ... on Blob { text } }
            root: object(expression: $root) { ... on Blob { text } }
            docs: object(expression: $docs) { ... on Blob { text } }
          }
        }
        """
        struct Response: Decodable {
            struct Viewer: Decodable { let login: String; let email: String? }
            struct Blob: Decodable { let text: String? }
            struct Repository: Decodable { let github: Blob?; let root: Blob?; let docs: Blob? }
            let viewer: Viewer
            let repository: Repository?
        }
        let response = try await graphQL(Response.self, query: query,
            variables: ["owner": owner, "name": name, "github": baseRef + ":.github/CODEOWNERS",
                        "root": baseRef + ":CODEOWNERS", "docs": baseRef + ":docs/CODEOWNERS"], token: token)
        let rules = CodeOwners(response.repository?.github?.text ?? response.repository?.root?.text ?? response.repository?.docs?.text ?? "")
        let teamOwners = Set(paths.flatMap { rules.owners(for: $0) }.filter { $0.hasPrefix("@") && $0.contains("/") })
        let teams = await withTaskGroup(of: String?.self) { group in
            for team in teamOwners {
                group.addTask {
                    let parts = team.dropFirst().split(separator: "/").map(String.init)
                    guard parts.count == 2 else { return nil }
                    struct Membership: Decodable { let state: String }
                    let request = self.makeRequest(path: "/orgs/\(parts[0])/teams/\(parts[1])/memberships/\(response.viewer.login)", token: token)
                    let membership = try? await self.decode(Membership.self, request: request)
                    return membership?.state == "active" ? team.lowercased() : nil
                }
            }
            var result: Set<String> = []
            for await team in group { if let team { result.insert(team) } }
            return result
        }
        return (rules, response.viewer.login, response.viewer.email, teams)
    }

    func setFileViewed(token: String, pullRequestID: String, path: String, viewed: Bool) async throws {
        let mutation = viewed ? "markFileAsViewed" : "unmarkFileAsViewed"
        let query = """
        mutation($id: ID!, $path: String!) {
          \(mutation)(input: { pullRequestId: $id, path: $path }) {
            pullRequest { id }
          }
        }
        """
        struct Response: Decodable {}
        _ = try await graphQL(Response.self, query: query, variables: ["id": pullRequestID, "path": path], token: token)
    }

    func setReviewThreadResolved(token: String, threadID: String, resolved: Bool) async throws {
        let mutation = resolved ? "resolveReviewThread" : "unresolveReviewThread"
        let query = """
        mutation($id: ID!) {
          \(mutation)(input: { threadId: $id }) {
            thread { id isResolved }
          }
        }
        """
        struct Response: Decodable {}
        _ = try await graphQL(Response.self, query: query, variables: ["id": threadID], token: token)
    }

    func fetchPullRequestComments(token: String, reference: PullRequestReference) async throws -> PullRequestComments {
        let (owner, name) = try repoParts(reference.repoFullName)
        // Only the first 100 comments and threads are loaded, like the changed files.
        let query = """
        query($owner: String!, $name: String!, $number: Int!) {
          repository(owner: $owner, name: $name) {
            pullRequest(number: $number) {
              comments(first: 100) { nodes { ...CommentFields } }
              reviews(states: PENDING, first: 1) { nodes { id viewerDidAuthor } }
              reviewThreads(first: 100) {
                nodes {
                  id path line startLine diffSide isResolved isOutdated
                  comments(first: 100) { nodes { ...CommentFields } }
                }
              }
            }
          }
        }

        fragment CommentFields on Comment {
          id
          body
          createdAt
          author { login }
          ... on IssueComment { databaseId url }
          ... on PullRequestReviewComment { databaseId url state }
        }
        """
        let response = try await graphQL(CommentsResponse.self,
                                         query: query,
                                         variables: ["owner": owner, "name": name, "number": reference.number],
                                         token: token)
        guard let pullRequest = response.repository?.pullRequest else {
            throw GraphQLError(message: "Pull request \(reference.id) was not found.")
        }
        return PullRequestComments(
            comments: pullRequest.comments.nodes.map(\.comment),
            threads: pullRequest.reviewThreads.nodes.map { thread in
                ReviewThread(id: thread.id,
                             path: thread.path,
                             line: thread.line,
                             startLine: thread.startLine,
                             side: DiffSide(rawValue: thread.diffSide) ?? .right,
                             isResolved: thread.isResolved,
                             isOutdated: thread.isOutdated,
                             comments: thread.comments.nodes.map(\.comment))
            },
            // GitHub shows a pending review only to its author, but check in case that changes.
            pendingReviewID: pullRequest.reviews?.nodes.first { $0.viewerDidAuthor }?.id
        )
    }

    /// Posts through REST so each comment is published right away instead of joining a pending review.
    func postPullRequestComment(token: String, reference: PullRequestReference, comment: NewPullRequestComment) async throws {
        let (owner, name) = try repoParts(reference.repoFullName)
        let repoPath = "/repos/\(owner)/\(name)"
        let path: String
        let body: [String: Any]
        switch comment {
        case let .general(text):
            path = "\(repoPath)/issues/\(reference.number)/comments"
            body = ["body": text]
        case let .inline(text, commitID, anchor):
            path = "\(repoPath)/pulls/\(reference.number)/comments"
            body = ["body": text,
                    "commit_id": commitID,
                    "path": anchor.path,
                    "line": anchor.line,
                    "side": anchor.side.rawValue]
        case let .reply(text, commentID):
            path = "\(repoPath)/pulls/\(reference.number)/comments/\(commentID)/replies"
            body = ["body": text]
        }
        var request = makeRequest(path: path, token: token)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        struct Created: Decodable { let id: Int }
        _ = try await decode(Created.self, request: request)
    }

    /// Replaces the pull request's title, description, or both. Fields left nil are not sent, so GitHub keeps them.
    func editPullRequest(token: String, reference: PullRequestReference, title: String?, body: String?) async throws {
        let (owner, name) = try repoParts(reference.repoFullName)
        var request = makeRequest(path: "/repos/\(owner)/\(name)/pulls/\(reference.number)", token: token)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var fields: [String: String] = [:]
        fields["title"] = title
        fields["body"] = body
        request.httpBody = try JSONSerialization.data(withJSONObject: fields)
        struct Updated: Decodable { let number: Int }
        _ = try await decode(Updated.self, request: request)
    }

    /// Submits a review with its verdict in one step, so GitHub publishes it right away instead of keeping it pending.
    func submitReview(token: String, reference: PullRequestReference, review: NewPullRequestReview) async throws {
        let (owner, name) = try repoParts(reference.repoFullName)
        var request = makeRequest(path: "/repos/\(owner)/\(name)/pulls/\(reference.number)/reviews", token: token)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var fields: [String: String] = ["event": review.event.rawValue, "commit_id": review.commitID]
        if !review.body.isEmpty {
            fields["body"] = review.body
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: fields)
        struct Created: Decodable { let id: Int }
        _ = try await decode(Created.self, request: request)
    }

    /// Starts a pending review, which holds draft comments until it is submitted with a verdict.
    func startPendingReview(token: String, pullRequestID: String, commitID: String) async throws -> String {
        let query = """
        mutation($id: ID!, $commit: GitObjectID!) {
          addPullRequestReview(input: { pullRequestId: $id, commitOID: $commit }) {
            pullRequestReview { id }
          }
        }
        """
        struct Response: Decodable {
            struct Payload: Decodable { let pullRequestReview: Review }
            struct Review: Decodable { let id: String }
            let addPullRequestReview: Payload
        }
        let response = try await graphQL(Response.self, query: query, variables: ["id": pullRequestID, "commit": commitID], token: token)
        return response.addPullRequestReview.pullRequestReview.id
    }

    /// Adds a draft comment to a pending review. The pull request's author is not notified until the review is submitted.
    func addPendingReviewComment(token: String, reviewID: String, comment: PendingReviewComment) async throws {
        let query: String
        var variables: [String: Any] = ["review": reviewID]
        switch comment {
        case let .thread(body, anchor):
            query = """
            mutation($review: ID!, $path: String!, $line: Int!, $side: DiffSide!, $body: String!) {
              addPullRequestReviewThread(input: { pullRequestReviewId: $review, path: $path, line: $line, side: $side, body: $body }) {
                thread { id }
              }
            }
            """
            variables["path"] = anchor.path
            variables["line"] = anchor.line
            variables["side"] = anchor.side.rawValue
            variables["body"] = body
        case let .reply(body, threadID):
            query = """
            mutation($review: ID!, $thread: ID!, $body: String!) {
              addPullRequestReviewThreadReply(input: { pullRequestReviewId: $review, pullRequestReviewThreadId: $thread, body: $body }) {
                comment { id }
              }
            }
            """
            variables["thread"] = threadID
            variables["body"] = body
        }
        struct Response: Decodable {}
        _ = try await graphQL(Response.self, query: query, variables: variables, token: token)
    }

    /// Publishes a pending review and all its draft comments with a verdict.
    func submitPendingReview(token: String, reviewID: String, event: PullRequestReviewEvent, body: String) async throws {
        let query = """
        mutation($review: ID!, $event: PullRequestReviewEvent!, $body: String) {
          submitPullRequestReview(input: { pullRequestReviewId: $review, event: $event, body: $body }) {
            pullRequestReview { id }
          }
        }
        """
        var variables: [String: Any] = ["review": reviewID, "event": event.rawValue]
        if !body.isEmpty {
            variables["body"] = body
        }
        struct Response: Decodable {}
        _ = try await graphQL(Response.self, query: query, variables: variables, token: token)
    }

    /// Discards a pending review and its draft comments.
    func deletePendingReview(token: String, reviewID: String) async throws {
        let query = """
        mutation($review: ID!) {
          deletePullRequestReview(input: { pullRequestReviewId: $review }) {
            pullRequestReview { id }
          }
        }
        """
        struct Response: Decodable {}
        _ = try await graphQL(Response.self, query: query, variables: ["review": reviewID], token: token)
    }

    /// Merges the base branch into the pull request's branch, like GitHub's Update branch button.
    /// GitHub refuses when the branch moved past `expectedHeadSHA`, so a push made meanwhile is not merged over blindly.
    func updatePullRequestBranch(token: String, pullRequestID: String, expectedHeadSHA: String) async throws {
        let query = """
        mutation($id: ID!, $head: GitObjectID!) {
          updatePullRequestBranch(input: { pullRequestId: $id, expectedHeadOid: $head, updateMethod: MERGE }) {
            pullRequest { id }
          }
        }
        """
        struct Response: Decodable {}
        _ = try await graphQL(Response.self, query: query, variables: ["id": pullRequestID, "head": expectedHeadSHA], token: token)
    }

    /// Only the first 100 checks load, which covers all but the largest matrices.
    func fetchPullRequestChecks(token: String, reference: PullRequestReference) async throws -> PullRequestChecks {
        let (owner, name) = try repoParts(reference.repoFullName)
        let query = """
        query($owner: String!, $name: String!, $number: Int!) {
          repository(owner: $owner, name: $name) {
            id
            pullRequest(number: $number) {
              commits(last: 1) {
                nodes {
                  commit {
                    statusCheckRollup {
                      contexts(first: 100) {
                        nodes {
                          __typename
                          ... on CheckRun {
                            id name status conclusion startedAt completedAt detailsUrl title
                            isRequired(pullRequestNumber: $number)
                            checkSuite {
                              id
                              app { name }
                              workflowRun { databaseId workflow { name } }
                            }
                          }
                          ... on StatusContext {
                            id context state description targetUrl createdAt
                            isRequired(pullRequestNumber: $number)
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
        """
        let response = try await graphQL(ChecksResponse.self, query: query,
                                         variables: ["owner": owner, "name": name, "number": reference.number],
                                         token: token)
        guard let repository = response.repository, let pullRequest = repository.pullRequest else {
            throw GraphQLError(message: "Pull request \(reference.id) was not found.")
        }
        let contexts = pullRequest.commits.nodes.last?.commit.statusCheckRollup?.contexts.nodes ?? []
        return PullRequestChecks(checks: contexts.compactMap { $0.check(repositoryID: repository.id) })
    }

    func rerunChecks(token: String, repoFullName: String, rerun: CheckRerun) async throws {
        switch rerun {
        case let .workflowRun(runID):
            let (owner, name) = try repoParts(repoFullName)
            var request = makeRequest(path: "/repos/\(owner)/\(name)/actions/runs/\(runID)/rerun-failed-jobs", token: token)
            request.httpMethod = "POST"
            let (data, response) = try await transport.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard (200...299).contains(http.statusCode) else {
                if let apiError = try? JSONDecoder().decode(GitHubAPIError.self, from: data) {
                    throw apiError.withStatus(http.statusCode)
                }
                throw GitHubAPIError(message: "Unexpected response from GitHub.", documentationURL: nil, statusCode: http.statusCode)
            }
        case let .checkSuite(repositoryID, suiteID):
            let query = """
            mutation($repo: ID!, $suite: ID!) {
              rerequestCheckSuite(input: { repositoryId: $repo, checkSuiteId: $suite }) {
                checkSuite { id }
              }
            }
            """
            struct Response: Decodable {}
            _ = try await graphQL(Response.self, query: query, variables: ["repo": repositoryID, "suite": suiteID], token: token)
        }
    }

    /// Paths the viewer marked as viewed, whether they may edit the pull request, and whether GitHub offers Update branch.
    /// GitHub reports files changed since they were viewed as `DISMISSED`, not `VIEWED`.
    /// `viewerCanUpdateBranch` is false when the branch is up to date. GitHub shows the button only when the repository
    /// suggests updating branches, or when its rules require an up-to-date branch, which makes the merge state `BEHIND`.
    private func fetchViewerState(token: String, owner: String, name: String, number: Int) async throws -> (viewedFiles: Set<String>, canEdit: Bool, isAuthor: Bool, canUpdateBranch: Bool) {
        let query = """
        query($owner: String!, $name: String!, $number: Int!) {
          repository(owner: $owner, name: $name) {
            pullRequest(number: $number) {
              viewerDidAuthor
              viewerCanUpdate
              viewerCanUpdateBranch
              mergeStateStatus
              baseRepository { allowUpdateBranch }
              files(first: 100) { nodes { path viewerViewedState } }
            }
          }
        }
        """
        let response = try await graphQL(ViewerStateResponse.self,
                                         query: query,
                                         variables: ["owner": owner, "name": name, "number": number],
                                         token: token)
        let pullRequest = response.repository?.pullRequest
        let nodes = pullRequest?.files?.nodes ?? []
        let isAuthor = pullRequest?.viewerDidAuthor == true
        let canEdit = isAuthor && pullRequest?.viewerCanUpdate == true
        let suggestsUpdate = pullRequest?.baseRepository?.allowUpdateBranch == true || pullRequest?.mergeStateStatus == "BEHIND"
        let canUpdateBranch = pullRequest?.viewerCanUpdateBranch == true && suggestsUpdate
        return (Set(nodes.filter { $0.viewerViewedState == "VIEWED" }.map(\.path)), canEdit, isAuthor, canUpdateBranch)
    }

    private func repoParts(_ repoFullName: String) throws -> (owner: String, name: String) {
        let parts = repoFullName.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw URLError(.badURL) }
        return (parts[0], parts[1])
    }

    private func makeRequest(path: String, token: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.github.com\(path)")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("GithubPanel", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        return request
    }

    private func repoFullName(from item: SearchItem) -> String? {
        let components = item.repositoryURL.pathComponents
        guard components.count >= 4 else { return nil }
        return "\(components[2])/\(components[3])"
    }

    private func decode<T: Decodable>(_ type: T.Type, request: URLRequest) async throws -> T {
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(http.statusCode) else {
            if let apiError = try? JSONDecoder().decode(GitHubAPIError.self, from: data) {
                throw apiError.withStatus(http.statusCode)
            }
            throw GitHubAPIError(message: "Unexpected response from GitHub.", documentationURL: nil, statusCode: http.statusCode)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    private func graphQL<T: Decodable>(_ type: T.Type,
                                       query: String,
                                       variables: [String: Any],
                                       token: String) async throws -> T {
        var request = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("GithubPanel", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["query": query, "variables": variables]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(http.statusCode) else {
            let raw = String(data: data, encoding: .utf8) ?? "<non-utf8 response>"
            throw GraphQLError(message: "GraphQL HTTP \(http.statusCode): \(raw)", statusCode: http.statusCode)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope: GraphQLResponse<T>
        do {
            envelope = try decoder.decode(GraphQLResponse<T>.self, from: data)
        } catch {
            let raw = String(data: data, encoding: .utf8) ?? "<non-utf8 response>"
            throw GraphQLError(message: "GraphQL decode failed: \(raw)")
        }
        if let errors = envelope.errors, !errors.isEmpty {
            throw GraphQLError(message: errors.map(\.message).joined(separator: " "))
        }
        guard let value = envelope.data else {
            throw GraphQLError(message: "Empty response from GitHub.")
        }
        return value
    }
}

struct GitHubAPIError: Decodable, LocalizedError {
    let message: String
    let documentationURL: URL?
    var statusCode: Int?

    enum CodingKeys: String, CodingKey {
        case message
        case documentationURL = "documentation_url"
    }

    func withStatus(_ status: Int) -> GitHubAPIError {
        var copy = self
        copy.statusCode = status
        return copy
    }

    var errorDescription: String? {
        if let statusCode {
            return "GitHub API error (\(statusCode)): \(message)"
        }
        return "GitHub API error: \(message)"
    }
}

private struct SearchResponse: Decodable {
    let totalCount: Int
    let items: [SearchItem]

    enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case items
    }
}

private struct SearchItem: Decodable {
    let number: Int
    let repositoryURL: URL
    let title: String
    let htmlURL: URL
    let updatedAt: Date
    let closedAt: Date?
    let pullRequest: SearchPullRequest?

    enum CodingKeys: String, CodingKey {
        case number
        case repositoryURL = "repository_url"
        case title
        case htmlURL = "html_url"
        case updatedAt = "updated_at"
        case closedAt = "closed_at"
        case pullRequest = "pull_request"
    }
}

private struct SearchPullRequest: Decodable {
    let mergedAt: Date?

    enum CodingKeys: String, CodingKey {
        case mergedAt = "merged_at"
    }
}

private struct PullResponse: Decodable {
    struct User: Decodable {
        let login: String
    }

    struct Ref: Decodable {
        let ref: String
        let sha: String
    }

    let nodeID: String
    let title: String
    let body: String?
    let user: User
    let state: String
    let draft: Bool?
    let mergedAt: Date?
    let base: Ref
    let head: Ref
    let htmlURL: URL
    let createdAt: Date
    let updatedAt: Date?
    let additions: Int
    let deletions: Int
    let changedFiles: Int
    let commits: Int

    enum CodingKeys: String, CodingKey {
        case title, body, user, state, draft, base, head, additions, deletions, commits
        case nodeID = "node_id"
        case mergedAt = "merged_at"
        case htmlURL = "html_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case changedFiles = "changed_files"
    }

    func detail(reference: PullRequestReference) -> PullRequestDetail {
        let detailState: PullRequestDetail.State
        if mergedAt != nil {
            detailState = .merged
        } else if state == "closed" {
            detailState = .closed
        } else if draft == true {
            detailState = .draft
        } else {
            detailState = .open
        }
        return PullRequestDetail(reference: reference,
                                 nodeID: nodeID,
                                 title: title,
                                 body: body ?? "",
                                 authorLogin: user.login,
                                 state: detailState,
                                 baseRef: base.ref,
                                 headRef: head.ref,
                                 headSHA: head.sha,
                                 htmlURL: htmlURL,
                                 createdAt: createdAt,
                                 additions: additions,
                                 deletions: deletions,
                                 changedFiles: changedFiles,
                                 commits: commits,
                                 updatedAt: updatedAt)
    }
}

private struct PullFileResponse: Decodable {
    let filename: String
    let previousFilename: String?
    let status: String
    let additions: Int
    let deletions: Int
    let patch: String?

    enum CodingKeys: String, CodingKey {
        case filename, status, additions, deletions, patch
        case previousFilename = "previous_filename"
    }

    var file: PullRequestFile {
        PullRequestFile(filename: filename,
                        previousFilename: previousFilename,
                        status: PullRequestFile.Status(rawValue: status) ?? .changed,
                        additions: additions,
                        deletions: deletions,
                        patch: patch)
    }
}

private struct ViewerStateResponse: Decodable {
    struct Repository: Decodable { let pullRequest: PullRequest? }
    struct PullRequest: Decodable {
        let viewerDidAuthor: Bool?
        let viewerCanUpdate: Bool?
        let viewerCanUpdateBranch: Bool?
        let mergeStateStatus: String?
        let baseRepository: BaseRepository?
        let files: Files?
    }
    struct BaseRepository: Decodable { let allowUpdateBranch: Bool? }
    struct Files: Decodable { let nodes: [File] }
    struct File: Decodable {
        let path: String
        let viewerViewedState: String
    }

    let repository: Repository?
}

private struct CommentsResponse: Decodable {
    struct Repository: Decodable { let pullRequest: PullRequest? }
    struct PullRequest: Decodable {
        let comments: Connection<Comment>
        let reviewThreads: Connection<Thread>
        /// The viewer's pending review, if any.
        let reviews: Connection<Review>?
    }
    struct Review: Decodable {
        let id: String
        let viewerDidAuthor: Bool
    }
    struct Connection<Node: Decodable>: Decodable { let nodes: [Node] }
    struct Thread: Decodable {
        let id: String
        let path: String
        let line: Int?
        let startLine: Int?
        let diffSide: String
        let isResolved: Bool
        let isOutdated: Bool
        let comments: Connection<Comment>
    }
    struct Comment: Decodable {
        struct Author: Decodable { let login: String }

        let id: String
        let databaseId: Int
        let body: String
        let createdAt: Date
        let url: URL?
        /// Missing when the author's account was deleted.
        let author: Author?
        /// `PENDING` for a draft in the viewer's pending review. Only review comments have it.
        let state: String?

        var comment: PullRequestComment {
            PullRequestComment(id: id,
                               databaseID: databaseId,
                               authorLogin: author?.login ?? "ghost",
                               body: body,
                               createdAt: createdAt,
                               htmlURL: url,
                               isPending: state == "PENDING")
        }
    }

    let repository: Repository?
}

private struct ChecksResponse: Decodable {
    struct Repository: Decodable {
        let id: String
        let pullRequest: PullRequest?
    }
    struct PullRequest: Decodable { let commits: Connection<CommitNode> }
    struct Connection<Node: Decodable>: Decodable { let nodes: [Node] }
    struct CommitNode: Decodable { let commit: Commit }
    struct Commit: Decodable { let statusCheckRollup: Rollup? }
    struct Rollup: Decodable { let contexts: Connection<Context> }
    struct Context: Decodable {
        struct CheckSuite: Decodable {
            struct App: Decodable { let name: String }
            struct WorkflowRun: Decodable {
                struct Workflow: Decodable { let name: String }
                let databaseId: Int
                let workflow: Workflow?
            }
            let id: String
            let app: App?
            let workflowRun: WorkflowRun?
        }

        let typename: String
        let id: String?
        let isRequired: Bool?
        // CheckRun
        let name: String?
        let status: String?
        let conclusion: String?
        let startedAt: Date?
        let completedAt: Date?
        let detailsUrl: URL?
        let title: String?
        let checkSuite: CheckSuite?
        // StatusContext
        let context: String?
        let state: String?
        let description: String?
        let targetUrl: URL?
        let createdAt: Date?

        enum CodingKeys: String, CodingKey {
            case typename = "__typename"
            case id, isRequired, name, status, conclusion, startedAt, completedAt, detailsUrl, title, checkSuite
            case context, state, description, targetUrl, createdAt
        }

        func check(repositoryID: String) -> PullRequestCheck? {
            switch typename {
            case "CheckRun":
                guard let id, let name, let status else { return nil }
                let outcome = PullRequestCheck.outcome(status: status, conclusion: conclusion)
                let rerun: CheckRerun? = checkSuite.map { suite in
                    suite.workflowRun.map { .workflowRun($0.databaseId) }
                        ?? .checkSuite(repositoryID: repositoryID, suiteID: suite.id)
                }
                // GitHub leaves the summary blank for most Actions jobs; name the conclusion when it is not plain failure.
                let summary = title?.isEmpty == false ? title
                    : ["CANCELLED", "TIMED_OUT", "STARTUP_FAILURE", "ACTION_REQUIRED"].contains(conclusion ?? "")
                        ? conclusion?.replacingOccurrences(of: "_", with: " ").capitalized : nil
                return PullRequestCheck(id: id,
                                        name: name,
                                        workflowName: checkSuite?.workflowRun?.workflow?.name ?? checkSuite?.app?.name,
                                        outcome: outcome,
                                        summary: summary,
                                        startedAt: startedAt,
                                        completedAt: status == "COMPLETED" ? completedAt : nil,
                                        detailsURL: detailsUrl,
                                        isRequired: isRequired ?? false,
                                        rerun: rerun)
            case "StatusContext":
                guard let id, let context, let state else { return nil }
                return PullRequestCheck(id: id,
                                        name: context,
                                        workflowName: nil,
                                        outcome: PullRequestCheck.outcome(statusState: state),
                                        summary: description?.isEmpty == false ? description : nil,
                                        startedAt: nil,
                                        completedAt: nil,
                                        detailsURL: targetUrl,
                                        isRequired: isRequired ?? false)
            default:
                return nil
            }
        }
    }

    let repository: Repository?
}

private struct OpenPullRequestsResponse: Decodable {
    let viewer: Viewer

    struct Viewer: Decodable {
        let login: String
        let pullRequests: Connection
    }

    struct Connection: Decodable {
        let pageInfo: PageInfo?
        let nodes: [PullRequestNode]
    }

    struct PageInfo: Decodable {
        let hasNextPage: Bool
        let endCursor: String?
    }
}

private struct PullRequestNode: Decodable {
    let updatedAt: Date
    let repository: Repository

    struct Repository: Decodable {
        let nameWithOwner: String
        /// Only the My PRs query asks for these.
        var mergeCommitAllowed: Bool?
        var squashMergeAllowed: Bool?
        var rebaseMergeAllowed: Bool?
        var viewerDefaultMergeMethod: String?

        var mergeMethods: RepositoryMergeMethods {
            let allowed: [(MergeMethod, Bool?)] = [(.merge, mergeCommitAllowed),
                                                   (.squash, squashMergeAllowed),
                                                   (.rebase, rebaseMergeAllowed)]
            return RepositoryMergeMethods(allowed: allowed.filter { $0.1 ?? ($0.0 == .merge) }.map { $0.0 },
                                          suggested: viewerDefaultMergeMethod.flatMap(MergeMethod.init(rawValue:)) ?? .merge)
        }
    }

    let id: String
    let title: String
    let number: Int
    let url: URL
    let headRefOid: String
    let isDraft: Bool
    let autoMergeRequest: AutoMergeRequest?
    let viewerCanEnableAutoMerge: Bool
    let viewerCanDisableAutoMerge: Bool
    let isMergeQueueEnabled: Bool
    let isInMergeQueue: Bool
    let mergeStateStatus: String
    let statusCheckRollup: StatusCheckRollup?
    let reviewDecision: String?
    let latestOpinionatedReviews: Connection<Review>?
    let reviewRequests: Connection<ReviewRequest>?

    struct Connection<Node: Decodable>: Decodable { let nodes: [Node] }
    struct Login: Decodable { let login: String }
    struct Review: Decodable {
        let state: String
        /// Missing when the reviewer's account was deleted.
        let author: Login?
    }
    struct ReviewRequest: Decodable {
        struct Reviewer: Decodable {
            let login: String?
            let combinedSlug: String?
        }
        let requestedReviewer: Reviewer?
    }

    var reviewStatus: PullRequestReviewStatus {
        let reviews = latestOpinionatedReviews?.nodes ?? []
        func reviewers(_ state: String) -> [String] {
            reviews.filter { $0.state == state }.compactMap { $0.author?.login }
        }
        return PullRequestReviewStatus(
            decision: reviewDecision.flatMap(ReviewDecision.init(rawValue:)),
            approvedBy: reviewers("APPROVED"),
            changesRequestedBy: reviewers("CHANGES_REQUESTED"),
            waitingOn: (reviewRequests?.nodes ?? []).compactMap { request in
                request.requestedReviewer.flatMap { $0.login ?? $0.combinedSlug }
            })
    }
}

private struct ReviewRequestsResponse: Decodable {
    let viewer: Author?
    let direct: Search
    let all: Search

    struct Search: Decodable {
        let nodes: [Node]

        /// `isMyRequest` picks the review-requested events that count as asking me.
        func rows(isMyRequest: (Reviewer) -> Bool) -> [ReviewRequestRow] {
            nodes.map { pr in
                let requests = (pr.timelineItems?.nodes ?? []).filter { event in
                    event.requestedReviewer.map(isMyRequest) ?? false
                }
                return ReviewRequestRow(id: "\(pr.repository.nameWithOwner)#\(pr.number)",
                                        title: pr.title,
                                        number: pr.number,
                                        repoFullName: pr.repository.nameWithOwner,
                                        htmlURL: pr.url,
                                        authorLogin: pr.author?.login,
                                        isDraft: pr.isDraft,
                                        updatedAt: pr.updatedAt,
                                        checkState: pr.statusCheckRollup.map {
                                            CheckState(githubStatus: $0.state,
                                                       hasCheckContexts: $0.contexts.map { $0.totalCount > 0 })
                                        },
                                        additions: pr.additions,
                                        deletions: pr.deletions,
                                        requestedAt: requests.compactMap(\.createdAt).max())
            }
        }
    }

    struct Node: Decodable {
        let title: String
        let number: Int
        let url: URL
        let updatedAt: Date
        let isDraft: Bool
        let repository: PullRequestNode.Repository
        let author: Author?
        let additions: Int?
        let deletions: Int?
        let statusCheckRollup: StatusCheckRollup?
        let timelineItems: Timeline?
    }

    struct Timeline: Decodable {
        let nodes: [Event]
    }

    struct Event: Decodable {
        let createdAt: Date?
        let requestedReviewer: Reviewer?
    }

    struct Reviewer: Decodable {
        let typename: String
        let login: String?

        enum CodingKeys: String, CodingKey {
            case typename = "__typename"
            case login
        }
    }

    struct Author: Decodable {
        let login: String
    }
}

private struct StatusCheckRollup: Decodable {
    let state: String
    let contexts: StatusCheckContexts?
}

private struct StatusCheckContexts: Decodable {
    let totalCount: Int
}

private struct AutoMergeRequest: Decodable {}

private struct GraphQLResponse<T: Decodable>: Decodable {
    let data: T?
    let errors: [GraphQLErrorPayload]?
}

private struct GraphQLErrorPayload: Decodable {
    let message: String
}

struct GraphQLError: LocalizedError {
    let message: String
    var statusCode: Int? = nil

    var errorDescription: String? { message }
}
