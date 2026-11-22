# FreeDocx SEO plan

**90-day goal** · Turn searches about editing Word files on a Mac into FreeDocx download clicks. The research covers public pages and U.S. English search demand, checked November 21, 2026. Current traffic and Google index coverage still need first-party data.

## 1. Give search visitors a working next step · Week 1

**Fix the download path first.** The live download button is a placeholder. GitHub lists zero public releases. Use **View source and build instructions** until an installer is available. At release, link directly to the installer and show the version and minimum macOS beside it. The project targets macOS 26.5. Confirm the shipping build’s requirement and verify that a signed-out visitor can download it. [Live homepage](https://freedocx.thirdeyeds.com/) · [Public releases](https://github.com/SiavashB/FreeDocx/releases) · [Build instructions](https://github.com/SiavashB/FreeDocx#run-locally) · [Project settings](../FreeDocx.xcodeproj/project.pbxproj)

**Redirect HTTP to HTTPS.** Both addresses served the homepage with status `200`. The page already names HTTPS as its preferred address. Set a permanent `301` or `308` redirect on the FreeDocx subdomain, preserving the path and query. Verify one redirect followed by an HTTPS `200`. [HTTP homepage](http://freedocx.thirdeyeds.com/) · [Google’s redirect guidance](https://developers.google.com/search/docs/crawling-indexing/301-redirects)

**Set up Google Search Console.** Verify site ownership, inspect the homepage, and record its index status and Google-selected address. Export the available query and page history. The live `robots.txt` contained comments only. The sitemap returned `404`. With the first guide, publish a sitemap listing both pages, reference it in `robots.txt`, and confirm Search Console can read it. [Robots file](https://freedocx.thirdeyeds.com/robots.txt) · [Sitemap endpoint](https://freedocx.thirdeyeds.com/sitemap.xml) · [Search Console setup](https://developers.google.com/search/docs/monitor-debug/search-console-start) · [Sitemap guidance](https://developers.google.com/search/docs/crawling-indexing/sitemaps/overview)

## 2. Publish for two search intents · Days 8–30

| Search phrase | Est. U.S. searches/month | Where it belongs |
| --- | ---: | --- |
| docx editor for mac | 40 | Homepage. The visitor is choosing an app. |
| how to edit a word document on mac | 110 | First guide. Lead with the editing steps. |
| how to open docx on mac | 90 | Same guide. Answer the opening question in the first step. |
| edit docx on mac | 20 | Same guide. Show the save-and-reopen result. |
| free word processor for mac | 480 | Defer. This broader search includes people choosing a full writing suite. |

Serpstat estimates average monthly searches over the past year. Similar phrases overlap. The exact phrase “free docx editor for mac” had no estimate. Its search results included WPS and a Mac App Store listing. The “without Microsoft Word” search surfaced a tutorial. The FreeDocx homepage currently links to sections on the same page, leaving room for a dedicated walkthrough. [Serpstat methodology](https://help.serpstat.com/en/articles/14660916-overview-keyword-research) · [WPS](https://www.wps.com/feature/the-free-docx-editor-for-word-files/) · [App Store listing](https://apps.apple.com/us/app/docx-editor-word-processor/id588286789?mt=12) · [Tutorial result](https://mobisystems.com/en-us/blog/tutorials/how-to-edit-a-document-without-word)

**Homepage · `/`**. The title and main heading describe a free DOCX editor for Mac. Lead with saving edits directly to the same Word file, whether the user needs to send it back or share it with an AI assistant that can access local files. Link to the guide with the text **How to edit a Word document on Mac**. [Homepage and FAQ](https://freedocx.thirdeyeds.com/#faq)

**First guide · `/guides/edit-word-document-on-mac/`**. Use the title **How to edit a Word document on Mac without Microsoft Word**. Open a fictional résumé, change one bullet, save back to the same `.docx`, and reopen it. Explain which steps work offline. Show that Pages opens a Word file as a Pages document and exports the edits to a separate Word copy. Link to the FreeDocx download and its macOS requirement. [FreeDocx features](https://github.com/SiavashB/FreeDocx#current-feature-set) · [Apple’s Word export instructions](https://support.apple.com/en-us/105050)

**Publishing check.** Give the guide its own title, description, and canonical URL. Link to the existing FAQ for compatibility. FreeDocx edits text, basic formatting, and simple lists. Tracked changes and complex tables need another editor. Legacy `.doc` files require conversion first. Verify that readers can follow ordinary links from homepage to guide to download. [FreeDocx editing scope](https://github.com/SiavashB/FreeDocx#scope) · [Google’s link guidance](https://developers.google.com/search/docs/crawling-indexing/links-crawlable)

## 3. Put FreeDocx where Mac users already look · Days 15–60

| Placement | Action | Success check |
| --- | --- | --- |
| GitHub | Fill the empty website field with the homepage URL. Link the guide near the top of the README. | Both links work for a signed-out reader. [Repository metadata](https://api.github.com/repos/SiavashB/FreeDocx) |
| Studio portfolio | Add FreeDocx beside nano.md in the Apps section, with a link and one example of a quick Word edit. | The portfolio links directly to FreeDocx. [Studio portfolio](https://thirdeyeds.com/portfolio#apps) |
| Independent sites | After release, submit FreeDocx to AlternativeTo as an offline, open-source Mac editor. Offer a Mac software reviewer the sample résumé workflow. | Track published mentions and visits from each site. [AlternativeTo submission guidance](https://alternativeto.net/faq/) |

## 4. Measure downloads and choose the next page · Through day 90

- **Downloads.** From release day, measure the share of organic search visits with at least one installer click. Record a `download_click` with the original landing page and traffic source. Verify one test event. Count source-code clicks separately and use release asset counts to check overall delivery.
- **Search visibility.** Weekly, check index status for each page. Track impressions, clicks, and click-through rate by query and landing page. Review branded and nonbranded searches separately. [Google’s performance metrics](https://support.google.com/webmasters/answer/7042828?hl=en)
- **Days 60 and 90.** Compare consecutive 28-day periods using counts and rates. If a page stays unindexed, inspect crawling and canonical selection. If impressions grow but clicks lag at similar positions, test a clearer title. If guide visits grow but download clicks lag, check the link placement and macOS requirement. Publish a follow-up when repeated searches reveal a distinct task. Extend the observation period if counts are low.
