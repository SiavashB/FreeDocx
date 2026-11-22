# FreeDocx Code Review

- **Date:** 2026-09-05
- **Scope:** Full application review, with particular attention to the font-substitution
  + spacing-projection changes (≈564 lines across `DocxDocumentModel.swift` and
  `DocxEditorProjection.swift`).
- **Note:** This file is a reconstruction from the session handoff summary and
  code cross-references verified on 2026-09-08. Line numbers refer to the tree at
  that date. The minor "low severity" tail items from the original review were not
  preserved in the handoff and are not reproduced here; everything tracked as an
  actionable follow-up (H1, H2, M1–M5) is below.

## Findings summary

| ID   | Severity | Area                                   | Status |
|------|----------|----------------------------------------|--------|
| H1   | High     | Edit rejection invisible; unsafe set too broad | **Fixed** in PR #1 (`bionic/surface-unsafe-edit-rejections`, `06ee2b8`) |
| H2   | High     | OOXML schema element ordering on write | Open |
| M1   | Medium   | Per-keystroke O(n²) reconciliation cost | Open |
| M2   | Medium   | Test harness fragility                  | Open |
| M3   | Medium   | `w:eastAsia` (and theme font) attributes dropped on save | Open |
| M4   | Medium   | Numbered lists silently fall back to bullet marker | Open |
| M5   | Medium   | `try!` in untitled-document init; generic open-error message | Open |

---

## H1 — Edit rejection is invisible to the user, and the "unsafe paragraph" set is too broad (FIXED)

Two related problems:

1. **Invisibility.** When `DocxDocumentSession.acceptEditorText`
   (`FreeDocx/DocxCore/DocxDocumentSession.swift:54`) rejects an edit, it sets
   `pendingError` and reverts `attributedText`. Nothing in the UI ever surfaced
   this state — the user's edit silently reverted, ⌘S started failing with an
   opaque write error, and there was no way to know why.
2. **Over-broad rejection.** `DocxDocumentModel.hasOnlySimpleRuns`
   (`FreeDocx/DocxCore/DocxDocumentModel.swift:589`) treated any paragraph
   containing elements other than `pPr`/`r` (and `rPr`/`t` inside runs) as
   unsafe. Real Word documents nearly always contain `w:proofErr` spell-check
   markers and `w:lastRenderedPageBreak` / `w:lastRenderedLineBreak` runs, so
   editing virtually every real document was rejected.

**Fix (PR #1):** harmless artifacts (`proofErr`, `lastRenderedPageBreak`,
`lastRenderedLineBreak`) are now tolerated in `hasOnlySimpleRuns`;
`FreeDocxDocument` publishes `pendingEditMessage`; `ContentView` shows a
non-dismissable orange banner while an edit is pending rejection, which clears
on the next accepted edit (e.g. undo). Hyperlinks, bookmarks, and fields are
intentionally still rejected — unsupported edits must fail safely.

---

## H2 — Written OOXML can violate schema element ordering

CT_PPr and CT_RPr are **ordered sequences** in the Word schema. The write paths
append new property elements to the **end** of the existing container instead of
inserting them at the schema-correct position:

- `setAlignment` appends `w:jc` to the end of `w:pPr`
  (`FreeDocx/DocxCore/DocxDocumentModel.swift:342`).
- `setBulletedList` appends `w:numPr` to the end of `w:pPr`
  (`FreeDocx/DocxCore/DocxDocumentModel.swift:382` and `:391`).
- `applyRunProperties` appends `w:rFonts`, `w:sz`, `w:szCs`, `w:b`, `w:i`,
  `w:u`, `w:color` to the end of the copied template `w:rPr`
  (`FreeDocx/DocxCore/DocxDocumentModel.swift:656–740`).

In real Word documents, `pPr` commonly ends with the paragraph-mark `w:rPr`
(and sometimes `w:outlineLvl`), and `rPr` commonly ends with `w:lang`,
`w:highlight`, `w:spacing`, etc. Appending after those places `w:jc` after
`outlineLvl`/`rPr`, `w:numPr` after `spacing`/`ind`, or `w:b`/`w:sz` after
`w:lang` — schema violations that make Word prompt to repair the file or flag
unreadable content on open. The regression fixtures don't exercise this because
their `pPr`/`rPr` are minimal and already end at the right place.

**Suggested fix:** a small ordered-insertion helper that inserts each property
element at its CT_PPr/CT_RPr sequence position (removing-then-reinserting any
existing instance of the same element), used by all three write paths.

---

## M1 — Per-keystroke cost is O(document), so editing is O(n²)

Every keystroke goes through `acceptEditorText`
(`FreeDocx/DocxCore/DocxDocumentSession.swift:54`), which:

- calls `model.transactionalCopy()`
  (`FreeDocx/DocxCore/DocxDocumentModel.swift:100`) — a full
  `xmlData()` serialization **and** a full re-parse of `document.xml` on every
  edit;
- runs `DocxEditorProjection.reconcile`
  (`FreeDocx/DocxCore/DocxEditorProjection.swift:36`), which re-slices the
  entire editor text with per-paragraph paragraph-style work;
- may re-run `model.presentations()` (XPath per paragraph) during the pass.

The transactional copy is the right safety design, but doing it per keystroke
with a full serialize+parse round trip will degrade on large documents.
Candidates: debounce reconciliation at paragraph-commit granularity, or make
`transactionalCopy` copy the already-parsed XML node tree (retaining the
copy-on-write safety) instead of serializing to bytes and re-parsing.

---

## M2 — Test harness is fragile

`Scripts/test-docx-core.sh` compiles the five `DocxCore` sources plus
`Tests/DocxCoreRegression.swift` directly with `swiftc` against
`$products/ZIPFoundation.o` from DerivedData. Issues:

- It depends on SPM build artifacts in a fixed DerivedData path; a clean build,
  SPM version bump, or layout change silently breaks the harness.
- It is not an XCTest target, so it is invisible to `xcodebuild test` and CI
  test reporting.
- The "byte-identical no-op save" check is brittle against benign serializer
  changes (attribute order, ZIP entry metadata).
- `makePlainFixture` (`Tests/DocxCoreRegression.swift:523`) derives its rels by
  exact-whitespace `replacingOccurrences` on the shared fixture strings — a
  one-space edit to `contentTypes` or `documentRelationships` breaks it with a
  confusing downstream failure.

---

## M3 — `w:eastAsia` and theme font attributes are dropped on save

`applyRunProperties` writes only `w:ascii`, `w:hAnsi`, and `w:cs` into the new
`w:rFonts` (`FreeDocx/DocxCore/DocxDocumentModel.swift:675–678`). Consequences:

- `w:eastAsia` is lost, so CJK text in an edited run reverts to the default
  East Asian font after save.
- `w:asciiTheme` / `w:hAnsiTheme` (theme font references) are replaced by the
  resolved family name, de-linking the run from the document theme; later theme
  changes in Word no longer affect those runs.

---

## M4 — Numbered lists silently fall back to a bullet marker

`DocxNumberingResolver` (`FreeDocx/DocxCore/DocxDocumentModel.swift:1421`)
defaults a missing `w:numFmt` to `"bullet"` and a missing `w:lvlText` to `"•"`.
A numbered list whose `lvlText` is absent or unparseable therefore renders as
`•` bullets with no warning, and — because the marker is only a projection —
the user has no way to notice the list is not actually numbered as authored.

---

## M5 — `try!` in untitled-document init; generic open-error message

- `FreeDocx/FreeDocxDocument.swift:43` — the untitled `init()` uses
  `try! DocxDocumentSession()`. A failure creating the blank document crashes
  the app on launch / File ▸ New. It should be `init?(...)` or surface an
  error the document framework can present.
- `FreeDocx/FreeDocxDocument.swift:62–80` — `init(fileData:)` collapses every
  parse failure into `CocoaError.fileReadCorruptFile` with
  "FreeDocx couldn't read this Word document." The underlying cause (missing
  package part, invalid XML, projection mismatch) is only in the localized
  underlying error, which the standard alert may not show. Opening a real
  broken file gives the user no actionable detail.
