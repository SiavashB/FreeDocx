# FreeDocx SEO plan

**90-day goal** · Turn searches about editing Word files on a Mac into FreeDocx download clicks. The research covers public pages and U.S. English search demand, checked November 21, 2026. Current traffic and Google index coverage still need first-party data.

## 1. Give search visitors a working next step · Week 1

**Getting the app.** The homepage now links to **View source and build instructions**. The project targets macOS 26.5. When an installer ships, link directly to it, show the version and minimum macOS, and verify that a signed-out visitor can download it. [Live homepage](https://freedocx.thirdeyeds.com/) · [Public releases](https://github.com/SiavashB/FreeDocx/releases) · [Build instructions](https://github.com/SiavashB/FreeDocx#run-locally) · [Project settings](../FreeDocx.xcodeproj/project.pbxproj)

**HTTPS.** The FreeDocx subdomain sends a permanent `301` redirect from HTTP to HTTPS, preserving the path and query. Both pages name their HTTPS address as canonical. [HTTP homepage](http://freedocx.thirdeyeds.com/) · [Google’s redirect guidance](https://developers.google.com/search/docs/crawling-indexing/301-redirects)

**Google Search Console.** The live sitemap lists the homepage and guide, and `robots.txt` links to it. Verify site ownership, submit the sitemap, and inspect both URLs for index status and Google's selected canonical. Export the available query and page history. [Robots file](https://freedocx.thirdeyeds.com/robots.txt) · [Sitemap](https://freedocx.thirdeyeds.com/sitemap.xml) · [Search Console setup](https://developers.google.com/search/docs/monitor-debug/search-console-start)

## 2. Publish for two search intents · Days 8–30

| Search phrase | Est. U.S. searches/month | Where it belongs |
| --- | ---: | --- |
| docx editor for mac | 40 | Homepage. The visitor is choosing an app. |
| how to edit a word document on mac | 110 | First guide. Lead with the editing steps. |
| how to open docx on mac | 90 | Same guide. Answer the opening question in the first step. |
| edit docx on mac | 20 | Same guide. Show the save-and-reopen result. |
| free word processor for mac | 480 | Defer. This broader search includes people choosing a full writing suite. |

Serpstat estimates average monthly searches over the past year. Similar phrases overlap. The exact phrase “free docx editor for mac” had no estimate. Its search results included WPS and a Mac App Store listing. The “without Microsoft Word” search surfaced a tutorial. [Serpstat methodology](https://help.serpstat.com/en/articles/14660916-overview-keyword-research) · [WPS](https://www.wps.com/feature/the-free-docx-editor-for-word-files/) · [App Store listing](https://apps.apple.com/us/app/docx-editor-word-processor/id588286789?mt=12) · [Tutorial result](https://mobisystems.com/en-us/blog/tutorials/how-to-edit-a-document-without-word)

**Homepage · `/`**. The title and main heading describe a free DOCX editor for Mac. Lead with saving edits directly to the same Word file, whether the user needs to send it back or share it with an AI assistant that can access local files. Link to the guide with the text **How to edit a Word document on Mac**. [Homepage and FAQ](https://freedocx.thirdeyeds.com/#faq)

**First guide · `/guides/edit-word-document-on-mac/`**. The walkthrough covers opening a fictional résumé, changing one bullet, saving back to the same `.docx`, and reopening it. It also explains how to export a Word copy from Pages. Readers can follow the source and build instructions while FreeDocx is distributed as source. [Published guide](https://freedocx.thirdeyeds.com/guides/edit-word-document-on-mac/) · [Apple’s Word export instructions](https://support.apple.com/en-us/105050)

**Publishing check.** Give each guide its own title, description, and canonical URL. Link to the existing FAQ for compatibility. FreeDocx edits text, basic formatting, and simple lists. Tracked changes and complex tables need another editor. Legacy `.doc` files require conversion first. Verify the links from the homepage to the guide and from the guide to the current way to get the app. [FreeDocx editing scope](https://github.com/SiavashB/FreeDocx#scope) · [Google’s link guidance](https://developers.google.com/search/docs/crawling-indexing/links-crawlable)

## 3. Put FreeDocx where Mac users already look · Days 15–60

| Placement | Action | Success check |
| --- | --- | --- |
| GitHub | The repository website field points to the homepage, and the README links to the guide. | Both links work for a signed-out reader. [FreeDocx on GitHub](https://github.com/SiavashB/FreeDocx) |
| Studio portfolio | FreeDocx appears beside nano.md in Apps. The entry describes updating a résumé bullet and saving the Word file. | The portfolio links directly to FreeDocx. [Studio portfolio](https://thirdeyeds.com/portfolio#apps) |
| Independent sites | After release, submit FreeDocx to AlternativeTo as an offline, open-source Mac editor. Offer a Mac software reviewer the sample résumé workflow. | Track published mentions and visits from each site. [AlternativeTo submission guidance](https://alternativeto.net/faq/) |

## 4. Measure downloads and choose the next page · Through day 90

- **Downloads.** From release day, measure the share of organic search visits with at least one installer click. Record a `download_click` with the original landing page and traffic source. Verify one test event. Count source-code clicks separately and use release asset counts to check overall delivery.
- **Search visibility.** Weekly, check index status for each page. Track impressions, clicks, and click-through rate by query and landing page. Review branded and nonbranded searches separately. [Google’s performance metrics](https://support.google.com/webmasters/answer/7042828?hl=en)
- **Days 60 and 90.** Compare consecutive 28-day periods using counts and rates. If a page stays unindexed, inspect crawling and canonical selection. If impressions grow but clicks lag at similar positions, test a clearer title. If guide visits grow but download clicks lag, check the link placement and macOS requirement. Publish a follow-up when repeated searches reveal a distinct task. Extend the observation period if counts are low.
