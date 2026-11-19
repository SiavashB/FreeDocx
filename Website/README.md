# FreeDocx website

A responsive, dependency-free landing page based on the approved November 18, 2026 mockup. The AI workflow pairs a DOCX file badge with the ChatGPT and Claude icons. All illustration assets are local SVG or HTML/CSS. The résumé is invented sample content.

The ChatGPT and Claude marks belong to OpenAI and Anthropic, respectively. The SVG artwork comes from [Lobe Icons](https://github.com/lobehub/lobe-icons) and includes its [MIT license](assets/assistant-icons-license.txt).

## Version history

The original site is saved in the main project repository at tag `website-before-mockup-2026-11-18`, commit `10a6121`. View the original website files with:

```sh
git show website-before-mockup-2026-11-18:Website/index.html
git show website-before-mockup-2026-11-18:Website/styles.css
```

The current design is committed separately. The Sites publication repository also retains its previous published versions.

## Design scope

The download button is intentionally an unconnected `type="button"` placeholder. Connect it to an installer only when requested. Navigation and FAQ disclosures use native HTML; the page has no JavaScript, external fonts, analytics, or upload functionality.

The primary audience needs occasional, simple edits to .docx files without paying for Microsoft Word. The supporting AI workflow describes taking turns on a saved local file with an assistant that can access it. It does not imply a built-in AI connection or live collaboration. The FAQ explains saving and closing between turns.

Visual verification remains with the user. No browser screenshots or FreeDocx GUI checks are performed during implementation.

## Local preview

No build is needed. From the project root:

```sh
python3 -m http.server 4173 --bind 127.0.0.1 --directory Website
```

Open `http://127.0.0.1:4173` to review the design.

## Hosting

Private site: https://freedocx-mac.open-loach-4340.chatgpt.site

`Website/.openai/hosting.json` retains the existing Sites identity. The publication checkout, staging, caches, and archive live under the ignored project-root `Temp/freedocx-site/` folder. Copy `index.html`, `styles.css`, and `assets/` into that checkout’s `dist/`, and retain its `.openai/hosting.json`. Publish through the Sites source helper using the exact pushed source and packaged archive.
