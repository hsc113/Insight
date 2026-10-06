import AppKit
import Darwin
import Foundation
@testable import InsightCore

// stdout is block-buffered when redirected, so a crash would swallow every check that already
// ran. Line buffering keeps the output useful precisely when something goes wrong.
setvbuf(stdout, nil, _IOLBF, 0)

// The checker never writes the user's data.
//
// Both stores have their own guard, and **`Secrets` went without one for a long time** — which is
// how six thousand `llm.custom-XXXX.apiKey = "sk-test"` entries accumulated in a real
// `secrets.json`. `Settings` was already covered; `Secrets` was not, and the checker makes a
// *fresh random* custom provider every run, so every run leaked at least one entry. Nothing
// failed, which is the whole problem: the file just grew.
//
// Turned off here rather than inside each check, because "this process must not write the user's
// files" is a property of the process, not of any individual assertion — and a per-check switch is
// exactly the kind of thing the next check forgets to set.
Settings.persistenceEnabled = false
Secrets.persistenceEnabled = false

print("Insight 检查")
print(String(repeating: "─", count: 46))

await ConfigChecks.run()
await StreamingChecks.run()
await PipelineChecks.run()

exit(Check.summarize())