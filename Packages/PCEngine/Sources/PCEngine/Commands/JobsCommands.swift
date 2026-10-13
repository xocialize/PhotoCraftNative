// Port of photocraft-engine (crates/engine/src/jobs.rs `specs`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The job table as commands (the control channel and MCP use them too).

import PCDocument

enum JobsCommands: CommandModule {
    static let name = "jobs"

    static func register(into r: inout CommandRegistry) {
        r.add(CommandSpec("jobs.list", "List Background Jobs", module: name, journal: false) { s, _ in
            ["jobs": .array(s.jobsWithRecent.map(\.json))]
        })
        r.add(CommandSpec("jobs.cancel", "Cancel Background Job", params: #"{"job":u64? (default: every running job)}"#, module: name, journal: false) { s, p in
            switch p["job"] {
            case nil, .null?:
                let n = s.runningJobs.count
                s.cancelAllJobs()
                return ["cancelled": .int(n)]
            case let v?:
                guard let id = v.uint64Value else { throw EngineError.bad("jobs.cancel", "`job` must be a job id") }
                if s.cancelJob(JobId(id)) { return ["cancelled": 1] }
                throw EngineError.other("no running job \(id)")
            }
        })
    }
}
