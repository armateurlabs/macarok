# Wikipedia context

Open **Playing → Wikipedia** to read about the inspected or playing track's artist or album. The centered **Artist / Album** selector chooses the metadata used for the search. Its selection stays unchanged as tracks advance. The search field is editable, and **Search** submits a manual query.

The pane follows the same track as the central context. A presented artwork or metadata sheet keeps its original target pinned until closed. Metadata drafts retained after leaving their Playing editor do not pin Wikipedia; returning to that editor restores its original draft. The same artist or album query reuses the loaded page while the pane remains visible.

Search uses English Wikipedia's [MediaWiki Go behavior](https://www.mediawiki.org/wiki/Help:Go_button): an exact article when available, otherwise search results. Search requests ask for the compact [Minerva skin](https://www.mediawiki.org/wiki/Beta_Features/Minerva); the final page layout and appearance remain controlled by Wikipedia. **Open in Browser** opens the current page with the website's full controls. Page links to other sites open the browser when clicked.

## Requests and storage

Wikipedia loads only while its pane is visible. Changing the target cancels the previous navigation, and obsolete callbacks cannot replace the new page. Leaving the pane stops its navigation. Loading, missing-metadata, and network-error states remain centered; errors offer **Try Again**.

Artist or album search terms are sent to English Wikipedia. Macarok does not send source credentials or file paths. WebKit uses a nonpersistent website data store with content JavaScript disabled; no Wikipedia article cache is added to the library database. The page controls and article appearance are supplied by Wikipedia.

## Content licenses

The pane displays unmodified official pages, including their attribution and licensing footer, and links to the current page through Open in Browser. Wikipedia text and media retain their own licenses; Macarok's MIT license covers its source code. No Wikipedia articles, media, or logos are bundled with Macarok.

See [Wikipedia's copyright and reuse information](https://en.wikipedia.org/wiki/Wikipedia:Copyrights#Reusers%27_rights_and_obligations) and [Wikimedia's licensing terms](https://foundation.wikimedia.org/wiki/Policy:Terms_of_Use#7._Licensing_of_Content). Media licenses are identified on their individual description pages.
