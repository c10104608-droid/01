# Export Integrity Repair

## Defects repaired

1. **Mid-record JSONL/TXT truncation**: runtime class index and detailed runtime collectors now checkpoint byte offsets at safe batch boundaries. On relaunch, incomplete bytes are truncated back to the last checkpoint and collection resumes from the saved class index.
2. **PASS files missing from ZIP**: the session manifest enumerates expected outputs by phase, detects missing files even when a phase reports PASS, and the final ZIP is built only after final logs and the manifest exist. A second ZIP pass is validated against the session file count before sharing.
3. **Loaded-image count disagreement**: `LegacyWriteLoadedImages` now records enumerated, written, and error counts. The returned count is the number of successfully written JSONL/text records. The manifest cross-checks summary, JSONL records, and TXT lines.

## Output validation

- Every JSONL file is streamed and parsed record-by-record.
- Text outputs are required to end on a newline.
- Every manifest file entry records size and incremental checksum.
- Missing or malformed outputs force `overallStatus=PARTIAL`.
- ZIP central-directory count, ZIP structural validity, and expected session-file count are checked before sharing.
- `FINAL_LOG.txt`, `FINAL_LOG.json`, and `SESSION_MANIFEST.json` report `PARTIAL` whenever work is incomplete or any validation disagrees.

## Scope

The existing legacy collectors remain the source of truth. Runtime class records additionally expose an app-owned classification heuristic and a conservative Swift-runtime heuristic based only on registered Objective-C class/image metadata. No target application, bundle identifier, or third-party repository is hardcoded.

The public `YangJiiii/3105` v2.0 release was used only as a comparison test for general app-owned/Swift-facing data priorities; it is not a runtime dependency or collection target.
