# FreeDocx

FreeDocx is a small, native macOS viewer and editor for `.docx` files. AppKit/TextKit provides the editing surface, while an OOXML-first document core owns the Word package and is the only save source.

## Current feature set

- Open existing `.docx` files and create new ones
- Edit rich text with native undo, find, spelling, font, and color support
- Apply bold, italic, underline, and paragraph alignment
- Add or remove real Word bullets from one or multiple selected paragraphs
- Render fixed-size pages using each document's paper size and margins
- Flow text across visible page gaps without changing wrapping as the window resizes
- Zoom from 50% to 200% without reflowing the document
- Save edits back to `.docx`
- Preserve all untouched parts of an imported Word package
- Keep lists as real Word numbering and formatting as native OOXML properties
- Show live word and character counts
- Quit when the last document window closes

## Document architecture

- `DocxPackage` retains every ZIP entry and returns the exact original bytes for a no-op save.
- `DocxDocumentModel` owns `word/document.xml`, stable paragraph identities, numbering, style inheritance, and page geometry.
- `DocxEditorProjection` maps the OOXML model to TextKit and reconciles edits by stable identity rather than matching paragraph text.
- `DocxDocumentSession` applies edits transactionally. An unsupported edit fails without mutating the last valid Word model.
- An edited save replaces only `word/document.xml`; parts such as styles, numbering, settings, relationships, themes, fonts, media, and metadata remain byte-for-byte unchanged.

ZIPFoundation is used for in-memory package preservation. AppKit's Office Open XML importer is used only to seed the visual projection; its exporter is not used to save imported documents.

## Run locally

Open `FreeDocx.xcodeproj` in Xcode, select the **FreeDocx** scheme and **My Mac**, then run with **⌘R**. Use **File → Open** for an existing Word document or **File → New** for a blank document.

For a command-line build:

```sh
xcodebuild -project FreeDocx.xcodeproj \
  -scheme FreeDocx \
  -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData \
  build
```

Run the generated-fixture package regression with:

```sh
sh Scripts/test-docx-core.sh
```

## Scope

This is intentionally a basic rich-text editor. It currently projects the final section's page geometry and supports safe editing of ordinary paragraphs and lists. Paragraphs containing fields, drawings, embedded objects, footnote/endnote references, or other complex inline structures are preserved when untouched and rejected if an edit cannot be represented safely. Per-section layouts, tracked changes, headers and footers, advanced tables, and manual page/section-break editing are not yet exposed in the editor.
