# FreeDocx website

A responsive, dependency-free site based on the approved November 18, 2026 mockup. The AI workflow diagram shows the user chatting with an assistant, represented by the ChatGPT and Claude icons, above the DOCX file they both edit. All illustration assets are local SVG or HTML/CSS. The résumé is invented sample content.

The ChatGPT and Claude marks belong to OpenAI and Anthropic, respectively. The SVG artwork comes from [Lobe Icons](https://github.com/lobehub/lobe-icons) and includes its [MIT license](public/assets/assistant-icons-license.txt).

## Version history

The original site is saved in the main project repository at tag `website-before-mockup-2026-11-18`, commit `10a6121`. View the original website files with:

```sh
git show website-before-mockup-2026-11-18:Website/index.html
git show website-before-mockup-2026-11-18:Website/styles.css
```

The current design is committed separately. The Sites publication repository also retains its previous published versions.

## Design scope

The homepage links to the public source and build instructions while FreeDocx is available as source. The [Word editing guide](public/guides/edit-word-document-on-mac/index.html) explains the FreeDocx workflow and how to export a Word file from Apple Pages. The site uses native HTML navigation and FAQ disclosures.

The homepage leads with saving quick edits directly to the same `.docx` file. The guide explains how Pages opens a Word file as a Pages document and exports an edited Word copy. The AI workflow and FAQ describe taking turns with an assistant that can access the saved local file. Save and close the file between turns.

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

The FreeDocx HTTP redirect is a Cloudflare Single Redirect scoped to `freedocx.thirdeyeds.com`. It preserves the path and query string. Both public pages are listed in `sitemap.xml`, which `robots.txt` references. [Live sitemap](https://freedocx.thirdeyeds.com/sitemap.xml)

## Private design preview

The [private Sites preview](https://freedocx-mac.open-loach-4340.chatgpt.site) retains its existing identity in `.openai/hosting.json`. To update that preview, copy the contents of `public/` into the Sites publication checkout’s `dist/` and use the Sites publishing workflow. Its staging files live in the ignored project-root `Temp/freedocx-site/` folder.
