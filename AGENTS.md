# Working on NewExplorer

Read HANDOVER.md and inspect the current branch, main and open pull requests before editing. Use one development branch per milestone. Keep working UI and file behavior unless Amine approves a change. Review the diff and test results before merging.

Trace failures through the production entry point. Preserve files on failure or cancellation, including after relaunch. Use a regression test for each reproducible fix. Reuse Scripts/generate_project.py whenever Swift files or build settings change. Keep the version, build number, packaging assertions, workflow artifact name and README release history in sync.

Update HANDOVER.md with decisions, evidence, open issues and the next check. Report simulator, package validation, performance measurements and physical device results separately. Device target is iPhone 17 Pro Max, iOS 27.2.1, signed with KravaSigner. Keep signing material and credentials out of git.
