# FreeDocx website

A responsive, dependency-free landing page. The source lives here in the main FreeDocx checkout; no build is needed for local use. The page uses the existing app icon and a clearly labeled HTML illustration, not an app screenshot.

Serve this directory with any static web server. For example, from the project root:

```sh
python3 -m http.server 4173 --bind 127.0.0.1 --directory Website
```

Open `http://127.0.0.1:4173` to review the design. No browser or FreeDocx GUI verification has been performed.

## Design scope

This is a design prototype. The “Download for Mac” buttons show the intended call to action and are deliberately unconnected. Installer availability is outside the current design scope. The stated macOS requirement comes from the current project target.

The primary audience needs occasional, simple edits to Word documents and does not want to pay for Microsoft Word. The supporting AI story is about taking turns on the same saved local file with an assistant that can access it. It does not claim a built-in ChatGPT connection, live collaboration, or limitations of Google Docs. The sample résumé is invented for the design.

The earlier design review’s four items have been addressed in this design revision: 1 (positioning), 2 (a concrete editing example), 3 (repetitive copy), and 4 (small reading text). The app view remains a labeled illustration using an invented résumé. Visual review remains with the user.

## Hosting

Private design preview: https://freedocx-mac.open-loach-4340.chatgpt.site

`.openai/hosting.json` retains the private Sites preview identity. Publication staging and archives belong under the project’s ignored `Temp/freedocx-site/` directory. Copy `index.html`, `styles.css`, and `assets/` into the staging directory’s `dist/`; copy the manifest into its `.openai/`. Only the website is included in that publication.

The page has no JavaScript dependencies, external fonts, analytics, or document upload functionality. Navigation uses ordinary links and the FAQ uses native HTML disclosure controls.
