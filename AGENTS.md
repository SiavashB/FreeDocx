# FreeDocx working agreements

## Product positioning

- Lead with saving edits directly to the same `.docx` on a Mac. The user can send the Word file back or take turns editing it with an AI assistant that has local file access.
- Describe the Pages workflow accurately. Pages opens a Word file as a Pages document, and an edited `.docx` is a separate export. [Apple’s conversion guide](https://support.apple.com/en-us/105050)

## User files and manual testing

- Never open, edit, save, or use the user's personal `.docx` files for development or verification.
- Use generated fixtures or disposable test documents for development checks.
- Store all generated sample and test documents in the project-root `Test Documents` folder. Keep build output, caches, and logs in `Temp`.
- Do not launch or control the FreeDocx GUI, use System Events, or take application screenshots. The user is the manual test agent.
- When a change needs visual or interactive verification, ask the user to test it and provide the result or a screenshot.

## Document integrity

- Preserve the OOXML-first architecture described in `README.md`. The Word package and document model remain the source of truth for saves.
- Preserve untouched DOCX package parts and native Word structures, including styles, numbering, settings, relationships, fonts, media, and metadata.
- Keep bullets and numbering as real OOXML lists. Do not replace them with literal bullet characters.
- Never fall back to a lossy whole-document export for imported documents.
- Unsupported edits must fail safely without corrupting or partially overwriting the source document.

## Architecture boundaries

- Keep DOCX parsing, editing, and serialization inside `DocxCore`. UI code must not manipulate OOXML directly.
- Maintain the separation of responsibilities between `DocxPackage`, `DocxDocumentModel`, `DocxEditorProjection`, and `DocxDocumentSession`.
- Treat AppKit and TextKit as the editing projection, never as the save source for imported documents.
- Reconcile edits through stable paragraph identities. Do not match paragraphs by their text or current display position.
- Apply document updates transactionally: validate that an edit is representable before replacing the current model.
- Extend the document model when adding format support instead of introducing document-format workarounds in the UI.
- Preserve unsupported content when it is untouched, and reject edits that cannot be represented safely.

## Development workflow

- Do not add, remove, or modify tests unless the user explicitly asks.
- Existing non-UI checks may be run when appropriate, using only generated or disposable fixtures.
