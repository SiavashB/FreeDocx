# FreeDocx website

A responsive, dependency-free landing page based on the approved November 18, 2026 mockup. The AI workflow diagram places one DOCX file between the person editing it and their AI assistant, represented by the ChatGPT and Claude icons. All illustration assets are local SVG or HTML/CSS. The résumé is invented sample content.

The ChatGPT and Claude marks belong to OpenAI and Anthropic, respectively. The SVG artwork comes from [Lobe Icons](https://github.com/lobehub/lobe-icons) and includes its [MIT license](public/assets/assistant-icons-license.txt).

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

Serve the page from the project root with Python.

```sh
python3 -m http.server 4173 --bind 127.0.0.1 --directory website/public
```

Open `http://127.0.0.1:4173` to review the design.

## Cloudflare hosting

The Cloudflare deployment uses the files in `website/public/`. The Worker name and custom domain are in [cloudflare.config.ts](cloudflare.config.ts). The deployment scripts place Cloudflare’s generated files in the project’s `Temp/freedocx-cloudflare/build/` folder.

Use a supported Node.js version listed in [package.json](package.json), such as Node 24.22.0. To install the publishing tool and check the release locally, run these commands from the project root.

```sh
cd website
npm ci
npm run deploy:check
```

For the public release, sign in to the Cloudflare account that manages `thirdeyeds.com` with `npx cf auth login` if needed. From `website/`, run `npm run deploy`. That command publishes the files to `freedocx.thirdeyeds.com`. Cloudflare creates the DNS record and provisions HTTPS for the custom domain. [Cloudflare custom domains](https://developers.cloudflare.com/workers/configuration/routing/custom-domains/)

## Private design preview

The [private Sites preview](https://freedocx-mac.open-loach-4340.chatgpt.site) retains its existing identity in `.openai/hosting.json`. To update that preview, copy the contents of `public/` into the Sites publication checkout’s `dist/` and use the Sites publishing workflow. Its staging files live in the ignored project-root `Temp/freedocx-site/` folder.
