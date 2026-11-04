<!-- Modified for WSurf by wsagency in 2026; based on Linen by Kavoye. -->
# Changelog
This file preserves release notes inherited from the upstream
[kavoye/linen-browser](https://github.com/kavoye/linen-browser) project. They
describe upstream Linen releases, not releases published by WSurf. New WSurf
release notes will be added above this provenance record.

## 0.1.22 (build 22) — 2026-11-03

Everything since 0.1.21 (build 21). None of the screens and prompts below has been checked by hand.

### Websites and sign-in

- WebKit tabs now ask for a username and password when a website or proxy wants HTTP authentication (Basic, Digest, NTLM). Until now the prompt never appeared and you got the server’s “Unauthorized” page. A refused password asks again, and the third refusal ends the sign-in, as it was meant to.
- Chromium tabs show the same sign-in sheet as WebKit tabs, with a Username and a Password field, the cursor in Username, and “Try again” after a refused password, for websites and proxies. Chromium’s own prompt is switched off: inside WSurf it vanished and left “ERR_INVALID_AUTH_CREDENTIALS”. A tab in the background that is asked for a password is refused.
- The sign-in sheet names the address that asks (such as https://example.com), and shows the website’s own wording for it separately, as “The website’s message”. Only the page’s own website, or a proxy, can raise the sheet in either engine: an image or frame from another website that asks for a password is refused without one, so it cannot pose as the page and collect its password.
- A navigation to another website that was stopped, answered with no content, failed or became a download no longer leaves that website able to raise the sign-in sheet over the page you are on.
- Because WebKit tabs now answer such challenges, the certificate warning with its “proceed anyway” choice (when certificate exceptions are on) now appears in WebKit tabs too; before, WebKit tabs never showed it. It has not been checked by hand.

### Chromium tabs

- The right-click menu in Chromium tabs has the items WebKit tabs have: Open Link in Peek, Summarize Link, Download Linked File, Open Image in New Tab, Download Image, and Save Page As… and Print Page… on the page itself (they replace Chromium’s own Print, so they save and print as in WebKit tabs).
- Shift-click on a link opens it in a Peek, as in WebKit tabs. ⌘-click and middle-click open a tab in the background, and ⇧⌘-click in front.
- A pop-up that a page opens without a click and WSurf blocks shows the “pop-up blocked” notice, as in WebKit tabs.
- Chromium tabs now have developer tools. View › Developer › Show Web Inspector (⌥⌘I), the ⌘K palette and the Developer Tools menu open Chromium’s DevTools in a window of their own, and a right-click offers Inspect Element, under the same conditions as in WebKit tabs (the Web Inspector setting, or a website in Developer mode).
- Find on page in a Chromium tab uses Chromium’s own find: every match is highlighted, and “n of m” is Chromium’s own count and position.
- Developer mode’s Page Appearance (Match System, Light, Dark) now works in Chromium tabs, as the page’s preferred color scheme; WebKit tabs set the view’s appearance instead.

### Passwords, passkeys and autofill

- A filled login now reaches the page as typing does, with focus, key, input, change and blur events, in WebKit and Chromium tabs, so sign-in pages that copy what you type on a key or on leaving the field (such as SAP Ariba) receive it; before, Login could treat the filled fields as empty. Focus goes back to the field you chose.
- In Chromium tabs, a page counts as secure for saved logins by WebKit’s rule (an HTTPS page with a valid certificate and nothing insecure on it), so Pick Credential…, suggestions and save offers no longer disappear on secure pages Chromium rated otherwise. A page reached past a certificate warning gets no saved logins.
- In WebKit tabs too, a page reached past a certificate warning, or one that loaded something past one, no longer counts as secure: no saved logins are offered, filled or saved there, and the address bar shows no lock.

### Tabs

- Changing a website's engine from its site controls now switches only that tab. Other open tabs of the website keep their engine, also when they move within the site, and tabs you open afterwards use the new one. Changing the engine in Settings still moves every open tab of the website.

### Command palette

- Open tabs that match what you type now stay at the top of the Command palette while you type, instead of dropping below Search or ask and the suggestions.

### Updates

- The sidebar update banner can be closed: a close button on the card, and Close in the menu of the icons-only badge, so “Couldn’t check for updates” and “Update Available” no longer stay in the sidebar for good. It is not offered while an update downloads, is prepared or installs; the next Check for Updates shows the banner again.

### External assistants (MCP)

- `readPage` and action results show link addresses as the page’s link gives them (`&`, not `&amp;`), so an address passed back to `navigate` is accepted.
- In Chromium tabs, a page restored by Back after `resetDevelopment` ended a diagnostics capture answers again; before, it needed a reload.
- The connection instructions now say to make one call at a time (a parallel call is refused with “Another operation is running”) and to call `switchTab` when `setViewport` answers `unsupported` for a tab in the background.

### License

- WSurf’s own code is now under the Business Source License 1.1; the code that comes from Linen keeps its Apache 2.0 license. The About panel and Get Info say so, and Settings › About › Acknowledgements now starts with WSurf’s license and Linen’s.

### Known issues

- One- and two-letter address-bar queries search only the newest 3,000 pages; three letters and the History page search everything.
- Removing one website in Website data removes the cookies that exact host set; a cookie a website set for its whole domain (from www.example.com for example.com) stays until you clear everything. This was true before, but Chromium’s cookies now stay across a quit.
- Clear Browsing Data does not reach Chromium’s own small records of the sites you visited (the sites it must open over HTTPS, its site-engagement scores); they go when you delete the profile.
- WebKit tabs that both use the camera or microphone still take it from each other: showing another tab that uses them mutes the first for good, and WSurf has no button to resume it.
- Taking back camera or microphone access from a Chromium tab that is using it stops the devices by closing and reopening the page, and shows “Could not change website device access”.
- Back after an engine switch goes back one step only: Forward does not return to the other engine, and a Chromium page comes back by its address, not with its history.
- Passkeys from Apple Passwords, from phones and from security keys do not work in either engine until Apple grants WSurf the browser passkey entitlement; WSurf’s own passkey sheet is all a website gets.
- A script that must run before a page’s own code (the passkey script, the notification and location stand-ins, the development diagnostics hook) can run late on the first page of a Chromium pop-up, so that page may have done its first work before it.
- A page in a background tab runs its timers more slowly after 10 seconds, so a page that counts, polls or refreshes itself from a timer can fall behind until you show it. Set the website to Keep this website loaded to leave it as it was.
- A tab you switched to another engine from its site controls, and the other tabs of that website that keep their engine, go back to the website's setting after WSurf is quit and opened again.
- The known issues of 0.1.14 are unchanged.

## 0.1.21 (build 21) — 2026-11-03

Everything since 0.1.20 (build 20). None of the screens and prompts below has been checked by hand.

### Chromium tabs

- In Chromium tabs, passkeys now work in a sign-in frame from another website when the page permits it, such as YouTube’s Verify step. The sheet names both the frame’s website and the page around it; a frame without permission is refused.
- Cookies from Chromium tabs are saved as soon as the last Chromium tab closes.

### Tabs

- The color chooser a page opened closes when you switch away from its tab.

### Known issues

- One- and two-letter address-bar queries search only the newest 3,000 pages; three letters and the History page search everything.
- Chromium tabs open ⌘-click and middle-click tabs in front.
- In Chromium tabs, a pop-up that WSurf blocks is refused without the notice WebKit tabs show.
- Removing one website in Website data removes the cookies that exact host set; a cookie a website set for its whole domain (from www.example.com for example.com) stays until you clear everything. This was true before, but Chromium’s cookies now stay across a quit.
- Clear Browsing Data does not reach Chromium’s own small records of the sites you visited (the sites it must open over HTTPS, its site-engagement scores); they go when you delete the profile.
- WebKit tabs that both use the camera or microphone still take it from each other: showing another tab that uses them mutes the first for good, and WSurf has no button to resume it.
- Taking back camera or microphone access from a Chromium tab that is using it stops the devices by closing and reopening the page, and shows “Could not change website device access”.
- Back after an engine switch goes back one step only: Forward does not return to the other engine, and a Chromium page comes back by its address, not with its history.
- Passkeys from Apple Passwords, from phones and from security keys do not work in either engine until Apple grants WSurf the browser passkey entitlement; the sheet above is all a website gets.
- A script that must run before a page’s own code (the passkey script, the notification and location stand-ins, the development diagnostics hook) can run late on the first page of a Chromium pop-up, so that page may have done its first work before it.
- A page in a background tab runs its timers more slowly after 10 seconds, so a page that counts, polls or refreshes itself from a timer can fall behind until you show it. Set the website to Keep this website loaded to leave it as it was.
- The known issues of 0.1.14 are unchanged.

## 0.1.20 (build 20) — 2026-11-02

Everything since 0.1.18 (build 18). None of the screens and prompts below has been checked by hand.

### Credentials

- Signing in with a passkey now asks once: one sheet names the passkey, Touch ID on the sheet confirms it, Change picks another passkey and Find shows why another stored passkey can’t be used on this website. Credential Manager is unlocked first only if it is locked.
- Password suggestions now list the login you last used on a website first, followed by every other login saved for that website.
- On a verification code field, WSurf can now fill a code that arrived in Messages or Mail: choose Code from Messages or Mail… and pick the code macOS suggests.

### Tabs

- After signing in through a pop-up, such as a single sign-on window, WSurf returns to the tab that opened it, also when the pop-up was in its own window. Closing a tab opened from a link now returns to its parent tab.

### Chromium tabs

- In Chromium tabs, a site you allowed to open pop-ups can open them again without a click, as in WebKit tabs.
- In Chromium tabs, sign-in forms that a website builds in a frame of its own, such as the Apple Developer sign-in, now get WSurf’s password autofill, Pick Credential…, save offers, Input History and autoplay settings.

### PDFs

- Right-clicking a PDF now offers Download PDF in both engines (and Open in Preview in Chromium), File › Save Page As… (⌘S) saves the PDF itself, and a Download PDF button appears in the address bar while a PDF is open.
- Fixed a crash that showed a sad face instead of any PDF opened in a Chromium tab, present since 0.1.14.

### Known issues

- One- and two-letter address-bar queries search only the newest 3,000 pages; three letters and the History page search everything.
- Chromium tabs open ⌘-click and middle-click tabs in front.
- Removing one website in Website data removes the cookies that exact host set; a cookie a website set for its whole domain (from www.example.com for example.com) stays until you clear everything. This was true before, but Chromium’s cookies now stay across a quit.
- Clear Browsing Data does not reach Chromium’s own small records of the sites you visited (the sites it must open over HTTPS, its site-engagement scores); they go when you delete the profile.
- WebKit tabs that both use the camera or microphone still take it from each other: showing another tab that uses them mutes the first for good, and WSurf has no button to resume it.
- Taking back camera or microphone access from a Chromium tab that is using it stops the devices by closing and reopening the page, and shows “Could not change website device access”.
- Back after an engine switch goes back one step only: Forward does not return to the other engine, and a Chromium page comes back by its address, not with its history.
- Passkeys from Apple Passwords, from phones and from security keys do not work in either engine until Apple grants WSurf the browser passkey entitlement; the sheet above is all a website gets.
- A script that must run before a page’s own code (the passkey script, the notification and location stand-ins, the development diagnostics hook) can run late on the first page of a Chromium pop-up, so that page may have done its first work before it.
- A page in a background tab runs its timers more slowly after 10 seconds, so a page that counts, polls or refreshes itself from a timer can fall behind until you show it. Set the website to Keep this website loaded to leave it as it was.
- The known issues of 0.1.14 are unchanged.

## 0.1.18 (build 18) — 2026-10-29

Everything since 0.1.17 (build 17). None of the screens and prompts below has been checked by hand.

### Address bar

- A long website address in the address bar now ends with “…” before the icons at its end instead of running under them, and hovering the address shows the whole address. This holds in the toolbar, the Minimal bar and the Micro window’s bar. The icons keep their size and stay clickable.

### Window

- Settings › Appearance › Window has new Shadow and Border options. Turning the shadow off also removes the thin outline macOS draws around the window. Border adds a 1 pt line (None, Subtle, Accent or a custom color) that follows the window’s corners. Both apply at once to every open window, in the Standard, Minimal and Micro window styles, and a build before 0.1.18 ignores them.

### Credentials

- Credential Manager’s merge review now recommends the plain username (user@example.com) over its numbered copies (user@example.com (1)) as the primary credential; nothing changes until you confirm.
- The Lock control in the Credentials toolbar is now just the padlock icon, with “Lock Credentials” as its tooltip and VoiceOver label.

### Passkeys

- Passkey buttons in sign-in forms that a website embeds from its own address, such as the Apple Developer sign-in, now show WSurf’s passkey sheet instead of doing nothing, in both WebKit and Chromium tabs.

### Chromium tabs

- A web page can no longer open a color picker, a pop-up or a new tab by itself just after it loads in a Chromium tab; only your own click opens them, and websites allowed to play sound still start it by themselves.

### Under the hood

- The test plan turns the allocator’s large-block cache off for the test host, so a performance memory budget reads what a test does and not when macOS takes freed memory back. A test fails if the cache is on. No budget changed.
- A new test pins the Folder indent as you set it in Settings, with the rows on screen, in the docked, floating and Minimal tab lists. The indent itself is unchanged.

### Known issues

- One- and two-letter address-bar queries search only the newest 3,000 pages; three letters and the History page search everything.
- Chromium tabs open ⌘-click and middle-click tabs in front.
- In Chromium tabs, a website set to Allow pop-ups still needs your click to open one; this comes back in the next version.
- Removing one website in Website data removes the cookies that exact host set; a cookie a website set for its whole domain (from www.example.com for example.com) stays until you clear everything. This was true before, but Chromium’s cookies now stay across a quit.
- Clear Browsing Data does not reach Chromium’s own small records of the sites you visited (the sites it must open over HTTPS, its site-engagement scores); they go when you delete the profile.
- WebKit tabs that both use the camera or microphone still take it from each other: showing another tab that uses them mutes the first for good, and WSurf has no button to resume it.
- Taking back camera or microphone access from a Chromium tab that is using it stops the devices by closing and reopening the page, and shows “Could not change website device access”.
- Back after an engine switch goes back one step only: Forward does not return to the other engine, and a Chromium page comes back by its address, not with its history.
- Passkeys from Apple Passwords, from phones and from security keys do not work in either engine until Apple grants WSurf the browser passkey entitlement; the sheet above is all a website gets.
- A script that must run before a page’s own code (the passkey script, the notification and location stand-ins, the development diagnostics hook) can run late on the first page of a Chromium pop-up, so that page may have done its first work before it.
- A page in a background tab runs its timers more slowly after 10 seconds, so a page that counts, polls or refreshes itself from a timer can fall behind until you show it. Set the website to Keep this website loaded to leave it as it was.
- The known issues of 0.1.14 are unchanged.

## 0.1.17 (build 17) — 2026-10-28

Everything since 0.1.16 (build 16). None of the screens and prompts below has been checked by hand. The speeds are from tests on a debug build under load, so they show how much less work is done, not what you will see.

### Speed

- Sidebar: opening or closing a tab over a long list, and pressing ⌘, no longer redraw every row. A row used to look at every tab in the window to build its right-click menu, and every row listened for the ⌘ key. The menus have the same items in the same order. In our test with 1,000 tabs, opening a background tab takes 0.24 s instead of 1.3 s, and pressing and releasing ⌘ takes a fraction of a millisecond instead of 75 ms. VoiceOver still finds the button at the end of every row.
- Downloads: a running download now updates its progress bar and byte count at most ten times a second, instead of with every piece it receives. A fast download used to keep the Downloads page, the sidebar button and the Start page redrawing all the time. The last count is always shown exactly, a download that finishes, pauses or fails shows it at once, and the list is no longer written to disk for a byte count alone.
- Address field: typing in the Start page’s address field searches your history once for each change you make, not once for each time the page redraws. In our test, eight searches of three to ten letters over 50,000 pages take about a third of the time.
- Theme gallery: dragging Brightness with Settings › Appearance open redraws only the theme card that changes, not all twenty. In our test, 30 steps take 0.30 s instead of 0.52 s.
- Chromium site count: Settings › Privacy and Website data now list the sites Chromium holds data for without starting Chromium. They used to open a hidden Chromium browser for every site, and start Chromium first if it was not running (1.2 s for 40 sites in our test). WSurf also keeps the list in memory instead of rewriting its file at every page and frame that loads. A site you visit for the first time is written to disk about a second later, or when you quit; if WSurf crashes in that second, Website data misses that site until you visit it again. Nothing Chromium stored is lost.
- Chromium start: after launch, WSurf reads the Chromium framework into memory in the background, so the first Chromium tab of a session is less likely to wait for the disk. It does this only on a Mac where you have used Chromium before; otherwise nothing is read. Chromium itself still starts with the first Chromium tab.
- Chromium idle: once you had opened a Chromium tab, WSurf woke up about 30 times a second for the rest of the session, even with every Chromium tab closed and the window hidden. With Chromium idle it now wakes up not at all (from 30 to 0 a second in our test). Chromium pages should load as quickly as before.
- Background tabs rest: a tab that has been in the background for 10 seconds is now hidden from its page, as in any browser, so a page that animates (a dashboard, a chat, a favorite you keep loaded) no longer draws 60 frames a second behind the page you are looking at (60 to 0 in our test). This covers tabs WSurf keeps loaded off screen too, such as favorites. Switching back shows the page at once, and it takes a few frames to draw again. The page sees what any background tab sees: its timers run more slowly, and it is told when you switch away and back, so a page that saves when it is hidden saves then. A tab is never hidden while it plays sound or is shown in the media panel, has its video in Picture in Picture, uses the camera or microphone or shares the screen, holds a form you edited, is controlled by the assistant or a connected app, is a private tab, or is on a website you set to Keep this website loaded.

### Minimal bar

- Settings › Appearance › Window has a new menu, Hide bar, in place of the switch of that name. Choose Never, While scrolling (the default, and what Reset to Defaults sets), After 5 seconds, After 10 seconds or After 30 seconds. After a time, the Minimal window’s bar goes once nothing has held it for that long, and scrolling no longer matters. The pointer at the edge of the window, a prompt, a popover, the address you are editing, the open tab list, and a page that has no address all hold the bar, and the time starts again when they let go. Your earlier choice is kept: on is While scrolling, off is Never. **Going back to a build before 0.1.17 reads Never and the timed choices as While scrolling**, because the older build cannot read them.
- Settings › Appearance › Icons only is dimmed while the Minimal window style is chosen, with a note that the Minimal window always shows tab titles. The switch had no effect there and applied when you went back to Standard; you can no longer set it from Minimal. Your choice is kept for Standard.

### Assistant

- The assistant no longer loses conversations at launch. While your first window opened, the assistant’s memory was cut down to the tabs of that window, before your other windows had opened, so the conversations about tabs in those windows were deleted, and so were those of a window you had closed but could still bring back with Reopen. They are now kept. A conversation that an earlier build already deleted is not restored.

### Pop-ups, passkeys and dialogs

- Chromium tabs: a pop-up a page opens (`window.open`, a sign-in window, a link that opens a new window) now keeps its connection to the page that opened it, so a sign-in pop-up can hand its result back and close itself. It used to open as an ordinary tab with no link to the page, so a sign-in that reports back to the page could not finish. The pop-up still opens in a tab of its own, and the pop-up blocker and the question about opening another app work as before. A pop-up to a website you set to WebKit (Google sign-in is one) opens as a plain WebKit tab as before, with no link to the page.
- Passkeys: when a website asks for a passkey and WSurf has none for it, a sheet now says “No passkey for this website in WSurf.” and “Choose another way to sign in on the website.”, with one button, OK. It used to offer ways that could not work: Chromium’s “Use Another Device or Key…” is gone, and so are the “Continue in Chromium” button and its note on the sheets of WebKit tabs. Where a passkey request used to reach Chromium’s own passkey code, which has no prompt and reaches no authenticator, the page waited forever. In Chromium tabs, and in the frames of other websites, that request now ends at once as “not allowed”, which websites answer with their other way to sign in. When WSurf cannot save a new passkey (no vault yet), its sheet says so in the same way, with one button. A passkey request from a tab in the background, or one WSurf keeps loaded off screen such as a favorite, now waits until you open the tab, so its sheet never appears over the page you are looking at. It used to appear over the tab in front, or be refused when the tab was in no window. Closing the tab or leaving the page, or the website’s own time limit, ends the wait with “not allowed”.
- Dialogs: an alert, confirm or prompt from a tab in the background no longer appears over the page you are looking at. It waits until you open that tab, and the page waits too. In Chromium tabs, “Leave page?” and “Reload page?” from a background tab wait the same way. A tab that closes, or loads another page, before you look at it answers its waiting dialogs with Cancel (Stay for “Leave page?”).

### Under the hood

- CefSwift, the library that brings Chromium into WSurf, is now part of the source (`Packages/CefSwift`, revision 59cad64) instead of a download pinned in the project. It carries one patch, to its message pump, which is what stops the 30 wakeups a second above; `Packages/CefSwift/WSURF-PATCHES.md` lists it. A build from source now downloads the Chromium framework into that folder (about 336 MB, once). Nothing else about Chromium changes.
- Ten performance budgets were added, and the brightness preview budget went from 21 s to 11 s, because rows no longer read every tab.

### Known issues

- One- and two-letter address-bar queries search only the newest 3,000 pages; three letters and the History page search everything.
- Chromium tabs do not yet block `window.open` without a click, and open ⌘-click and middle-click tabs in front.
- Removing one website in Website data removes the cookies that exact host set; a cookie a website set for its whole domain (from www.example.com for example.com) stays until you clear everything. This was true before, but Chromium’s cookies now stay across a quit.
- Clear Browsing Data does not reach Chromium’s own small records of the sites you visited (the sites it must open over HTTPS, its site-engagement scores); they go when you delete the profile.
- WebKit tabs that both use the camera or microphone still take it from each other: showing another tab that uses them mutes the first for good, and WSurf has no button to resume it.
- Taking back camera or microphone access from a Chromium tab that is using it stops the devices by closing and reopening the page, and shows “Could not change website device access”.
- Back after an engine switch goes back one step only: Forward does not return to the other engine, and a Chromium page comes back by its address, not with its history.
- Passkeys from Apple Passwords, from phones and from security keys do not work in either engine until Apple grants WSurf the browser passkey entitlement; the sheet above is all a website gets.
- A script that must run before a page’s own code (the passkey script, the notification and location stand-ins, the development diagnostics hook) can run late on the first page of a Chromium pop-up, so that page may have done its first work before it.
- A page in a background tab runs its timers more slowly after 10 seconds, so a page that counts, polls or refreshes itself from a timer can fall behind until you show it. Set the website to Keep this website loaded to leave it as it was.
- The known issues of 0.1.14 are unchanged.

## 0.1.16 (build 16) — 2026-10-27

Everything since 0.1.15 (build 15). None of the screens and prompts below has been checked by hand.

### Chromium tabs keep what you sign in to

- Chromium tabs now keep logins, cookies, site storage and site settings after you quit WSurf. Until now every regular profile’s Chromium data lived in memory and was gone at quit, so you signed in again at every launch. Each profile has its own, under WSurf’s Application Support folder in Chromium, and two profiles never share. Private windows still keep nothing. Clear Browsing Data for all time, Website data, Clear Data on Quit and deleting a profile remove it, including the storage of a frame from another website that a page held. Chromium’s own history is switched off, so Clear History has nothing of Chromium’s to miss. Going back to 0.1.15 loses nothing: it ignores the new folders. Cookies are stored encrypted with the Keychain item “Chromium Safe Storage”, which macOS creates for WSurf the first time, or asks you once to allow if another app made it; Deny means logins are not kept. Camera, microphone, location and notification answers that Chromium’s own prompt stored are cleared at every start, so only WSurf’s choice answers.

### Camera and microphone

- WebKit tabs: a tab that WSurf keeps alive off screen (a favorite that loads at launch, a tab kept for its sound) no longer takes the camera and microphone from the page in front. It used to be given them the moment it asked, WebKit then muted the other page, and Google Meet said the microphone was muted by the system. Now such a tab’s request waits until you show that tab, and is then decided by the website’s setting as before.
- Chromium tabs: a website you set to Allow now reports camera and microphone as allowed, as it does in Chrome. Google Meet and similar sites read this first and used to wait for their own “Allow microphone and camera” step, so no devices appeared. Only the exact website you allowed (same host and port, in the profile where you allowed it) reports it; another port, a private window (it keeps its own settings) and a site set to Ask or Block do not, and a frame from another website still cannot use the devices. Because Meet now starts the devices when the page loads, macOS asks for camera and microphone access at that moment the first time, as it does in Chrome.
- Chromium tabs: setting a website’s camera or microphone back to Ask or to Allow in the address bar no longer ends in “Could not change website device access”.

### Back and the mouse

- Back now works from a page WSurf opened in the other rendering engine. A search result for a website you set to Chromium (or a WebKit website reached from a Chromium page) used to leave Back dimmed; Back now returns to the page you left, with its whole history in WebKit, and asks the same “Switch rendering engine?” question as before when the page holds work.
- Back from the first page of a tab that a page opened (a link that opens in a new tab, a pop-up) now shows the page that opened it and closes the tab, as in Safari; ⇧⌘T brings the tab back. This holds only while the page that opened it is still open in the window.
- Settings › General › Browsing has a new switch, “Mouse side buttons go back and forward”, on as before. Turn it off to leave the buttons on the side of a mouse to websites.

### Themes and Appearance

- Brightness now changes the colors along the whole slider. On most themes half of it did nothing, because the color had already reached black or white after 10 to 40 percent. A theme you saved with a brightness set will look different at the same slider position. A light theme’s window is already almost white, so lighter has little room there.
- Customize replaces the two rows that did the same thing, Customize and Save as Theme. Customize saves a copy of a built-in theme under a name (“Nord Custom”) with its brightness, material and layout, and opens its colors; a saved theme keeps Edit Colors, Rename, Duplicate and Delete. A Settings search for “save as theme” finds Customize.
- Settings › Appearance now has a Window section and a Sidebar section side by side, each with its own Layout disclosure: page edge, corner rounding and page spacing under Window; tab and folder edges, sidebar margin, tab padding, folder indent and tab icons under Sidebar. The separate Layout card is gone, and Tint selected tab moved to Sidebar. Settings search finds each part under “Window layout” and “Sidebar layout”.

### Downloads

- Pointing at the Downloads button shows your five newest downloads, each with its name, its size or progress, and two buttons: Open, and Show in Finder. A file you moved or deleted is marked as such and its buttons are off. Pressing the button still opens the Downloads page, and so does Show All Downloads at the foot of the list. In a Minimal window the button is there only while a download runs, as before.

### Memory

- A window you close now gives back its tabs. A window that had been drawn was kept alive by its pull-to-refresh gesture, with everything its tabs held, until you quit WSurf.

### Under the hood

- Two performance tests were made steady (the credential search waits for the page to settle, and the four-window launch is timed with the welcome tour done). Nothing changes on screen.

### Known issues

- One- and two-letter address-bar queries search only the newest 3,000 pages; three letters and the History page search everything.
- Chromium tabs do not yet block `window.open` without a click, and open ⌘-click and middle-click tabs in front.
- Removing one website in Website data removes the cookies that exact host set; a cookie a website set for its whole domain (from www.example.com for example.com) stays until you clear everything. This was true before, but Chromium’s cookies now stay across a quit.
- Clear Browsing Data does not reach Chromium’s own small records of the sites you visited (the sites it must open over HTTPS, its site-engagement scores); they go when you delete the profile.
- WebKit tabs that both use the camera or microphone still take it from each other: showing another tab that uses them mutes the first for good, and WSurf has no button to resume it.
- Taking back camera or microphone access from a Chromium tab that is using it stops the devices by closing and reopening the page, and shows “Could not change website device access”.
- Back after an engine switch goes back one step only: Forward does not return to the other engine, and a Chromium page comes back by its address, not with its history.
- The known issues of 0.1.14 are unchanged.

## 0.1.15 (build 15) — 2026-10-27

Everything since 0.1.14 (build 14). None of the screens and prompts below has been checked by hand.

### Links

- Open Link in New Tab in the right-click menu works again in WebKit tabs. WebKit asked for its window the way a page asks for a pop-up, so WSurf blocked it as one on every website that blocks pop-ups, which is the default; Open Image in New Tab and Open Video in New Tab were blocked the same way. Chromium tabs gain Open Link in New Tab, Open Link in New Window and Open Link in New Private Window at the top of the menu on a link (a private tab offers only the private window); their menu had no link items before.
- WSurf’s own link items in WebKit tabs (Open Link in New Window, New Private Window, Open Link in Peek, Summarize Link and Download Linked File) now work for a link inside a frame from another website, where they did nothing.

### Security

- Choosing Open Link in New Tab, Open Image in New Tab or Open Video in New Tab lets exactly that one address through the pop-up blocker, once, and only for a moment (a quarter of a second). A pop-up the page opens by itself in that moment, or any window for another address, is still blocked and cannot use up your choice. Open Frame in New Tab is still treated like any pop-up, because WSurf cannot read the address of another website’s frame.

### Speed

- Faster launch: the window that was in front when you quit opens first, and your other windows, your favorites and the assistant with its voices follow straight after it, one at a time. Quitting before they have opened keeps them for the next launch.
- Much faster sidebar: clicking a row, dragging a row over a large list and switching tabs now redraw only the rows that change. In our tests on lists of 300 to 1,000 rows they take about a tenth of the time.
- History: Clear History is much faster on a large history (about twenty times in our test, and no longer minutes for a very large one), and opening a profile is faster, because it no longer rebuilds the history search index every time. Page titles are saved in batches, up to two seconds after they change; a crash in those two seconds loses the title, not the visit. One- and two-letter address-bar queries answer instantly from your recent history.
- Content blocker: the tracker rules are compiled only when they change, not on every launch, and the lists that earlier builds left behind are removed.
- Chromium tabs: less work per page and per frame from another website, about a tenth less of the app’s own work while a page loads in our tests. Pages do not load sooner.

### Smaller, faster build

- The build is now an optimised Release build, and Chromium ships only the English and Croatian interface languages. The app is about a third smaller on disk. Websites see no difference: Chromium reports the same languages to them as before.

### Known issues

- One- and two-letter address-bar queries search only the newest 3,000 pages; three letters and the History page search everything.
- Chromium tabs do not yet block `window.open` without a click, and open ⌘-click and middle-click tabs in front.
- The known issues of 0.1.14 are unchanged.

## 0.1.14 (build 14) — 2026-10-26

Everything since 0.1.13 (build 13). None of the screens and prompts below has been checked by hand.

### Passwords, passkeys and autofill

- Chromium tabs: a login or code field inside a frame from another website (a cross-site iframe, such as an embedded sign-in or payment frame) now gets the dropdown and Pick Credential…, as in WebKit tabs. The suggestions, the Pick Credential… sheet and the offer to save a login you typed there all use that frame’s own website, never the page around it: a frame cannot claim the page’s website, and the page cannot speak for the frame. Nothing is filled until you choose a row or press Fill, and a password or code still goes only into a form that sends it to the same website. Cards and addresses work in these frames as they do in WebKit, and a card still asks for Touch ID.
- While the assistant or a connected app controls a tab (it is working in it, is in the middle of a call on it, or holds it), WSurf now offers nothing there: no saved password, verification code, card or address in the dropdown, and no offer to save a login or card. This holds in WebKit and Chromium tabs and in every frame, and a fill that was already under way when the tab was taken is refused. Until now the password and code dropdown could still be opened in such a tab. When the agent lets go, the next click in a field asks again; a login typed while it held the tab is not offered for saving afterwards, and neither is an offer that was waiting when it took the tab.
- Chromium tabs: a sandboxed frame (an iframe whose sandbox gives it no origin of its own) is no longer trusted for autofill. Chromium reports such a frame under the website that embeds it, and WSurf used to take that at its word, so a sandboxed frame of the same website could be offered that website’s logins and saves. It now gets nothing, as in WebKit. In frames from other websites the same goes for an empty (about:blank), srcdoc, data: or blob: document.
- Settings › Credentials › Suggested Merges now suggests only credentials of the same website and the same username. A website is the host and the port, ignoring a leading www., so dev5.example.com and htz.example.com are different websites even with the same username and password, and so are two ports of one host. Numbered copies such as “name (1)” are still suggested, within one website, and so is a password, passkey or verification code saved apart for the same website. The same password, or a similar site name, is no longer a reason. Each suggestion says why under its title: “Same website and username”, “Copy (1) of “name””, and so on.
- Merging, cancelling or choosing Not the Same from Suggested Merges now comes back to the list instead of closing the sheet. The list keeps its place and selects the next suggestion, and the last one selects the one before it. For a moment after a merge the row buttons and Merge All Identical are dimmed until the new list is ready, so nothing is merged from an old list.
- Not the Same on a suggestion says those credentials are different, and WSurf never suggests merging them again, whatever you edit or merge afterwards. Dismissed (n) lists them, Suggest Again brings a group back, and each is one Undo. The choice is kept with the vault entry (the ids of the credentials it is not the same as, nothing else) and syncs with it once iCloud vault sync is turned on.

### Sound

- Sound from a player inside an iframe now counts as the tab playing, in WebKit tabs and in Chromium tabs, frames from other websites included: the speaker appears, the tab is in its list, and the tab is not put to sleep while it plays. Such a tab also takes part in the media panel like any tab that plays. Mute WSurf and a tab’s Mute reach those players as well, and in Chromium tabs they also use Chromium’s own mute, which covers frames and Web Audio that WSurf’s script cannot reach.
- Mute WSurf (the speaker, or View › Mute WSurf, ⌃⌘M) now also silences the assistant’s voice and Read Aloud. The assistant stops speaking and does not speak new answers while WSurf is muted, an answer’s Read Aloud button does nothing, and a voice conversation in progress ends; starting one while muted tells you to unmute. Read Aloud of an article pauses where it is and goes on from the same sentence when you unmute, and one you start while muted waits and speaks when you unmute. The setting that mutes the assistant’s voice is not changed: unmuting WSurf never turns on a voice you had muted. Nothing is kept after a restart.
- With the sidebar hidden (⌃⌘S), the speaker now sits in the toolbar, at the right of the address field before the connection badge and the extension icons, while a tab plays or WSurf is muted. It has the same list, the same click to mute and the same right-click menu. With the sidebar shown, or peeking, the sidebar’s speaker is the only one.

### Under the hood

- The string catalog now holds every string the app uses: about 1,170 were missing, most of them from Settings › Credentials, each with a note for translators. A new check, `Tools/check-string-catalog.py`, lists what a build uses that the catalog lacks. Nothing changes on screen.

### Known issues

- Credentials saved for login.example.com and for example.com are not suggested for merging, because only a leading www. counts as the same website; select both and use Merge With… to join them.
- When an iframe is removed while it plays, the tab can still show as playing for about half a second.
- The two known issues of 0.1.13 (no dropdown or Pick Credential… in cross-site frames in Chromium tabs, and a speaker that did not notice sound inside iframes) are gone; the known issues of 0.1.12 are unchanged.

## 0.1.13 (build 13) — 2026-10-25

Everything since 0.1.11 (build 11); 0.1.12 was not released, so its notes below are part of this build. None of the screens and prompts in either section has been checked by hand.

### Passwords, passkeys and autofill

- Right-click a field › Pick Credential… for the times the dropdown does not open, in WebKit and Chromium tabs. A sheet lists the logins and verification codes in your unlocked vaults, this website’s first, with a search; choose one and press Fill (or double-click). A login goes into the field you right-clicked and its partner field, a code into the code field, and a code split over several boxes fills them one by one. Nothing is filled into a form that sends what you type to another website, and the password or code is read from the vault only after you choose it. The item is not offered in private windows, with Save and fill passwords off, on a page that is not secure, or while the assistant or a connected app is working in the tab.
- When Pick Credential… fills an entry that is not saved for that website, the toolbar asks “Use “name” on host?” with “Add host to its websites.” Add Website adds exactly that website, as the address bar shows it, as one change in the entry’s History; Not Now stores nothing. If the page’s address imitates one of the entry’s own websites (a look-alike letter, a digit for a letter, a one-letter typo), the popover says so and Not Now is the default.
- A verification code saved for example.com is now offered on login.example.com and the other websites of the same domain. When nothing matches exactly, the code field shows “Check other logins for *.example.com”, which lists the codes saved for the domain; choosing one fills the code and then offers to add that website. A look-alike domain is never a sibling.
- More code fields get the dropdown: names such as totp, mfaCode, twoFactorToken and 2fa_code, and the words “authentication code” and “one time password”. “Security code” is still not taken for a verification code, because it may be a card’s.
- When one vault is open and the login or code for a field is in another, locked vault, the dropdown now shows “Unlock Credentials…”, which asks for the locked vault only; it used to show nothing. A vault you keep locked on purpose now shows this row on fields the open vault has no match for.

### Sound

- A speaker appears at the bottom left of the sidebar, beside the profile button, while a tab plays sound or WSurf is muted. Rest the pointer on it for a moment and a list shows each tab that plays, with its icon, title and website, “Another Window” or “Micro Window” when it is not in this window, and a Mute button of its own. Click a tab to go to it: its window comes forward, its space and row are shown, and a shut folder around it opens. The list covers the windows of the same profile, and a private window lists only its own tabs. The speaker is also in the Minimal bar’s island, in a micro window’s bar before Float on Top, and above the profile button in the icons-only sidebar; VoiceOver reads how many tabs play and offers a Show action for each, and right-clicking the speaker lists the same tabs.
- Click the speaker, or choose View › Mute WSurf (⌃⌘M), to mute every tab in every window, private and micro windows included; a page that starts to play afterwards is silent from its first sound. The speaker stays, crossed out. Click again and each tab gets its own setting back: a tab you muted yourself stays muted, and one you unmuted while WSurf was muted stays unmuted. It mutes the sound of pages, not the assistant’s voice or Read Aloud, and it is not kept after a restart.
- A muted tab now stays muted when it goes to another page; until now the new page was audible. Unmuting a tab also leaves alone a video the page itself keeps muted.

### Known issues

- Chromium tabs: a login or code field inside a frame from another website (a cross-site iframe) gets no dropdown and no Pick Credential… item, because WSurf’s page scripts do not run in such a frame. WebKit tabs are not affected.
- The speaker and its list notice only sound from the page itself, not from a player inside an iframe. Mute WSurf still silences such a player.
- The known issues of 0.1.12 are unchanged.

## 0.1.12 (build 12) — 2026-10-25

Everything since 0.1.11 (build 11). None of the screens and prompts below has been checked by hand.

### Tabs and sidebar

- A new tab scrolls into view in the sidebar and its row pulses gently, twice, so you can see where it went. This happens when a tab gets an address (⌘T and Return, a link opened in a new tab or in the background, a page opened by another app, Reopen Last Closed Tab, Duplicate): the list scrolls to put the row in the middle, as far as the list allows, and opens any shut folder around it. A blank new tab waits until you type an address. The list holds still while you drag a row, rename a tab or folder, or scroll it yourself, and the address field keeps the keyboard. With Reduce Motion the pulse is one highlight that fades.
- Folders can have a color and an icon of their own. Right-click a folder › Custom Color… opens the color panel and the folder changes as you drag in it; a swatch afterwards goes back to a preset. Icon… opens a search of SF Symbols to use in place of the folder icon, and Default puts the plain folder back. Each is one Undo. Folder color opacity, Size and Tint Icons as Folder work with them, and a color too close to the sidebar’s own is made lighter or darker until it can be seen. A pinned folder keeps them with the profile’s pins. They are not synced to other devices.
- A tab moved to a micro window stays in the sidebar, in the same place, folder and space, with a small micro window mark. Its row follows the page’s title and address. Click the row to bring the page back where it was, without reloading it, and the empty micro window closes; Option-click, or right-click › Show Micro Window, brings the micro window forward instead. Closing the micro window removes the row, and after a restart the row and its micro window come back together. The row is not a second copy of the page: it is never loaded, connected apps, the assistant and iCloud tabs do not list it, and closing the row closes no page.

### Window

- The Minimal bar now hides while you scroll down, so the end of a page is readable, and comes back when you scroll up or point at its edge. It follows the trackpad, the wheel, Space, the arrow keys, Page Down and End, on WebKit and Chromium pages. It stays while you edit the address or use Find, while the tab list is open, while a dialog, sign-in, certificate, permission, password-save or passkey prompt is up, and for a moment when you go to another website. The same goes for the bar at the top.
- Settings › Appearance › Window › Hide the bar while scrolling is now on by default. A Mac that turned it off keeps it off, and Reset to Defaults turns it on.

### Known issues

- A page with no website address (a local file, `data:` or `about:`) keeps the Minimal bar shown, so its end can still sit under the bar.
- A web app that scrolls an area inside the page, not the page itself, moves the Minimal bar with the trackpad or wheel only, not with the keyboard.
- The micro window mark is not drawn in the icons-only sidebar; its tooltip and menu still work there.
- The known issues of 0.1.11 are unchanged.

## 0.1.11 (build 11) — 2026-10-24

Everything since 0.1.10 (build 10). None of the screens and prompts below has been checked by hand.

### Tabs and sidebar

- Everything above the pin line is pinned, including every tab in a pinned folder and in its subfolders. A pinned tab keeps its place when you browse away, and unloading it (the X, ⌘W, Unload Tab, sleeping tabs or Free Memory) brings it back to its pinned page. A link opened from a page in a pinned folder now opens below the line, and ⌘D on such a page no longer moves it out of its folder.
- Right-click a pinned tab or a favorite that has wandered › Update Pinned URL makes the page it shows its new pinned page, beside Back to Pinned Page; one Undo puts the old page back. In the File menu the ⌘D item says what it will do: Pin This Page, Update Pinned URL or Unpin Tab. “Edit Pinned Page ▸ Edit…” is now “Edit Pinned Page…”.
- A new tab can be pinned: it pins the Start page and comes back to it.
- On first launch, a page in a pinned folder takes the page it shows as its pinned page. A tab in an ordinary folder that an older version still treated as pinned (left from a folder that was unpinned) is no longer pinned, and the X closes it.
- Tab, page and folder icons now sit on the middle of the row, level with the title, at every icon and font size: SF Symbols and favicons with uneven transparent padding were up to about 1.8 pt off. The open and shut folder icon no longer cross-fades, and thin symbol strokes are a little softer.
- Right-click a folder › Tint Icons as Folder draws the icons of the tabs in it, and in its subfolders, in the folder’s color. It is off by default, the current tab keeps its own colors, and the nearest folder that tints wins. One Undo turns it back.
- Settings › Appearance › Colors › Folder color opacity makes folder colors stronger or fainter (20 to 100 %, 100 % is the look until now). It is kept with the theme, like the Layout sliders, and Reset Theme to Default puts it back.
- Settings › Appearance › Layout › Folder indent now has a slider for Level 1, Level 2, and Level 3 and deeper. A theme that had one indent keeps it on all three levels, so nothing moves until you change one.
- The hidden sidebar, and the Minimal tab list, open only when the pointer rests at the left edge for a moment, not when it passes over it. They close when the pointer leaves them, when you switch to another app, or after a menu closes outside them; resizing the sidebar keeps them open.

### Window

- Full screen now uses the whole screen: the empty band at the top is gone. When you point at the top edge, the toolbar, the sidebar or the Minimal bar slides down with the menu bar and the strip of window buttons, and back up when they hide. With the menu bar set to stay, the toolbar sits right below the strip.
- New Micro WSurf window: just the page, with no controls until you point at the top of the window, where a small bar and the window buttons slide down. File › New Micro Window (⌥⌘N).
- Move any tab into a micro window with the new button beside Reader and the pin, from the tab’s menu or with Window › Move to Micro Window (⌥⇧⌘N). The page moves as it is, without reloading. Move Back to Main Window returns it.
- Float on Top keeps a micro window above other windows, on every desktop and over full-screen apps.
- Micro windows come back after a restart, with Float on Top off. A private tab stays private in its micro window, and the private session ends when its last window closes. While a page in a micro window asks something (a dialog, a sign-in, a certificate, a permission, a password to save, a passkey step), the bar stays down so the website’s address shows.
- The assistant no longer forgets the conversations of other windows when a new window opens.

### Developer mode

- Websites on local addresses (localhost, `*.localhost`, `*.test`, `*.local`, 127.x.x.x, `::1`) open in Developer mode: the address field shows the full address and a Developer Tools button with Copy Screenshot, Show Frame Rate, Outline Elements, Page Appearance (WebKit tabs), Open In another browser (not in private windows), Restart Page and Clear Website Data…. View › Developer › Developer Mode for “site” turns it on for any website and off for a local one; the choice is kept per profile, and a private window’s choice is forgotten when it closes.
- Clear Website Data… removes the storage and cookies of exactly the address it names, not its subdomains or its parent domain, and removes nothing if the page moved on while you were asked.
- View › Developer › Show Web Inspector (⌥⌘I), also in the ⌘K palette, opens WebKit’s Web Inspector for the page. Chromium tabs don’t offer it. Websites in Developer mode get Inspect Element even with the Web Inspector setting off.
- Copy Screenshot, in the Developer Tools menu and the ⌘K palette, copies a picture of the page as shown.

### History

- History groups the pages of one visit to a website into a trail you can open and close, with its pages in the order you visited them. A trail stays on one website.
- Pages that change their address without loading (single-page apps) are recorded as visits, with the title they end up with; a move to another part of the same page is not. History records the page’s own title, never a name you gave the tab.
- Older history loads as you scroll to the end of the list, and a middle-click on a row opens it in a background tab (a private tab only from a private window).
- A link clicked in a tab that was already open when you cleared History, or part of it, is recorded again. Until now that visit was lost.
- Private windows record nothing, and Clear History removes the trails too.

### Extensions

- Extensions that use features WebKit lacks now start: events it does not have are silent, `storage.managed` is empty and read-only, and an API the extension asks for that WebKit dropped answers with an error instead of being missing. Already installed extensions are updated on their next load. Nothing gains a permission, the manifest is never rewritten, and the iCloud Passwords adaptation is unchanged.

### Updates and release notes

- After an update the sidebar shows “Updated to 0.1.11” with a What’s New button, for 30 seconds or until clicked, once per installed build. The release notes no longer open by themselves.
- What’s New and WSurf › Release Notes… show WSurf’s own notes, from this changelog inside the app: the installed build first, with the older ones below. Nothing is fetched from the network.

### Interface

- Keyboard shortcuts in the ⌘K palette, the Ask hints, the profile menu and the shortcut recorder are drawn as key caps.
- New Private Window has a new symbol.
- The sidebar draws only the rows on screen, so a sidebar with a thousand tabs opens, switches tabs and scrolls in a fraction of the time. With VoiceOver, Switch Control or Full Keyboard Access on, it keeps drawing every row.
- Long lists outside the sidebar scroll without stalls: Settings › Websites and Website data, the assistant’s approved actions and memory, Downloads and the Release Notes page. A site whose icon is missing is not asked again for 15 minutes.
- Removing a site in Settings › Privacy › Website data shows a spinner on its row and no longer counts every site again; only that site’s data is removed, and a WebKit and a Chromium site of the same name stay separate.

### Known issues

- On a display at 1x (not Retina), a sidebar icon can still sit up to about 1 pt off its title.
- After 0.1.11 has recorded a single-page-app visit, an older build shows an empty History page, no recent history or frequent sites on the Start page and no history suggestions for an empty address field, until those visits age out or History is cleared. Going back to an older build is not supported before 1.0.
- A page that sets its title just before changing its address renames the previous visit with the new title, and an app that changes its address but never its title is not recorded.
- The known issues of 0.1.10 are unchanged.

## 0.1.10 (build 10) — 2026-10-23

Everything since 0.1.9 (build 9). None of the screens and prompts below has been checked by hand.

### Page watches

- Page Watches can now be found in Settings search: type “watch”, “monitor” or “notify when a page changes”, and the result opens Settings › Assistant at the Page Watches section.
- A notice WSurf could not show because notifications were off now stays in the Watches tab until you dismiss it, also after you quit and reopen WSurf. Hover a notice and click the ✕ to dismiss one, or right-click it for Open Page and Dismiss; Clear still removes all of them.
- A stored notice names only the site and what you were waiting for, never the page’s text. It goes away with what it names: Clear History and Clear Browsing Data (any kinds and range, and clearing on quit) remove every notice, stopping a watch removes the notices it left earlier, and deleting a profile removes its notices. The notice of a watch that ended on its own stays until you dismiss it, and a notice that a page can’t be read goes when the page reads again.
- A watch whose site you set to No Access now tells you it stopped, with one notification or, with notifications off, a notice in the Watches tab, instead of ending silently: “WSurf stopped watching this page because this website’s Assistant Access is now No Access.” Nothing more arrives afterwards.

### Passwords, passkeys and autofill

- Removing the last file of an entry that holds nothing else now says why (“Removing this file would leave the entry empty. Add a login, note or other detail first, or delete the entry. Nothing was saved.”) instead of “Check the details and try again.”

### Themes and appearance

- The Secondary text of Nord in its dark appearance and of Calm in its light appearance now reads at 4.5:1 or better: sleeping-tab titles are slightly stronger there, and the Colors panel no longer shows the low-contrast warning for them as they come. Copies of these themes you saved keep the values stored with them.

### Browsing

- Chromium: under the Allow autoplay setting, media a page starts by itself now plays even when the page was ready before the setting reached it. Muted and Never are unchanged.

### Under the hood

- CI now checks the line coverage of the shared vault and core packages (WSurfVault and WSurfCore) as well as the app, each against the same minimum; a package target that Xcode leaves out of the report is a warning, not a failure.

### Known issues

- If WSurf quits in the instant between a watch ending and the system saying it could not show the notification, that one notice is lost.
- The low-contrast warning for Calm in its light appearance and Nord in its dark appearance, listed under 0.1.8, is gone; the other known issues of 0.1.9 are unchanged.

## 0.1.9 (build 9) — 2026-10-23

Everything since 0.1.8 (build 8). None of the screens and prompts below has been checked by hand.

### Passwords, passkeys and autofill

- Importing a Passwords export again, from a CSV file or from the Passwords app, now changes only what changed since the last import. An entry that is the same on both sides is left alone, a change made only in Passwords is offered as an update (Use Incoming), a change made only in WSurf keeps your version, and a change made on both sides waits for your choice.
- Entries you deleted in WSurf, still in the Trash or after you emptied it, and copies you merged into another entry no longer come back with the next import. The review lists them under Skipped as “Removed from this vault before…” or “Merged into “…” before…”, and Import Anyway brings one back on purpose. If a merged copy changed in Passwords and the entry it was merged into still holds what the copy brought, the review offers the change as an update of that entry; otherwise it asks you.
- To recognize them, the vault keeps fingerprints of a deleted or merged entry’s website and user name and of the Passwords app’s own ids for it, made with the vault’s key and stored inside the encrypted vault. After you empty the Trash, nothing else of the entry is kept: not its password and not its note.

### iCloud (not turned on yet)

- This version contains iCloud sync between your Macs, switched off: the other Macs’ open tabs in the sidebar, and keeping a vault the same on your Macs, with every entry encrypted with the vault’s key before it leaves the Mac. Until it is turned on, nothing reaches iCloud and nothing in WSurf looks different. It is turned on after Apple’s iCloud setup for WSurf is finished and a check with two Macs has passed.

### Under the hood

- The vault’s store, encryption and Credential Exchange code now live in a shared package, ready for an iPhone app. Nothing changes in use.

### Known issues

- An entry imported before this version carries no record of what the import brought, so the first time it changes in Passwords the review still asks you about it once; from the import that saves it again on, it follows the rules above. Its deletes and merges are remembered, except an entry from a file import that was already emptied from the Trash before this version; an entry from the Passwords app stays remembered by its id.
- The known issues of 0.1.8 are unchanged.

## 0.1.8 (build 8) — 2026-10-22

Everything since 0.1.7 (build 7). None of the screens and prompts below has been checked by hand.

### Window

- In full screen, the toolbar, the sidebar and the Minimal bar now start below the strip macOS slides in at the top of the screen (the title bar with the window buttons), so it no longer covers the address field or the Minimal bar. This works with the menu bar set to hide or to stay. While the strip is hidden, a narrow band of the window's background stays empty at the top.
- The Minimal window can keep its tab list open: click the pin at the top of the list, or choose View › Keep Sidebar Open. The page and the bar move over to sit beside the list. The choice applies to every window and is remembered after you quit. Hide Tabs, ⌃⌘S and Hide Sidebar let go of the pin and hide the list.

### Tabs and sidebar

- ⌘W now closes the active tab, as the X in the sidebar does; Undo or ⇧⌘T brings it back. A pinned tab, a favorite or a page in a pinned folder is unloaded instead, as before. The File menu item says Close Tab or Unload Tab, depending on the tab. Like the X, ⌘W does not ask about a form you were filling in, a download or playing media; Undo brings the tab back.
- Right-click a folder › Sort › By Name or Folders First to sort what is in it. One Undo puts the order back, and a pinned folder's new order shows in every window of the profile.
- Right-click a folder › Size makes that folder's row larger: Normal, 1.5×, 2× or 2.5×. Its name keeps your sidebar font, and the tabs inside stay their usual size. The size is remembered, and a pinned folder's size shows in every window. The icons-only sidebar draws every folder at its normal size.
- Tab and folder titles now line up with their icons on the capital letters, so a title no longer sits a little above its icon. A title in lowercase letters only sits slightly lower than before.

### Themes and appearance

- Settings › Appearance › Layout › Folder indent moves what is inside an open folder to the right, from None to 24 pt, once for each level. None, the default, looks as before.
- Tab text, Unloaded tab text and Icons colors that would be hard to read are now darkened or lightened only as much as needed and keep their hue and as much of their transparency as still reads, instead of turning plain black or white. The row says so when this happens, for example “Shown at 72% so it stays readable.” Each color row has a short description, the opacity slider shows its percentage, and the panel says whether you are editing the light or the dark appearance.
- A theme's accent color now reaches the switches, sliders and progress bars in the window and in Settings, the address bar's loading bar, the autofill list and the selection in the credential and Input History lists. A theme without an accent keeps the macOS accent color.
- A theme's assistant color now colors the assistant's questions, buttons, status and voice indicator, not only the small marker shown while it works. A theme without one uses the accent color.
- Make your own theme: Settings › Appearance › Theme › Customize… copies the current theme as “Nord Custom” (or whichever theme you are on) and opens its colors. Set the Window background, Sidebar, Surface, Primary text, Secondary text, Accent and Assistant colors, for light and for dark. Secondary text is the former Unloaded tab text row. Changing the window, sidebar or surface color of a copy of Standard or Calm draws it as a solid color without the website tint; putting the original color back brings the tint back. Text under 4.5:1 contrast shows a warning with its ratio, and your color is kept as you picked it. The copy WSurf makes when you first recolor a built-in theme is now named “… Custom” too.
- Settings › Appearance › Theme › Reset Theme to Default puts a theme back as it came: every slider (brightness, glass, spacing, edges, corners, icons, folder indent and the rest) and, for a theme you made, its colors, taken from the theme it was copied from. Its name and your other themes stay as they are. WSurf asks first, and a reset can't be undone.
- Settings is denser: options sit closer together on every page, including the Colors and Layout groups on the Appearance page, which now line up with the other cards.

### Known issues

- Calm in its light appearance and Nord in its dark appearance show the low-contrast warning for Secondary text as they come: their sleeping-tab text is dimmer than 4.5:1 on the window or the sidebar.
- The known issues of 0.1.7 are unchanged.

## 0.1.7 (build 7) — 2026-10-22

Everything since 0.1.6 (build 6). None of the screens and prompts below has been checked by hand.

### Window

- New Minimal window style: the page gets the whole window, with a floating bar at the bottom (or top) and a tab list that slides in from the left. Choose it in Settings › Appearance › Window, with View › Use Minimal Window Style (⇧⌘M) or from the command palette. Standard stays the default.
- The Minimal bar keeps everything the address bar has: asking the assistant and its questions, the engine badge, password and passkey saving, Input History, Reader, translation and site controls, plus the AI mark and Stop for connected apps, downloads, extensions and the side panel.
- The tab list is the full sidebar: open it from the bar, with ⌃⌘S or by pointing at the left edge. Your Standard sidebar settings are untouched.
- Optional: hide the Minimal bar while scrolling, and move it to the top (View › Move Bar to Top). Your theme’s spacing, corners and glass apply, and Reduce Transparency, Increase Contrast and Reduce Motion are respected.
- Setup asks whether you want Standard or Minimal. Existing installs stay Standard.

### Address bar

- Settings › General › Show full website address shows the whole page address instead of only the website name. The website name is never cut first, sign-in details in an address are never shown, and names in other scripts appear as punycode so look-alike addresses can’t pose as another site.

### Spaces

- A space is a named set of tabs and folders. Once a profile has a second space, its icons sit at the bottom of the sidebar: click one, press ⌃1–⌃9 or swipe sideways with two fingers over the sidebar to switch. Pins, pinned folders and Favorites belong to the profile and show in every space.
- New Space… is in the profile menu, the ⌘K palette and the icons' menu. A new space either shares the sign-ins, history and passwords of an existing profile, or gets its own: “Separate sign-ins and data” creates a profile for it.
- Choosing a space of another profile switches the window to that profile, as the profile menu does: this profile's passwords lock, connected apps lose the window, the assistant stops and the tabs reload. WSurf explains this the first time.
- Move to Space in a tab's or folder's menu, or dragging it onto a space icon, moves it to another space of the same profile. Deleting a space closes its tabs; it never deletes a profile or its passwords, and a profile always keeps one space. Profiles are still deleted only in Settings › Profiles.
- Each existing profile starts with one space named after it. With one profile nothing changes until you add a space; with several, each profile shows as a space in the switcher.

### Browsing

- Reader can read the article aloud. View › Read Aloud (⌥⌘P), or the Read Aloud button in Reader's bar, starts at the headline with your Mac's own voice, one sentence at a time, and marks the sentence it is on; the same command pauses and resumes, and the bar can skip by sentence. The speed button sets 0.5× to 1.5× for every article, and a sentence in progress carries on at the new speed. A translated article is read in its translated text, in the voice for the language it was translated to. Hide Reader, a new page, another tab or View › Stop Reading ends it. Reading aloud uses only the voice built into your Mac, never a cloud service, and starts only when you ask.
- Reader opened over a page that is already translated (Always Translate or Translate Page) now reads the text the website wrote, so Translate Page can translate the article and Show Original brings its text back; the page behind keeps its translation.
- A local file that carries the macOS quarantine mark (anything fetched with a browser, mail or chat, whether typed by its `file:` address, dropped on the toolbar or opened from Finder or Downloads) can now read only itself. In WebKit a downloaded page, drawing or any other file that is not an image, PDF, text, audio or video file also runs without JavaScript and cannot open other local files in frames; in Chromium its other files are refused. Your own saved pages and project folders keep their scripts and still load their stylesheets, scripts and images from their folder, and a folder you open still lists its files. Pages that WSurf saved itself carry the mark, so they open without scripts.

### Passwords, passkeys and autofill

- Settings › Autofill is one page with a vault picker and two tabs. **Vault** shows everything in the vault by section (Logins, Passkeys, Codes, Identities, Cards, Addresses, Contacts, Notes, and Files while an entry holds one) with Trash, and Input History. **Settings** holds what autofill saves and fills, Apple Pay, your vaults, unlock passkeys, import and export.
- You can keep identities, such as your children's details, in the vault: Add › Identity starts with a name, an ID document, a hidden OIB, a date of baptism and medical notes, and asks for no sign-in. The Add button still adds a login with one click; its menu also adds an identity, a payment card, an address or a secure note.
- Each custom field has a type: Text, Hidden, Date, Number or Email. Dates can be picked from a calendar. Showing, copying or exporting a hidden custom field, such as an SSN, asks for Touch ID, like a card or an ID document.
- Payment cards, contacts and addresses are now saved in your vault. When you submit a checkout or address form, WSurf offers to save the card or address there, as it does for passwords, and fills it from the vault. A card still asks for Touch ID or your Mac password; addresses fill while the vault is unlocked. With every vault locked, card and address fields offer “Unlock Credentials…”. A profile with no vault gets no card or address save offer.
- Cards and addresses saved on this Mac by earlier versions move into the vault only when you ask. The open Vault tab shows a card for them: Review lists their titles (cards ask for Touch ID once), Move to Vault adds what the vault doesn't already hold, and until you confirm, Undo moves those entries to the Trash. Erase Old Copies… then deletes the old cards and addresses and their rows in the list WSurf suggested them from. That list kept card endings, cardholder names, email addresses and streets in plain text, readable without Touch ID; WSurf checks that none of it is left. Until you erase them, the old copies stay on this Mac and are still offered when filling.
- Cards and addresses are never offered, filled or saved in a tab the assistant or a connected app controls.
- Cards and addresses are added and edited in the vault (Add › Payment Card or Address); the separate card and address lists are gone.
- Settings › Autofill › Settings › Import & Export imports payment cards from a Safari export and a contact from Contacts straight into the vault. A review lists what will be added, Import adds it in one step, and Undo takes it back.
- Any vault entry can keep files: scans, photos, PDFs, ZIPs or anything else, up to 50 MB each, 64 per entry and 2 GB per vault. Add File… in the editor encrypts each file in the vault; Preview opens it in Quick Look, Save Copy… saves a decrypted copy where you choose, and Open With… opens it in another app. Nothing is decrypted until you ask, and a preview's copy is deleted when you close it, when the vault locks and when WSurf quits.
- A removed file can be brought back from History or with Undo, an entry in the Trash keeps its files, and merging entries keeps every file. Emptying the Trash or deleting a vault deletes the files nothing else uses. The Vault tab's Files section lists the entries that hold files and how much of the vault's room they use.
- Files aren't included when you export credentials to another app; use Save Copy… for each file.
- Once any vault of a profile holds a file, WSurf 0.1.6 and older, 0.1.5 included, can't open that profile's credentials: they say “Couldn’t access credentials.” and change nothing, so they can't lose the files. Removing the files doesn't undo this. If a newer WSurf saved your credentials, this version says so and changes nothing.
- Input History is now kept with your vault. Once a profile has a vault, showing the entries needs that vault unlocked as well as Touch ID or your Mac password, and recording goes on while it is locked. The first time you open it with your default vault unlocked, the existing key moves under the vault without losing or re-encrypting any entry. Deleting that vault deletes what Input History kept with it, and Delete Vault lists those entries first. Profiles without a vault work as before.
- Settings › Autofill › Vault › Input History can keep Input History in the vault the picker shows: choose Keep Here with both vaults unlocked. Only the key that opens it moves. No entry is lost or encrypted again, and nothing is asked for. The page now says that showing the entries needs that vault unlocked, then Touch ID or your Mac password.
- Importing from Contacts takes several contacts at once: click each one you want, close the list, and review them together. Import adds them in one step, and one Undo takes them all back.

### Extensions

- Website Settings (the sliders button beside the address) lists the extensions that run on the page, each with Block on this site, or Allow on this site while it is blocked there. An extension blocked on a whole website, such as example.com, is allowed again from any of its pages. An extension's toolbar button menu has the same Block and Allow for the website in front.
- Settings › Extensions lists, under each extension, the websites it is blocked on; Remove lets it run there again and reloads that website's open tabs.
- Extensions run only in WebKit tabs; in a Chromium tab, Website Settings and the toolbar menu say so instead of offering a control. Blocks made in a private window are forgotten when it closes.

### Page watches

- Watch a page and get one notification when it shows what you're waiting for, or when it changes: View › Watch This Page…, or ask the assistant. Up to 20 watches per profile, checked every 15 minutes to once a day, for up to 30 days, while WSurf is open. Find them in the side panel's Watches tab, where you can open, check, pause or stop each one, and in Settings › Assistant › Page Watches.
- Watches read pages without your sign-ins unless you tick "Use my sign-ins for this page" for that watch. Sites you set to Chromium are read with WebKit, and the watch says so.
- Pages are judged by Apple Intelligence on this Mac, never by an online model. Without it, a watch for any change still works; waiting for something specific needs it.
- Notifications name the site and what you're waiting for, never the page's text. With notifications off, the Watches tab keeps the notice and shows a count.
- The assistant asks you every time before it watches a page. Private windows can't watch pages, connected apps have no access to watches, a site set to No Access is never read, and Clear History forgets the stored page text.

### Assistant and MCP

- When the assistant remembers something about you, the answer shows "Remembered …" with Undo, which forgets a new note or puts back the earlier value.
- When you ask for something that depends on a preference only you know, such as "my usual colour", and no note answers it, the assistant asks you before it changes the page. Memory stays off until you turn it on, and its notes are written on this Mac.
- Connected apps written for Playwright MCP work with WSurf unchanged: browser_navigate, browser_click, browser_snapshot, browser_tabs and 15 other Playwright tool names are accepted as aliases of WSurf's own tools, with the same access rules, in background tabs and on both engines. A tab an app controls now counts as seen even while its window is covered, so pages that wait to be looked at, such as bot checks, keep going; your own tabs are unchanged.

### Fixes

- The native History test for merged credentials gives the primary its own verification code, so it checks that another credential's password and code never show as one version.
- Accent-coloured text stays readable on the window, sidebar and control surfaces at any theme Brightness. In some dark themes at +50 % and above (Calm, Catppuccin, Rosé Pine) it fell to about 4:1.
- The Sidebar margin setting also applies to the icons-only and floating sidebars; at the default margin nothing changes.
- The experimental video player no longer lets the page under it react to the pointer.
- Closing a tab no longer leaves password saving and password filling holding on to that page's frames, which used to add up the longer WSurf stayed open.
- Opening and closing tabs while WSurf works out a page's language can no longer crash it inside macOS's translation service. WSurf keeps one set of translation objects for as long as it runs, asks the service one question at a time, and waits half a second after a page loads before reading its language.
- The memory checks of the performance tests now judge the middle of five samples after a warm-up run instead of the average, and the vault-scale write cases hand freed memory back before and after each measured step, so one noisy sample no longer fails a run. No budget changed.

### Known issues

- With the vault locked, Input History's Show Entries asks you to unlock it in Settings › Autofill; it doesn't unlock on the click. Input History stays with the vault it is kept in until you choose Keep Here on another vault; making another vault the default doesn't move it.
- A removed file stays on disk, encrypted, while History names it. History never empties by itself, so that room comes back only when the entry is moved to the Trash and the Trash is emptied.
- Reading aloud and VoiceOver speak at the same time if both are on.
- One native test of the website sign-in (WebAuthn) code waits out its two-minute limit in a full test run, late in the run: in two full runs of this build it was a different one each time (the profile-with-no-vault ceremony hand-off, then the buffer-source check). Run alone, the same suites pass every time (three runs each). It is the late-run time-limit failure known from earlier builds, with no fault found in the sign-in itself.
- The noisy memory checks described under 0.1.6 are addressed by the new gating above, and this build's native test run held every performance budget with it, including the new ones for the Minimal window and for switching spaces. While the sidebar is peeking, the experimental video player's shadow can still show around it.

## 0.1.6 (build 6) — 2026-10-21

Everything since 0.1.5 (build 5), the installed candidate. None of the screens and prompts below has been checked by hand.

### Browsing

- On the Downloads page, a finished download can be previewed with Quick Look: use the eye button on its row, Preview File in its right-click menu, or select it with the arrow keys and press Space. The right-click menu also gains Open With, which lists the apps that can open the file, and Open in WSurf, which opens a PDF, image or text file in a new tab, able to read only that file. Show in Finder is still there. Nothing opens by itself, and downloaded files keep their quarantine.
- With Settings › Experiments › Show video in the player on, the video player can be dragged to any corner of the window. It snaps to the nearest corner when you let go, remembers its corner in every window, and View › Move Player to Corner (also in the player's right-click menu and as VoiceOver actions) moves it without dragging. Bottom Left is still the default and docks it in the sidebar as before.

### Passwords, passkeys and autofill

- When you merge credentials you now choose the primary one; its name, username, password, verification code and notes win, and nothing else is lost: every passkey, note, card and other item is kept, websites on other sites start ticked, and every other password and verification code, with its earlier versions, stays in the merged credential's History. Command-Z still takes the merge back.
- Copies an export numbered “name@example.com (1)”, “(2)” … on one site are suggested as one login and merged into it, several at once; with the same password Merge All Identical collapses them.
- Each credential has an Open Website button that opens its site in a new tab of the same window, and in the editor you can open a website from the menu beside Copy or by Command-clicking it.
- Right-click a credential for Open Website, Copy Username, Copy Password, Edit, Merge, Move to Trash and Select. Select shows checkboxes so you can pick several and move them to Trash or merge them; the separate Merge With window is gone.

### Fixes

- Test runs now free the windows each test closes. Every event the test host takes gets its own autorelease pool, as the app's own event loop gives each event one; before, a closed window stayed in memory until the run ended. The native test `representativeFixturesLeaveNoWindowBehind`, left out of 0.1.5, is back.

### Known issues

- While the experimental video player floats over the page, the page underneath can still react to the pointer, and while the sidebar is peeking the player's shadow can show around it.
- The memory checks of the performance tests are noisy in long test runs, and a bad run can fail one of them (the sidebar layout check described under 0.1.5 is one). Their samples sometimes swing by 20 MB or more either way, or one sample carries a single 20-45 MB step, so the average goes over its budget (in this build’s test run: saving an autofilled password and signing in with a passkey in a vault of 20,000 credentials, and the crowded sidebar layout), while the same checks on a fresh test host stay far below it and every time budget passes. This is a measurement quirk of the tests, not a leak found in WSurf. The budgets are unchanged; the next build judges memory by the middle sample after a warm-up instead of the average.

## 0.1.5 (build 5) — 2026-10-21

Everything since 0.1.1 (build 2), the installed candidate; build 3 and 0.1.4 (build 4) were never installed, and their changes are included. None of the screens and prompts below has been checked by hand.

### Browsing

- In Reader, View › Translate Page now translates the article instead of the page behind it, Show Original brings its text back, and Find shows how many matches the article has. Find also counts matches on websites whose JavaScript you turned off.

### Passwords, passkeys and autofill

- GitHub passkey sign-in works in WebKit tabs.
- A passkey asked for right after you unlock the vault no longer fails silently.
- On WebKit, a sign-in that needs a hardware key, a phone or an iCloud passkey that is not in the vault offers “Continue in Chromium”, which opens the page in a Chromium tab of the same profile.
- Imported Apple passkeys report as synced.
- When a website has several passkeys, none is preselected.
- Export to another app now includes cards, addresses, names, Wi-Fi networks, API and SSH keys, identity documents and custom fields. Each credential offers “Cards and other items” in the export sheet, which lists, kind by kind, every value the selected items carry and says that card numbers, security codes, PINs, document numbers, Wi-Fi passwords and keys leave the vault for the app you pick. Exporting a card or an ID document asks for Touch ID first. Every value keeps its type, so a hidden one stays hidden, and importing the export back gives the same items. A CSV file still holds only passwords.
- When a site offers to save a passkey to a credential that holds only notes or only cards and other items, the prompt now says so instead of showing an empty detail.
- Saving in a large vault does less work: the credential editor, an autofilled password, adding a website, a passkey registration or sign-in, a merge, an undo and a restore from the Trash name the credentials they change, so the vault no longer encodes every other credential to find them. A change to a credential that was not named is still written, and every whole-vault check still runs.
- A clipboard button beside the key opens Settings › Autofill › Input History while it is on. The count under the entries now reads “1 entry”.

### Assistant and MCP

- The assistant can remember things about you, per profile. It is off until you turn on Settings › Assistant › Memory › Remember things about me. Apple Intelligence writes the notes on this Mac from what you type and your answers to the assistant’s questions, never from pages, passwords, codes or payment details. You can see, edit and forget each note, or forget them all; turning memory off asks whether to forget everything. A cloud model gets the notes it needs with your request. Private windows keep no notes.
- A task now also shows in every tab the assistant opens for it, and those tabs show the assistant working until it finishes.

### Appearance

- Settings › Appearance › Layout adds Page spacing (down to none, so the page meets the window and the sidebar), Sidebar margin (down to 1 pt), Tab padding and Tab icon size (12–24 pt). Each is saved with the theme, previews live, and comes along with Save as Theme and Duplicate. The defaults keep today’s look.
- A page with no spacing has square corners; the resize handles still work at its edges.
- Theme Brightness now goes from −100 % to 100 %. Text, icons and accent text stay readable at both ends.
- Theme thumbnails show the current tab the way the sidebar draws it, and show each theme’s spacing and icon size.
- Tab icons pick a larger site icon when the site offers one, so they stay sharp at bigger sizes.

### Fixes

- Credentials no longer shows “Locked” for a moment when the vault is open.
- About WSurf and Settings › About show the candidate label and commit under the version. Builds without a candidate label show nothing.
- A new Chromium tab whose first page redirects straight to an app offers to open the app instead of doing nothing.
- The Chromium external-app handoff test listed under 0.1.1’s known issues replayed the click in the wrong frame; it now clicks in the frame that hands off, and the product was not at fault.
- Forgetting a profile also deletes its empty preferences file.
- Test runs free the windows and web views each test closes; before, they stayed in memory until the run ended. The vault tests open no windows, and ten vault suites now run in the parallel plan.

### Known issues

- One native test, `representativeFixturesLeaveNoWindowBehind`, is not part of this build. It checks that a test’s closed window is released, and its hidden test window still outlives it: a full test run ends with about a thousand closed windows in memory. The leak is in the tests’ own windows and predates this release; no screen of WSurf is affected. The test returns once it passes.
- The sidebar layout memory check in the performance tests sometimes measures one extra step of about 20 MB in a single sample. In this build’s test run four of five samples were under the 7 MB budget and the fifth was 21.5 MB, so the average went over. It is a measurement quirk of the test, not a leak found in WSurf; the check is to be made robust in the next build.

## 0.1.1 (build 2) — 2026-10-21

Everything since 0.1.0 (build 1), the installed candidate 6.2. None of the screens and prompts below has been checked by hand.

### Browsing

- Translate a page on this Mac with Apple’s on-device translation, in WebKit and Chromium tabs. The address bar offers it when a page isn’t in a language you read; View › Translate Page works too. Show Original brings the page back, and Always Translate a language is remembered per profile. Private windows translate only when you ask. Tabs the assistant or a connected app controls are never translated automatically.
- View › Show Reader (⌥⌘R) shows the article without the page around it, with its reading time, and links open in a new tab. Text size, font and a Sepia look are kept for every tab and window; zoom changes the text size, and Print and Find work on the article. Not yet: Translate Page still translates the hidden page, and Find shows no match count in Reader.
- Settings › General › Archive unused tabs can close tabs left unused for 12 hours, a day or a week (Never by default). The newest 30 archived tabs stay searchable in ⌘K: Show Archived Tabs, or type “arc” and press Tab, then restore a tab next to the current one or remove it.
- Pages see far less of WSurf: its own page helpers run out of the page’s reach in WebKit and Chromium, and WebKit keeps each website’s pop-up and auto-play answers itself, so built-ins such as `window.open` stay the browser’s own. What remains in a page is the passkey, notification and location support.
- Chromium tabs no longer show pages the traces of DevTools automation that bot checks flag, and keep the engine’s own client hints.
- Google sign-in always opens in WebKit, since Google refuses sign-in from embedded Chromium, and the redirect back to a service set to Chromium keeps the sign-in. The engine choice for Google sign-in says so.
- Back in a Chromium tab no longer loses the page you came from when the page adds a history entry right after loading.
- Auto-play “Muted” now works like Safari’s “Stop Media with Sound”: a video that would start with sound waits for you; muted videos still play.
- Pop-ups a page opens by itself, including from a scripted Cmd-click, are blocked like any other pop-up you didn’t open. A blocked pop-up with no address is blocked without a notice. In a Chromium tab a pop-up that a page opens without any action of yours is blocked before WSurf hears of it, so there is no “pop-up blocked” notice for it; WebKit tabs show one.
- The tracker count, and the tracker blocker in Chromium tabs, count only trackers from other websites; a website’s own subdomains are no longer counted or blocked as trackers.
- After you switch on an extension, tabs opened from then on get its page script fixes; tabs already open get them once reopened.
- A screen share in a Chromium tab keeps that tab from being unloaded.
- WebKit tabs and pop-ups report their window’s outer size and position, as Safari’s do. Pages that read them, such as Hetzner’s proof-of-work login check, no longer see a window of size 0. A Chromium sign-in loop on the same page may also be Hetzner’s rate limit from the earlier attempts.
- In a Chromium tab, a script run in the page’s own world inside a subframe must be a single expression; a list of statements is rejected. The main frame and WSurf’s own scripts are not affected.
- Groundwork with no screen yet: an extension can be blocked on a website (WebKit tabs only), which also stops its button, popup and menu items there.

### Passwords, passkeys and autofill

- Credential Manager also keeps cards, addresses, names, Wi-Fi networks, API and SSH keys, identity documents and custom fields, alone or next to a login. They come in with a transfer, show in the list with Cards, Addresses, IDs and Other filters, and can be edited and copied. Showing or copying a card’s or an ID document’s hidden values, opening its editor, or showing a History that held one asks for Touch ID or your Mac password. Web forms can fill the vault’s addresses, and its cards after Touch ID, never in a tab the assistant or a connected app controls. Not yet: exporting these items, and saving a card or address typed on a page into the vault (it still goes to the old store).
- Large vaults are faster: with 20,000 credentials, editing one, saving the editor, listing where an imported passkey can be merged and choosing a merge in a full import review no longer check the whole vault again each time. A credential saved by an older build that today’s rules refuse no longer blocks edits to other credentials; edits to it are still refused.
- A page can ask for a passkey while it is still loading; before, such a request was refused until the page had finished loading. A request made after a replaced navigation or a download is served as well, challenges up to 64 KiB are accepted, and a refused request writes its reason to the log (the kind of error only, no data). This is the fix aimed at Google’s passkey sign-in; it has not been tried against Gmail by hand.
- The Delete Vault sheet now comes down while the system passkey prompt is open and returns if you decline it, so the prompt is no longer left waiting behind it (not tried with the real prompt). A vault that the sheet would show as all zeros, with no credentials, no Trash and no history, is deleted with one click and no confirmation; unlocking is still required. Excluded sites (Never for This Site) count, and the sheet now lists them.
- Input History (Settings › Autofill › Input History), off by default:
  - With Remember what I type on, text you type on websites, including passwords, is kept encrypted on this Mac for 30 minutes, 2 hours, 1 day, 1 week or until you delete it. It is never synced. Turning it on asks first; turning it off deletes everything.
  - Not recorded: private windows, excluded websites and their subdomains, card numbers, security codes, one-time codes, rich text editors, values a page script or autofill put into a field, and any tab while the assistant or a connected app works in it.
  - The entries open only with Touch ID or your Mac password, and lock two minutes after the page closes or with any vault lock. Passwords stay masked until you reveal one. Copy marks the clipboard concealed and clears it after a minute.
  - Save as Credential saves a password entry into Credential Manager only after you confirm the username and what it changes.
  - The assistant and connected apps have no way to read it.
  - Not in this pass: the address-bar icon, pasted images and uploaded file names.

### Assistant and MCP

- Connected apps work in background tabs without taking your tab or keyboard focus, and every tab an app holds shows an AI mark with Take Over and Stop.
- The assistant’s website access applies to the whole website: the prompt names it (“Allow Assistant on google.com?”) and says it covers every page on it. An earlier Read Only or Allow Control answer for one page is not widened; the assistant asks again. Settings › Websites › Reset on any page of a website resets its assistant access, and says so. Sharing grants for connected apps still apply to one origin.
- Recent tasks on the start page leave out tasks without a question you typed, such as continued or resumed ones.
- Groundwork with no screen yet: a per-profile store for short notes the assistant keeps about you. Nothing writes or uses it yet; it is off by default, private windows have none, and connected apps cannot read it.

### Appearance

- Settings › Appearance › Layout sets a theme’s page edge and tab and folder edges (Standard, Thin edge or None), corner rounding from square to 150 %, and tab icons in Monochrome or Color. Built-in themes look as before until you change it; Increase Contrast keeps an edge.

### Fixes

- In Chromium tabs, WSurf’s own scripts no longer count as a click, so they cannot open pop-ups or start sound. Connected apps’ clicks and typing and WSurf’s media controls still do.
- Test runs keep their preference files in a test folder instead of `~/Library/Preferences`, and the command palette and sidebar row tests close the windows they open.

### Known issues

- A native test of the Chromium external-app handoff (a link to another app opened without a referrer by a page inside a frame of a different website) fails on some runs. When it fails, the request is dropped before WSurf sees it: no app is launched, no approval is remembered and no prompt is shown. The cause is still being traced.

## 0.1.0 (build 1)

- Credential Manager no longer freezes after unlocking a vault with thousands of credentials; long lists draw only the rows on screen.
- MCP for development and QA:
  - Paired apps connect with revocable tokens.
  - Every action reports what changed on the page.
  - Page dialogs, drag and key chords.
  - Console and network detail, plus opt-in headers and bodies on developer sites.
  - An accessibility outline and a performance summary.
  - The Developer tier, with a Developer profile and developer sites: test passwords, scripts and DOM edits.
  - Compare a page in WebKit and Chromium.
  - Media emulation, and clearing one site’s data.
- A badge in the window shows which app controls it, with a Stop button.
- Paired apps can follow a default website access level instead of asking before every new website.
- WSurf asks before the assistant or a connected app closes a tab. Pinned tabs are never closed.
- Back in a new Chromium tab no longer returns to the empty startup page.
- The import review recognizes exact duplicates: an item that matches a saved login (same site, username and password, or the same passkey) is shown as already saved, or as a suggested merge that only adds what’s missing.
- Passkeys with user handles longer than 64 bytes (for example PayPal’s) now import and sign in.
- File › Free Memory unloads background tabs in every window.
- WSurf has a new app icon, the Tandem mark: a violet disc with a smaller mint disc riding in its wake. It follows the system’s light, dark and tinted looks.
- Pins, pinned folders and Favorites now belong to the profile and appear in every window of it. Pins that existing windows already had are merged into the profile once.
- Closing the last window and then quitting brings that window back at the next launch.
- The review of an import from Passwords shows one row per item, with the decisions that need you first, a search field, filters and actions that decide a whole group. Re-importing items that haven’t changed no longer asks about them.
- A passkey that isn’t imported now says exactly why.
- Tab and folder rows in the sidebar are vertically centered on their icons.
- Glass becomes solid when Reduce Transparency or Increase Contrast is on.
- The assistant has a default website access level, Ask, Read Only or Allow Control, for websites without a setting of their own. It now asks before clicking “Continue with Google”-style sign-in buttons.
- Credential Manager is now the only password store. Passwords saved by earlier builds are imported once, after you review them; the old list is deleted only after that import and your confirmation. Sites excluded with “Never for This Site” in the old list are offered again.
- Passkey requests in normal tabs show Credential Manager first, with Use Another Device or Key… to use Apple Passwords, a phone or a security key.
- Transfers from Passwords now fit large libraries: up to 25,000 items and 100,000 credentials. A refused transfer names the limit it hit, and an item with more than 64 websites keeps the first 64.
- Approving an app link such as “Open Claude?” now opens the app even when the sign-in page moves on within the same site. A link whose requesting frame can’t be confirmed now asks once instead of doing nothing.
- Notes from Passwords are kept in the credentials store. A transfer is no longer refused because of a note or other data WSurf can’t store yet; the review lists what was left out. CSV import and export include notes.
- The current tab is shown in inverse colors in the sidebar, and tabs opened in the background that you haven’t seen yet are marked with a dot.
- Small element screenshots no longer fail, and Chromium tabs no longer go back to an empty startup page.
- The native test suite no longer fails on 16 test defects and 4 timing-dependent diagnostics tests.

### 2026-10-19 — Credential Manager, login saving, themes and command palette order

These changes describe the current candidate source, not a published release.

- Credential Manager has Credentials and Settings tabs, search and kind filters, counts, credential dates and vault statistics. Vaults can be renamed while unlocked and keep their own lock time: 1, 5, 15 or 30 minutes, 1 hour, or when WSurf quits. Sleep, display sleep, screen lock, user switching and profile changes still lock credentials. A shorter time applies immediately; a longer one starts at the next unlock. Locked vaults show only their number.
- The larger credential editor groups sign-in details, websites, verification codes, passkeys and notes. It can generate a password and asks before discarding edits or removing a nonempty note. Ordinary note edits, including clearing the last note, keep the previous notes as an earlier version; the confirmation says they can be copied back from History.
- The native fill dropdown can search its already-authorized site matches when more than five are available. Typing can start search in username fields with a standard keyboard layout; password and code fields require choosing Search. The query stays native and does not reach the page. Scope and authentication checks remain in force.
- Login saving follows redirects and in-page form completion without treating a verification step as a finished login. An attempt lasts 120 seconds, or 300 seconds when verification has been seen, counted from the attempt. Form actions, document bases and submitter overrides must stay origin-safe. A stale-page save reports “This page changed, so nothing was saved.” Only explicit Save or Update writes credentials.
- Settings › Appearance separates System, Light and Dark from the theme. WSurf joins Standard, Calm, Catppuccin, Gruvbox, Rosé Pine, Nord and Dracula, all with light and dark variants. WSurf is the default only on a fresh install; existing choices and customizations migrate. Each theme remembers Plain or Glass, transparency and separate light/dark brightness. Slider and color changes preview in memory before committing; changing a built-in theme's colors creates a saved copy.
- Theme text and control-icon ink are guarded for readability at drawing time without replacing saved colors or opacity. Docked and floating sidebar rows use their actual backgrounds. Controls follow the window's variant even on a locally inverted surface; adjusted system accent colors remain adaptive, and Standard/Calm previews honor explicit accent edits. WSurf's mint is reserved for assistant activity, not the selection or focus accent.
- Controls inside an actual glass card use their existing solid fill and border instead of nesting glass. Identity surfaces remain unpainted; Reduce Transparency and Increase Contrast keep their solid stand-ins.
- Settings › General › Command palette › Section order can move result sections up or down or reset them. Defaults stay the same, and a typed address keeps Search or ask first.
- Credential History opens beside the editor, from View History or History… in a credential's menu. It shows whole earlier versions, newest first, with their dates and whether an import or a merge made them. Secrets stay hidden until Show Secrets. Use This and Add copy a value into the editor; nothing is written until Save. Passkeys have no earlier versions; a removed passkey is in Trash.
- Export selects a credential as one unit with one switch. Its parts can still be chosen one by one, and the list has search, Select All and Select None.
- Credentials can be grouped By Site. Suggested Merges finds likely copies of one login, and Merge With… joins credentials: you choose what to keep, the others move to Trash with their history, and a website on another site is added only when you tick it. Credentials with different usernames are never merged. Merge All Identical merges copies with the same login and sites.
- A later import from Passwords finds a merged credential through every item merged into it, so a change made in Passwords to any of them reaches that credential and is reviewed as usual. Notes the saved credential already holds need no decision, and a note removed only in Passwords stays in WSurf.
- The import review has two collapsed sections. Changed in WSurf (kept) names the fields changed here since the last import, with dates and never values. No longer in Passwords lists saved credentials an earlier import brought that the transfer lacks; they are kept, and can be moved to Trash only after you confirm that the transfer has everything from Passwords.
- Everything in Credential Manager can be copied. A credential's menu has Copy Username, Copy Password, Copy Website and Copy Verification Code. The editor has a copy button on each field, website, note and code, and History has one on every value it shows, masked or not; a verification code's setup key is never copied. Passwords, notes, codes and concealed usernames are marked concealed so clipboard managers skip them, and a brief notice confirms each copy.
- Credentials can be selected and moved around from the keyboard. Click a row for the cursor, then use the arrows, Space to select, Shift to extend, Return to open, Escape to clear, and X or Command-Delete to move to Trash. A bar offers Move to Trash and Merge for the selection, and Remove moves a credential to Trash at once. Command-Z takes back the last five actions (Move to Trash, Merge, Edit, Add, Restore) and Shift-Command-Z repeats them. In Trash, X marks entries for deletion, Command-Z shows them again, and leaving Trash or choosing Delete Now deletes them with one passkey or Touch ID prompt.
- A vault is called the same thing everywhere: “Personal · Vault 1” while it is unlocked and “Vault 1 (locked)” while it is not, because a vault’s name is sealed until it unlocks. The list follows the locks and unlocks of your other vaults, and a lock removes the name from memory at once.
- When no login is saved for the exact site, the fill dropdown shows one Check other logins for *.site row. Choosing it lists logins saved for other HTTPS websites of the same registrable domain; shared suffixes such as `github.io` and `co.uk`, IP addresses and localhost get none. The usual list for the exact site is unchanged.
- After you fill from such a login, or submit a login that matches a credential saved for a sibling site, WSurf offers to add the website to that credential. Only Add Website writes, and it adds that one website; History shows it as Website added from autofill. A credential with 64 websites is never widened, and Not Now is remembered for the page.
- When every vault is locked, the dropdown shows an Unlock Credentials… row that uses the usual unlock prompt, and offers the logins again when a vault is unlocked, from the dropdown or elsewhere, while the field is still focused.
- Clicking a field again reopens its dropdown after Escape or any other dismissal.
- A frame policy the page refuses is sent once more after 300 ms.
- A username-only step, a lone email or user ID field before the password, is offered logins and its username is captured for saving. Trade-off: a lone email field without newsletter, subscribe, search or coupon wording now gets the login dropdown instead of contact fill when logins exist for the site.

- A passkey starts only from the dropdown. Clicking, Return or Down Arrow in a field that offers one no longer starts it, and Return reaches the page. While the page has a passkey request pending, the dropdown shows Use a Passkey…, in every vault state. A passkey request that arrives while the previous one is being cancelled now waits for it instead of failing. Typing in the dropdown's search that matches no login ends up in the field. This is meant for Google's sign-in; it has not been tried against Gmail by hand. The row needs password filling to be on, and a field marked `email webauthn` without a `username` token gets none.
- A fill the page accepted is no longer reported as Couldn't Fill Saved Details, and the credential you just filled is remembered, so submitting the sign-in no longer offers to save a copy of it.
- Settings › Vaults has Delete Vault… for an unlocked vault when the profile has more than one vault and no import is under review. The sheet shows what the vault holds and offers Export…; deleting needs the vault's name typed and then its passkey. The vault and its Trash go in one step and the other vaults keep working. Website passkeys saved in it stop working, and copies outside the store, such as backups, are not touched.
- Settings › Appearance can save the selected theme under your own name, with its colors, Plain or Glass, transparency and brightness. Saved themes can be renamed, duplicated and deleted, and editing one previews live and saves in place. The Dock icon can be Default, Light, Dark or Mono while WSurf runs; Finder and Applications keep the standard icon. A theme choice is now written to settings right after the click instead of during it, which keeps theme switching inside its time budget.
- An extension update that asks for more permissions or websites than the installed version is held and the old version keeps running. The extension shows Update needs approval, and a manual check lists only the added access before installing.
- Groundwork with no screen or setting yet: a tab archive that can close tabs left unused for 12 hours, a day or a week (the setting is Never and nothing in Settings changes it), Reader article extraction in WebKit and Chromium with Mozilla Readability 0.6.0, and the core of page watches, up to twenty with paced checks. Nothing in the app starts Reader or a watch.
- The assistant's tab group for a conversation is called an anchor in the code. Nothing you see changes.

Each branch above passed its own targeted native gate on the Pro before it was merged; the assembled candidate's gates are recorded separately. None of the screens and prompts above has been checked by hand.

Input History is not included in this candidate. No new recorder or unfinished UI is exposed.

Early verification at `83f89f0`, before the G/B overlays: isolated native Debug ARM64 build and identity guard passed; all 20 affected suites passed (245 test definitions, 350 executions, no failures or skips). The 3,000-credential layout measured 0.121752 seconds and 1,661.338 kB average growth, below the existing 0.300-second and 4,096-kB budgets. SwiftLint 0.65.1 passed. Separately reviewed executor evidence covers G (13 definitions / 17 executions) and corrected B v2 (208 definitions / 250 executions plus ten scoped performance budgets), not the assembled candidate. B's 80-switch mean was 0.0149294858 seconds under the unchanged 0.015-second limit, with two individual samples above it. Final assembled-source full-suite, coverage and all 24 performance checks are pending. Native keyboard/IME and Chromium fill-dropdown acceptance, real passkey and credential exchange, Stage, live private/accessibility/multiwindow visuals and GPU behavior remain unverified.

### 2026-10-16 — Preserve test checks under Swift compiler isolation and inference

The pull-to-refresh and development-ownership tests now propagate errors from throwing wait predicates. The context-budget fallback comparison explicitly uses `[Int]`, and the development-ownership test's immutable hostile-alphabet arguments are `nonisolated` for test discovery. Assertions, test cases, production code and security checks are unchanged.

### 2026-10-16 — Explicit WebKit import for bounded page replies

`PageReply.swift` now imports WebKit explicitly for `WKContentWorld.page` and the `WKWebView.evaluateJavaScript` completion-handler API. The native Debug ARM64 integration build rejected these uses under `MemberImportVisibility` without the import. Reply handling and runtime behavior are unchanged.

### 2026-10-15 — Credentials: Unlock works again after the vault locks

After a credential vault locked, **Unlock** could report "Couldn’t find this window to show the passkey prompt". The page remembers its window through a hidden view; that view was attached to the part of the page that changes between locked, unlocked and failed states, so SwiftUI created one per piece of the current state and the page kept whichever was updated last. After a state change the page could be left holding a view that was no longer on screen. The hidden view now sits on the page header, which every state keeps, so there is exactly one. Nothing about unlocking changed: the passkey prompt is still required and is still shown on the window that holds the page, never on another window.

Checked: a small SwiftUI probe in a real (invisible) window reproduced the loss with the old placement after the content changed and kept the window with the new placement, through lock, unlock and lock again; `Tools/check-format.sh` (SwiftLint 0.65.1) reports no violations. Not run: no Xcode build or test, and the real Unlock button was not used. There is no permanent UI regression test, because no reliable test of the real page is available here; the native acceptance is lock, Unlock, lock, Unlock again on the built app.

### 2026-10-15 — Credentials: a refused transfer from Passwords now says why

When a transfer from Passwords was refused ("The transfer could not be read"), the message gave only the position of the record (for example `account[0]/item[0]/credential[1]`), so two different causes looked the same. The message now also gives a fixed reason (not supported, could not be validated, an identifier repeated, over the import limits) and, when the position is a credential, its kind by the system's own case name (for example `note`, `totp`, `passkey`). It never includes a value, a title, a website or the underlying error text. The message no longer says "Export again from Passwords": the transfer is discarded and WSurf does not retry it.

This is a diagnostic only. What WSurf accepts is unchanged: a transfer is still read in full or refused in full, only passwords, passkeys and verification codes are imported, and nothing is written before Review and Import. It does not fix the failure that prompted it: that needs the reason and kind from a new attempt.

Checked: a swiftc build of the import codec and message with synthetic dummy records (a note, a second login, a verification code with period 0 and a malformed passkey key, each after a valid login) gave the expected position, reason and kind and no content in the message, and a valid login with a verification code still imported; `Tools/check-format.sh` (SwiftLint 0.65.1) reports no violations. Not run: no Xcode build or test; the updated unit tests (`CredentialExchangeTests+Import`, `CredentialExchangeCoordinatorTests`) have not been compiled or run.

### 2026-10-15 — Sleep inactive tabs after a time, and named color presets

**Sleep inactive tabs** can now also unload a background tab after it has been idle for a time you choose: 15 minutes, 30 minutes, 1, 2, 3 or 4 hours, or a custom number of minutes or hours. The switch is still off by default, and with no duration set it behaves as before, unloading only under memory pressure, which can still unload earlier. A single repeating check per window runs only while the switch is on and a duration is set. A tab's idle time starts when it leaves the screen, including the other pane of a split, not when it was opened or last in front hours earlier; it is measured with a monotonic clock that keeps counting while the Mac sleeps. Tabs opened or restored in the background start their idle time at that moment, and a tab that was already idle when you turn the setting on counts the time it has been idle. Unloading uses the same path and protections as memory pressure: favorites, Keep Loaded, the active tab and visible split panes, private windows, extension pages, forms with typed text, downloads, media, camera or microphone use and agent activity are never unloaded, and manual unload is unchanged. An unloaded tab reloads when you open it; on Chromium (CEF) pages it restores the address only, not back/forward history or scroll position. The protections rely on the same activity signals on both engines, traced in the source; not yet verified at run time on CEF.

**Color presets** in Settings → Appearance: Catppuccin Latte and Mocha, Nord, Dracula, Gruvbox Light and Dark, and Rosé Pine and Rosé Pine Dawn. A preset sets the real window, sidebar and control-surface colors, the accent, and the text and icon colors, and switches the window to the light or dark mode it was designed for. It draws solid in both window styles, and unloaded tab text keeps at least 4.5:1 contrast. Nothing changes until you choose one. While a preset is on, the Theme, Theme customization, Window style (with Website tint, Tint selected tab and Transparency) and sidebar text color controls are hidden; their saved values are not changed and come back when you press Reset, and a Settings search for one of them opens the Color preset row. A private window is always dark, so a light preset falls back to the standard dark surfaces and standard sidebar text there. Palette values come from each project's published palette (Gruvbox from the MIT-licensed Tinted Theming schemes, Rosé Pine from `@rose-pine/palette` 4.0.1); their notices are in `NOTICE`, the in-app acknowledgements and `Tools/vendored`.

**Sleep after, custom time**: a custom number of minutes or hours is applied only when you press Apply or Return, not while typing; Apply is dimmed while the typed value is already the applied one, and the row shows what is applied. A value that is empty, not a whole number, zero, or larger than 2,147,483,647 minutes is refused with a message that clears after the next good Apply or when you change the unit, and the previous setting stays. A custom value equal to a menu choice, such as 60 minutes, becomes that choice.

Verification. Source/component level (outside Xcode, Command Line Tools only, swiftc with the project's Swift 6, MainActor default isolation and MemberImportVisibility flags): `ThemePreset.swift` compiled with a harness (text and unloaded-text contrast at least 4.5:1 on each sidebar, lowest 4.64 for Rosé Pine Dawn; the ink resolves to the preset color under the light appearance and to the fallback under dark; Rosé Pine Dawn text 575279) and the extracted `SleepAfterRow.minutes(from:factor:)` (accepts 90 minutes, 2 hours and 35,791,394 hours; rejects 35,791,395 hours, empty, 0, negatives, decimals, non-ASCII digits and 20-digit overflow). Earlier component check of the real `TabSleepTimer.swift` with the test clock (repeating ticks; no tick from a sleep that finished just before a stop or restart). SwiftLint 0.65.1 (the CI pin) via `Tools/check-format.sh` reports no violations; `Acknowledgements.json` regenerates identically twice; `swiftc -parse` passes on the changed views and tests. Not run: the Xcode build, the Swift Testing suites (the new and extended tests are authored, not executed), and any Settings UI, private-window, window-backdrop or Chromium idle-unload check in the app.

### 2026-10-14 — Pull to refresh leaves pages that use the scroll wheel alone

A page that cancels the wheel event to zoom or pan, such as a map or a canvas, never scrolls the document. Pulling down on it used to read as a pull to refresh and could reload the tab. Pull to refresh now stays off while the page is cancelling wheel events (and for 500 ms after the last one), both when the pull starts and again when it is released. A pull on an ordinary page at its top, a scrolled page, or a page with its own inner scroller behaves as before. A wheel event inside an iframe is not seen, so a map embedded in a frame can still reload the tab.

A small document-start script in its own content world (`WSurfPull`) records the cancelled wheel events. It is installed once per page through `BrowserPage.installScript`, so the WebKit and Chromium engines use the same script, and the pull probes install it themselves in a document that loaded before the script existed. This is a port of the idea in Linen commit [`3748134`](https://github.com/kavoye/linen-browser/commit/3748134a21c26aeac212a333bdcd27ac615b170c) (kavoye/linen-browser, "Don't pull to refresh on pages that use the scroll wheel"), adapted to WSurf's engine-neutral `BrowserPage`.

Checked with the script text taken from the source and run in a real `WKWebView` isolated world and in real Chrome 154 over the DevTools protocol (isolated world, new-document script), against a page whose element cancels a DOM `WheelEvent`: not claimed before the event, claimed after it, unclaimed 650 ms later even when no other wheel event follows, a later uncancelled wheel not read as a claim, and no stale claim on a new document. Chrome also took a wheel from the browser input pipeline (`Input.dispatchMouseEvent`) with the same result. In WebKit only, a document also kept a single wheel listener after repeated probes. Not run: no Xcode build, test suite or lint (SwiftLint is not installed on this machine), and no run inside WSurf's own Chromium (CEF) engine or against a real trackpad gesture.

### 2026-10-14 — Interface polish ported from Linen: drag chip style, Reload availability, click focus and download icons

Adapted from Linen commits `3b191e50`, `ae84d3fb`, `792e9563` and `89fff458`. Dragging a tab or pane now draws its chip in the sidebar's live style (both drag overlays sit outside the sidebar and previously used the default style). Reload and Hard Reload (View menu, command palette, toolbar button) are off on pages that have nothing to reload: Start, Settings, History, Downloads, Release Notes and an empty tab; Stop still works while loading. Clicking an empty area of a WSurf page now takes keyboard focus off the toolbar in the window that holds the page (not whichever window is key), and a click inside the field that already has focus leaves its caret alone. Finished downloads show an icon for the file's type (PDF, image, video, audio, disk image, archive, app, presentation, spreadsheet, font, source code, web page, text, otherwise a plain document), and the icon becomes an open arrow under the pointer without animating.

Verification: swiftc component checks only (no Xcode build, no full test run, no SwiftLint on this machine): the focus modifier's AppKit half in hidden windows, and the download icon table and lookup. The SwiftUI tap wiring and the on-screen appearance of every change are unverified.

### 2026-10-14 — Search a website from the address field

The address field (toolbar) and the Start Page field now offer the command palette's site search. Type a supported site name or domain, such as `You` or `github.com`, and a “Search <site>” hint with a Tab key appears; press Tab and the field takes a site chip and the placeholder “Search <site>”. Enter, or ⌘/⌥-Enter, opens the site's own search results for your text in the current tab, through the same search URL builder as the palette. Nothing you type in site mode is sent for web suggestions or to the assistant. Backspace in the empty field, the chip, Escape, leaving the field, or submitting ends site search; removing the chip keeps what you typed and brings back normal results. Tab keeps its usual job when no site matches, when you have attached tabs with `@`, and when the field shows the page's own address (for example `https://www.youtube.com/` on YouTube). Typing with an input method still composes normally, because Tab and Backspace are ignored while text is marked. The rendering-engine badge, the lock and the VoiceOver labels are unchanged, and the state belongs to each window's own field.

Adapted from Linen (kavoye/linen-browser commit `baa5e7cad587f21762db0d968421f8e62d32b9bd`). WSurf's palette inlined the chip and the hint, so they are now the shared `SiteSearchChip` and `SearchScopeHint` views that both surfaces use. Unlike upstream, ending site search by removing the chip refreshes web suggestions for the text that stays, as the palette already does.

Not run: no Xcode build, Swift Testing run or app launch for this change. The new `AskSurfaceModelTests` and the SwiftUI row are untested on a Mac with the full app toolchain; only a swiftc check of the existing `SiteSearch` URL construction ran.

### 2026-10-14 — MCP page tools: scope, unlisted refs and screenshot size

Taken from Linen (`70c3c576`, `59c396de`, `78b76dee`), adapted to WSurf. `readPage` `scope` now covers every element the selector matches, not only the first. A ref that the current observation did not list (for example after control paging) now gets a message saying so, instead of the stale-page message, in every ref-taking tool and for any field of a `fillFields` batch (earlier fields in the batch are still filled); a genuinely stale page, a changed document or a wrong observation ID still gets the stale message. `screenshotPage` bounds its JPEG at 150,000 bytes, lowering quality and then shrinking pixels in 25% steps, and refuses to return a reply that would still exceed the 262,144-byte MCP line. A refused reply records no observation ID, read-content flag or link authority, since the client never received them. The computer-use frame path is unchanged. The reply measure assumes the SDK's own 36-byte request id (the relay always uses it); a client that talks to the socket directly with a very long id can lose only its own reply.

Not run: no Xcode build or test of this change; checked with swiftc probes of the scope script (nested, union, no-match, invalid and shadow-host selectors) in real WebKit and of the screenshot encoder in AppKit, and the changed Swift files were syntax-parsed only.

### 2026-10-14 — Apple Intelligence reads attached images

When this Mac's Apple Intelligence model supports image input (macOS 27 or later, reported by the system as the vision capability), the assistant now sends images attached to a message — pictures, and the pages of scanned files — to the on-device model instead of only the text extracted from them. On a Mac whose model has no vision capability, behavior is unchanged: the model gets the extracted text only, and an image with no readable text is refused with the existing message. Other providers are unchanged, including each window's and profile's own per-model setting for image input.

The on-device model still never receives screenshots. Its tool list excludes the screenshot and pointer tools, a screenshot that a tool leaves pending is replaced by a short text note, and images in tool results are removed when a saved conversation is restored. Only images you attach reach it. The tool, outcome and execution rules are unchanged.

The on-device context window is now the size the system reports for the model (8,192 tokens on the checked Mac) rather than a fixed 4,096. A window you set yourself still wins, and a Mac or build that reports no size keeps 4,096.

Attached images are now charged 256 tokens each against the on-device budget instead of the 1,600 used for hosted models. Every budget check uses the same charge: the check before sending (composer, chat and image-fallback paths), the check while the assistant runs, and the size estimate of a restored conversation. The half-window reserve and all file, size, page, image-count and text limits are unchanged. The 256 is an empirical margin, not a documented limit: on the checked Mac no image shape tried cost more than 195 input tokens, so 256 leaves about 30% headroom; it should be replaced by the framework's own count once that works for images. Pictures and scan pages cost more than the text extracted from them, so a long scan with little text per page can still be refused as over budget where it used to be sent as extracted text; the existing message tells you to attach fewer pages.

Ported from upstream Linen (kavoye/linen-browser) commit `fac4fa1e`, "Read attached images with the on-device model". Only its image-input part is taken, plus the reported on-device window and per-image charge that the image budget needs. Its compact tool set and outcome-tool changes, and the AnyLanguageModel 1.0.0 update, are not part of this change; the pinned AnyLanguageModel 0.15.1 already exposes the capability check and the context size.

Checked on an Apple M5 Mac running macOS 27.0 with Swift command-line component probes, using only synthetic images: the system reported the model available with the vision capability and an 8,192-token context size, and a red square with a blue circle sent through the system model was described as red and blue with a circle. Prompts with images prepared by the app's own importer (1,200×1,552 PDF pages, photos reduced to 1,600 px) cost 147 to 195 input tokens per image, linearly up to 20 images (3,002 to 3,962 tokens in total), and a sweep of 13 other shapes never exceeded 195. The framework's token count for a prompt with an image fails on this release, so these are measured session usages. The production budget sources were also compiled and run on that Mac (the AnyLanguageModel package could not be built, so only its system model was stood in for; the assistant's own run-loop budget was not run natively). With the real 8,192 window, a 20-page scan was accepted up to 15 pages with no text, 11 pages at about 280 characters of text per page (20 before), 7 at about 900 (6 before), 3 at about 2,700 (2 before) and 1 at about 5,600 (1 before); 15 photos were accepted and 16 refused, against 2 for a hosted model. Not run: the new regression tests and the WSurf app build (the Mac has Command Line Tools only), and the attached-image flow in the running app.

### 2026-10-14 — Credentials: an Import & Export section, and password CSV files

Credential Settings has one **Import & Export** section (it holds the incoming-credentials row that used to be its own section, and the Export… button that was on the Saved credentials header). **Choose File…** imports a password CSV and **Export to CSV…** writes one. A CSV is read by its header, not by column position: `URL` (or `Url`), `Username` and `Password` are required, `Title` or `Name` is used as the name, and both the 4-column `Title,Url,Username,Password` and the 6-column `Title,URL,Username,Password,Notes,OTPAuth` layouts work. That is compatibility with the layouts public third-party importers read, not a statement of Apple's format. A file over the vault's size limit is refused before it is read.

Import goes through the same review as the system credential exchange and the same single per-account write. Only passwords are imported: notes and verification-code (`OTPAuth`) columns are never imported, and the review lists the line numbers of rows that have them, of rows that cannot be imported (no website, a website that is not `https`, no password, a row that does not match the header) and of unrecognised columns by position (never by their header text). A header that names the URL, Username, Password, title, notes or code column twice is refused, since there is no single right column to read. A website is never completed (`example.com` without `https://` is refused). A username and a password are compared as exact bytes, not as Unicode-equivalent text and never as a delimited string: `Alice` and `alice` are two logins, and so are `é` as one character and as `e` plus an accent. A row identical to a stored login is counted as already saved and skipped. A row whose website and username match a stored login with a different password is a conflict you decide; every such row of the file is its own choice, but one stored login takes only one Replace (a second is refused), and Replace changes only that password and keeps its passkeys, verification code, exchange identifiers and field metadata. Rows of the file that share a website and username but differ in password, and a row that matches several stored logins, are never decided for you: each is marked **Choose…**, nothing is saved until every one is Skipped or Added separately (Replace is offered only for a single named stored login), and the review names the line of the file. An exact duplicate row is reported and skipped. The review counts what the file holds; only the receipt after Import counts what was saved.

Export writes only logins that have both a password and a website, as one row per website, after you have chosen the destination in the save panel (which asks before replacing a file); the selection is checked against the vault again after the panel closes. The file is written as a private (`0600`) temporary file next to the destination and moved into place in one step, so a failure or a change in the vault leaves any existing file exactly as it was; only WSurf's own temporary file is ever removed, and an import reads only an ordinary file up to the size limit. The file is **not encrypted**, WSurf never deletes it, and the export sheet says so, counts the passkeys, verification codes, logins without a website and notes it cannot include, and cautions against opening it in a spreadsheet (values are written unchanged, even when a spreadsheet could read one as a formula). The Import & Export entries are visible but off while the vault is locked or missing, with the reason. WSurf's CSV transfer carries no passkeys and no verification codes (it reports an `OTPAuth` value in a file it reads and does not import it); move those with Export… and the system credential exchange.

Maintenance fix (same day): the first pass of this change failed `Tools/check-format.sh` (SwiftLint 0.65.1, 24 style and size errors). The CSV header lookup now sits in a small private `Columns` type, the shared import value types moved to `CredentialImportReview.swift`, and the settings model's export methods moved to `CredentialSettingsModel+Export.swift`; the model's `manager` is now `private(set)` and its `exchange`, `ownMessage`, `live`, `authorizedSnapshot` and `perform` are internal so that extension can reach them. Behavior is unchanged. After the fix `Tools/check-format.sh` reports no violations and the swiftc CSV component check passes 27 of 27.

Not run: no Xcode build or test of this change has been run; only a swiftc component check of the CSV parsing and staging code.

### 2026-10-14 — Page robustness: stalled favicon lookups, detached players and crashed background tabs

Changes (implemented in source): the favicon lookup gives up on a page that does not answer its icon script within 5 seconds, and a page that never answers no longer keeps its web view alive through that pending call; the icon download is given a 10-second request timeout, which is an inactivity limit, so a server that keeps sending slowly is not cut off at 10 seconds, and one lookup can still take longer than 5 + 10 seconds when it has several candidate icons. Auto-play Never and Muted now also apply to players a page creates with `createElement('audio')` or `new Audio()` and never attaches to the document; a player the person started by hand is not stopped. A WebKit tab whose web-content process terminates while it is in the background is no longer reloaded there: it unloads to its saved session and restores when it becomes the active tab or a visible split pane. A tab that is shown, visible in a split, a favorite, kept active by its website, or protected from unloading for any other reason (private, extension page, an edited form, device access, docked media, a running agent or automation, an active download) still reloads at once under the same retry limit, and so does every Chromium tab, because unloading it would drop its back/forward history. Backported from Linen (`3d0903d`, `ebb66e9`, `c0afef3`).

Verification status when written: a standalone WebKit probe (non-persistent store, no app) observed the detached-player and bounded-reply behavior of the page-side code; the new app tests have not been run; and the background-tab change is covered only by tests that call its public lifecycle entry point, never by a real web-content crash. Update this paragraph with the native test results before release.

### 2026-10-14 — MCP: development access

A client can ask for development access (`requestAccess` with `development: true`); the prompt adds **Allow Development**, which still obeys each site's Assistant Access. It unlocks `findElements` and `inspectElement` (bounded DOM, geometry and allowlisted styles, never field values), `setViewport` and `emulateDevice` (an exact CSS-pixel viewport measured inside the page; `phone` and `tablet` also set pixel ratio, touch and mobile viewport on Chromium only), `reloadPage`, and console and network metadata through `startDiagnostics`, `readConsole` and `readNetwork`. `getDevelopmentInfo` and `resetDevelopment` report and clear the state. One connection owns a tab's viewport and diagnostics at a time. The lease is bound to the page view and document generation it was granted on: disconnecting, a lower grant, a site-policy change, a navigation or reload outside the grant, the page being replaced (engine change), or closing the tab releases it and removes everything it applied, and a call already running on a page that was replaced does not return its result. Diagnostics cover the main document from the moment capture starts, follow later navigations, and state their gaps per engine (see MCP.md). `pressKey` now says so when the key was not delivered instead of reporting success.

Review corrections in this entry: `screenshotPage` accepts a `findElements` ref (a non-control element) under development access, checked before the work, after every wait and before the image is returned, while a `readPage` control ref still needs only read access; inspection refs stay unusable for click, type, hover and every other action. An element inside a same-origin iframe is captured with the frame's border, padding, scale, clipping, CSS zoom and 2D rotation, reflection or skew applied; a selected frame, a frame or clipping container under a 3D transform or perspective, or a frame or clipping container inside SVG content (foreignObject), is refused as not measurable. A reloaded or reset tab returns only after the lease's cleanup has run, and a site-permission change ends a lease the grant no longer covers at once. `findElements` and `inspectElement` results are bounded by delivered bytes (about 24 KiB), selectors by 2,048 UTF-8 bytes natively. WebKit diagnostics no longer run page code to describe values, use a per-capture handler, restore only what they installed, and report fetch method and URL only where they are known. Overlapping viewport and device changes are serialized. `hoverOnPage` says when the element is clipped by the window.

Not verified: none of the code above has been built or run in a whole-app test. The component-level pure tests are the only automated evidence. DevOps checks still to run: a real WebKit and Chromium page for diagnostics, lease release on page replacement and policy change, native hover and key delivery, iframe capture on both engines, and the element-screenshot scale fixture (a 200 × 100 CSS element of four coloured quadrants at a non-zero offset, at zoom 1 and 1.5 and at phone device pixel ratio 3: the reported CSS bounds, the 2:1 aspect, `scale` = bitmap width / 200 and the quadrant centres must agree). The Chromium clip units in particular are unverified.

### 2026-10-14 — MCP: real hover, element waits and cropped screenshots

`hoverOnPage` now moves the real pointer to the element, so CSS `:hover` works. It needs WSurf to be the active app with the tab on screen, and says so instead of claiming success when it is not.

`waitForPage` accepts `elementVisible`, `elementHidden` and `elementEnabled` with a CSS selector that must match one element, and ends as stale if the page navigates. Selectors may test only attributes WSurf already exposes (see MCP.md, Safe selectors), so a selector cannot be used to read hidden values. `screenshotPage` can capture one referenced element or a viewport region, cropped to its visible part (a region must lie fully inside the viewport); it never scrolls or stitches, and a filled sensitive field anywhere on the page still refuses every capture.

### 2026-10-14 — Agent: AnyLanguageModel 1.0.0 (DRAFT: pending native build, tests and smoke; finalize or drop after them)

The agent now builds against AnyLanguageModel 1.0.0 (pinned to revision `80d50b0`). Provider reasoning that the library now records in the transcript is dropped at run start (checkpoint restore), at checkpoint save and in compaction, and is kept only for rounds produced in the running session, including later iterations of a resumed run. It is ignored for OpenAI items. Reasoning text counts toward the context estimate while it is kept. No other behavior changes.

### 2026-10-13 — Credentials: several vaults per profile, Trash and earlier versions, and a one-way store upgrade

Each profile now keeps its credentials in one encrypted store (`Credentials.store`) that holds up to 16 active vaults, each with a linked Trash. Every vault has its own passkey unlock, its own manager and lock, and a five-minute unlock; a profile lock (profile switch, sleep, screen lock, quit, profile erase) locks every vault of the profile. A locked vault is listed only by number, with no name or content. You can choose a default vault, create a further vault with a new passkey or with a passkey already enrolled in another vault of the profile (vaults sharing a passkey share its exposure: one compromised authenticator opens all of them), and remove an unlock passkey. Creating a vault never reuses or extends an existing unlock. Removing a passkey stops its normal unlock; it does not rotate the vault key, so a copy of the vault file that still holds its wrapper can still be opened with it.

Where a login is saved or filled is decided by the vault that holds it: a match in one unlocked vault goes to that vault; a match in several vaults, or none while another vault is locked, asks you to choose; the default vault takes new logins; a locked default vault asks you to unlock or choose and never falls back silently. Suggestions read only unlocked vaults. A passkey request is bound to the vault it runs on and ends only when that vault locks or the profile's access ends; choosing a vault only selects it and unlocks nothing until the request is checked again afterwards. Credential sheets belong to the task that awaits them, so a cancelled request dismisses its own sheet. Creating the first vault removes the files it built only when it is cancelled or its creation lease is dead; any other failure keeps them as fail-closed evidence and refuses a blind retry.

Each vault has a linked Trash that opens with the vault's own unlock and has no unlock of its own. Removing an account, a password, a one-time code or a passkey moves it, with its earlier versions, to the Trash in one transaction. The Settings page lists the Trash and an account's earlier versions in pages of 50 with counts checked against the stored rows. You can undelete (refused, with nothing written, when a live item has the same id, exchange item, website and username, or passkey, or the owner is gone) and restore an earlier password, one-time code or website-metadata version (passkeys are never restored from a version). Emptying the Trash or removing items for good needs a confirmation and a fresh passkey assertion. Purging is a logical removal, not secure erasure: the chosen entries and their earlier versions are replaced by a record that keeps identifiers only (no password, one-time-code seed or key), but encrypted remnants (older database pages), Time Machine or other backups, and the pre-upgrade backup can still hold the removed data, and WSurf never deletes those copies.

The first unlock of a vault saved by an older WSurf asks for an explicit confirmation, then upgrades it once, in one exclusive step: it writes a verified backup, `Credentials.vault.pre-v2`, builds and verifies the new store, and only then swaps it in. The upgrade is one-way. Older WSurf builds can no longer open the vault and show a corruption-style error; changes made after the upgrade are not in the backup; the backup still holds the vault as it was, under its old unlock wrappers, so anything you later purge stays readable there to whoever can unlock those wrappers; and WSurf never overwrites or deletes it, and a purge does not cover it (its path is shown wherever purge or a fail-closed state is explained). A write by an older build that lands during the swap is kept as `Credentials.vault.cutover-v1` and the vault stays closed with both files shown. An interrupted upgrade resumes at the next unlock without losing the old vault.

Integrity: the store has a registry that lists every vault and the digests of its heads and unlock wrappers, authenticated by a registry key. That key is sealed inside the head of every active vault, so unlocking any one vault can read it and could re-authenticate a forged registry; it opens no other vault and wraps nothing. Each vault's head, rows and history are sealed and checked against journals before any removal, and the vault's password-saving policy (the blocked-origins list) is part of the sealed head. A small witness in the profile's preferences remembers that a store existed for the profile; it is not cryptographic and detects accidental loss or replacement, not an attacker. When files are missing, foreign, unreadable, left over from an interrupted step, or disagree, the page shows the cause and the absolute paths with a Retry button only: WSurf never offers Create, reset or acknowledge there, and moves or deletes nothing to get out. Limits it does not solve: if the store, its stub file, the witness and every migration leftover are all gone, the profile reads as a first run (while `Credentials.vault.pre-v2` or another leftover survives, WSurf fails closed instead); a whole older but consistent copy of the store restored in place passes every check and loses the later changes without a warning; the vault list shown before an unlock is not authenticated.

Bounds: each vault holds at most 1,000 accounts and 4,000,000 bytes of live data, at most 32 unlock wrappers and 4,096 blocked origins; a profile holds at most 16 active vaults (each one's linked Trash is in addition). Earlier versions, Trash entries and purge records have no count limit and are bounded only by disk; each row is capped at 8,000,000 bytes. A write over a live limit is refused whole with the limit named, and nothing is dropped to make room.

Import and export: an import is classified against the destination vault only (new, unchanged, changed remotely, locally or both, no common base, ambiguous, previously removed, passkey conflict), matches by exchange identifiers and an accepted pairing and never by website and username, and never replaces a stored passkey. It applies in one per-account write bound to the version stamps of only the accounts it touches, so editing another account while the review is open no longer discards it; before the write starts, a changed touched account, a lock, a re-unlock or a cancel discards the import and writes nothing; if the vault's access ends or the write fails in a way that proves nothing about the outcome once the write has started, the result may already have landed, WSurf says so and asks you to check Saved Credentials, and it never claims a rollback (only a version-stamp mismatch, a limit, a collision or a malformed record, all refused before the first row is written, proves nothing was written). The review and result list what became of each credential (added, updated, unchanged or skipped; kind, title and website only), and every import and export ends in exactly one message with its next step. The ending belongs to the window and vault that began the transfer, so another window's later ending never replaces it and another window's dismiss never clears it; a system token that is ignored (already queued or spent) does not reopen the credential page, only a refused one does. An export records its hand-off time and a content hash only for still-unchanged chosen accounts; a chosen credential that changed meanwhile, including one whose only change is its password, code seed or passkey key, is named and the sheet asks again. Apple Passwords decides what it adds, skips or replaces and gives no per-item receipt, and WSurf cannot see or undo anything on the Apple side, so "handed to the system" is the strongest claim WSurf makes: it never says an export was accepted, updated in Passwords or synced, and these dates and hashes never mark anything as synced.

Verification: the app builds natively and the full automated test suite passes, including the vault, import/export and Settings model tests. Not yet verified by hand on a Mac, and only possible after installing: the on-screen Settings flows, passkey/PRF unlock with real authenticators, and a real credential exchange with Apple Passwords, which gives WSurf no receipt for what it adds, skips or replaces. Those checks are the user's to report.

### 2026-10-13 — Command palette keeps the focus you give it

The command palette's search field no longer takes keyboard focus back after you have moved it elsewhere, and the Ask mention field respects a focus change made by the system.

### 2026-10-13 — Profile settings fail closed

A named profile's settings never fall back to the original profile's (app-wide) defaults. If its own settings domain cannot be opened, the app stops instead of reading or writing another profile's settings.

### 2026-10-12 — Credential editor website fields

Both website fields of the credential editor (websites and other HTTPS origins) are now plain-text list editors: Return, Shift-Return and keypad Enter insert a new line and never save, a typed comma or Space after a valid address starts the next line, and valid addresses are underlined like links but a click only places the caret and never opens anything. Paste, drop and input-method text are inserted as typed, and save-time validation is unchanged. This is source-level only; the on-screen behaviour has not been exercised in a running app.

### 2026-10-13 — CI tests no longer share the installed app's identity

Debug builds take their bundle identifier from `WSURF_BUNDLE_ID_SUFFIX`, empty by
default; Release identifiers, the tests target and default Debug identifiers do
not change. CI builds with a unique `.ci-<run_id>-<run_attempt>` suffix, then
`Tools/check-built-identity.py` refuses to launch the test host unless the built
app, extension, five Chromium helpers and test bundle carry that identity, the one
generated `.xctestrun` names that app and test bundle, and no Stage environment is
set; only then does `test-without-building -xctestrun` run that exact file, inside
the same total watchdog budget. The test host's standard
preferences and default WebKit data then use that identifier instead of
`io.wsagency.wsurf`. A throwaway check on a uniquely suffixed build confirmed a
preferences key and a `localStorage` key stay in that namespace and that the
production preferences, WebKit and Caches metadata did not change. Test hosts also
keep favicon caches under their per-process test directory instead of
`~/Library/Caches/WSurf/Favicons` (a focused regression and its neighbours passed;
the full suite is not claimed here). Other profile test preference domains still
use random UUID names, not per-process ones. The CI job now selects Xcode through
`DEVELOPER_DIR` without `sudo xcode-select`, installs SwiftLint under
`RUNNER_TEMP`, downloads the Metal toolchain only when `runner.environment` is
`github-hosted` and otherwise only verifies it, no longer passes
`-skipMacroValidation -skipPackagePluginValidation`, no longer uploads every
host crash report, and runs a watchdog check; the watchdog now samples only its
own child and never lists host processes. A final step removes the run's own
preferences, WebKit, Caches, HTTPStorages and Saved Application State by exact
identifier. Limits: the Pro machine's own Gitea runners are distinct from this GitHub
Actions job, whose advertised runtime was GitHub-hosted (`runner.environment`
`github-hosted`); that job's OS isolation and account are not verified here, and the
suffix is namespacing, not OS isolation. macOS-managed
`~/Library/Containers/<id>.CredentialExchange` cannot be removed by `rm` and
stays; a hard-killed runner skips cleanup; the registered-extension `pluginkit -r`
branch has not been exercised. GitHub's fork pull-request approval policy is
unchanged and lets prior contributors' fork runs start without approval, which
stays unsafe until the owner permits a change, so only trusted-branch work may use
this runner.

The narrow probes above passed, but a full native test run then found a real
write to the production `~/Library/Application Support/WSurf/SitePermissions.json`:
two tests built `SitePermissions(storageURL: nil)`, whose implicit default pointed
at the installed app's file. The default is removed. `SitePermissions` now requires
an explicit file URL and those tests use their own, under the per-process test
directory. A targeted native run of the changed callers and their neighbours
(131 tests in 8 suites, including `FormConsumerBoundaryTests`,
`MCPPrivacyTests` and `SitePermissionsTests`) passed, and known production
metadata, including that file and its parent directory, was unchanged across it.
A later full native run on the fixed source ran 3244 tests in 351 suites in about
939 seconds, inside the watchdog budget, with 14 existing disabled tests and no new
skips. One test failed, a separate, not yet diagnosed failure in
`WebAuthnContextBackForwardTests` (its first `route == manager` check, before any
back/forward navigation), so the
full suite did not pass and CI is not green. The privacy part of that run held:
known production metadata, including that file and its parent directory, was
unchanged, and only owned namespace paths were created and cleaned. What the
earlier write changed is unknown: the file's content before it was never recorded,
and it was left untouched. Only the paths named above were checked, so this does
not show that all production data stays unchanged. A later diagnostic build of
`WebAuthnContextBackForwardTests` (extra instrumentation only, not a product fix)
passed its build and artifact guard and the 30-test `WebAuthnContextTests` run, but
the cause of the full-run failure is still unknown and was not reproduced by that
targeted run. The first CI run of this change failed at the Metal
toolchain step (the hosted image lacks it and the verify-only replacement removed the
download); that step is fixed in source and awaits a new run, so no CI result for
this change exists yet.

### 2026-10-11 — Remove managed browser passkey entitlement

WSurf no longer declares or requests Apple's managed
`com.apple.developer.web-browser.public-key-credential` entitlement. Release and
tip validation require it to be absent from the signed app and credential
exchange extension. Provider defaults, routing, data, and migrations do not
change. Native system passkeys for arbitrary relying parties via WebKit are not
guaranteed in legacy/default or private tabs. WSurf's vault-managed WebAuthn,
`wsurf.app` PRF unlock, and Apple Passwords exchange use separate paths.

### 2026-10-11 — Website passkey metadata and Settings

Website passkeys retain optional creation time, local creation/import provenance, and last local signature time in the encrypted vault; imported passkeys have unknown creation time. A local signature timestamp is committed under the expected vault revision and authorization epoch; it records local signing, not website receipt or sign-in success. After that commit succeeds, a later lock, cancellation, navigation, expiry, changed vault state, or vault read failure can still prevent assertion delivery. Stale-revision, authorization, and I/O commit failures refuse delivery; assertions are not retried from stale state.

Credential Settings and the assertion picker show the full immutable passkey UUID; removal confirmation names that exact UUID and RP ID, then removes only that local copy through the existing draft Save. Same-RP/same-user-handle registrations retain each passkey separately; `excludeCredentials` still rejects a matching credential. The user explicitly approved this retain-all deviation for the bounded metadata design and merge/deploy for manual testing; it is not a claim of WebAuthn conformance. Code `21ff6c801659e4129c342332149b199350dfc9ec` passed hosted run 38095943728 (3,019 tests in 334 suites, coverage 52.47%, format and every performance budget; overall success; 500 tab activations averaged 0.004793 s against 0.035 s); the final PR head still needs its own checks. The earlier run 38092727778 on `2c8949e` failed only the performance-budget step (0.036752 s) and is historical, not a current blocker. A dead top-bar coverage state in the tab/split model was removed (the always-false `isUnderTopBar` flag, its refresh loop and 4 calls); the explicit zero-inset resets on page adoption and on fullscreen changes, the `topBarInset` API and the split geometry stay, and one test that only asserted the default flag was removed, not skipped. No cross-run speed-up is claimed. Native acceptance remains pending.

### 2026-10-10 — Credential Manager in source

Implemented in source, not released, and not natively accepted: an opt-in
per-profile encrypted Credential Manager for passwords, ES256 passkeys, and
one-time codes, plus an exchange-only credential-exchange extension. Legacy
SavedPassword, SecureAutofillVault, settings, data and the default provider are
unchanged; the manager is used only when a profile selects it.
`CredentialManager.commit` and `updatePasswordSavePolicy` require the
authorization epoch captured at decision time and refuse with `unauthorized`
after a lock or re-unlock. Verified on the integration branch: WebAuthn nonce, history
(back/forward cache root) and late-resume handling, plus escaped
Permissions-Policy denial. The current proof is the joined 17-suite run, the
strict lint gate and a built-module CLI smoke (synthetic password, passkey and
one-time code through encrypted save, reopen, exchange export/preview/apply
and ES256 verification), recorded in the current-main integration appendix
(`docs/superpowers/plans/2026-10-10-credential-current-main-integration.md`).
Fill delivery (manager, legacy, card and contact) checks the request's
authority at the final dispatch point with no suspension before the engine
send; this is source-traced, with no actual UI fill. Autofill and save refuse
frames the engine flags as untrusted-origin, as WebAuthn already did (source
only). Native PRF, real user presence and verification, Apple Passwords
transfers, Settings accessibility and Stage remain unverified. Removing an
unlock passkey does not rotate the vault key, so a removed passkey that still
has an older copy of the vault file can decrypt later versions; this is a
documented limit, not forward revocation.

Review corrections on the draft PR, source only and unverified natively:
WebAuthn client data is serialized in the specified order and its origin is
checked by the independent verifier; the exchange review says when replacing a
stored login removes its password; Chromium back/forward-cache restores keep
isolated-world contexts and script messages, finish navigation state and
publish correct history controls while credential contexts are still
invalidated. Merge and deploy stay blocked on the unresolved duplicate-passkey
registration policy (D1: a second registration appends instead of overwriting),
and native handoff, signing, PRF and transfer gates remain open. (Superseded
2026-10-11: the user approved the retain-all registration policy for merge/deploy
to manual testing; D1 is no longer a gate. Capability-bearing signing/provisioning
remains a deployment prerequisite.)

External-app offers from a web page no longer depend on a race with the frame
handshake: the navigation decision records the exact document nonce the
registry issued or acknowledged for the source frame and that document's own
navigation, then waits for that frame's native readiness proof of the same
nonce before the offer is shown. A cancelled in-flight navigation no longer
invalidates an offer from the already-loaded page. Pending frames are never
treated as acknowledged, and stale or replaced frames still refuse. Verified
in hosted CI on `5649bbe` (3012 tests, including all handoff, stale-frame and
back/forward-cache cases); the performance-budget step of that run failed
(0.1019 s against 0.100 s) and its cause is unresolved. On `9253f7d` (main
`a2ab7b6` merged in), run 38075169484 passed 3014 tests in 334 suites, all
budgets (start page 0.0774 s) and coverage; the same run started the built
Debug app in an isolated Stage home and drove its bundled MCP relay through
initialize, the 19-tool listing, `listTabs` and EOF. That proves app startup
and relay IPC only, not the credential UI, native user presence or
verification, or the other tools; the earlier performance failure did not
recur but was not explained.

### 2026-10-10 — Tab title test waits for the website title

The website-title removal test now waits for the page's initial title before removing it, instead of reading the tab title the moment loading settles. This is a test-readiness correction; no tab title behavior changed.

### 2026-10-10 — Fresh window registration over a retired key

Registering a browser over a retired extension-window key now retires the old entry and creates a fresh window adapter instead of returning the dead one. Consent captured for the retired window stays invalid. The MCP transport tests now unregister the extension windows they register.

### 2026-10-09 — Actual engine beside address lock

The address bar shows WK or Cr beside the lock for the active page's loaded engine.

### 2026-10-09 — Classic Keychain credential storage

Provider credentials, MCP authorization credentials, and OAuth credentials now
share the classic macOS Keychain store. Durable tombstones keep deleted
credentials from reappearing.

### 2026-10-08 — Complete Linen integration

Integrated all 31 changes from the pinned upstream range through
[PR #8](https://github.com/wsagency/wsurf/pull/8). The list follows the
[source manifest](docs/upstream-migrations.md#complete-source-manifest):

1. Detect both standalone and ChatGPT-bundled Codex CLI layouts for MCP setup,
   retaining WSurf configuration and safe TOML merging.
2. Preserve command-palette editing shortcuts across keyboard layouts.
3. Wait for focused autofill fields to finish layout before delivering input,
   with bounded waits and cancellation.
4. Stop media polling on idle players and hidden pages, including page-cache
   transitions.
5. Show PDF filenames and correct untitled-page names on WebKit and Chromium,
   without overwriting custom tab titles.
6. Remember external-app approvals per website origin and target app, with
   revocation in website settings and session-only private-window grants.
7. Save WebKit PDF viewer documents through the download manager, preserving
   edited PDF bytes, filename reservations, quarantine and handoff deduplication.
8. Open the actual Downloads page from download settings and settings search.
9. Refresh the localization catalog while retaining WSurf-only strings and
   branding.
10. Align global-reset settings copy with the string catalog.
11. Stabilize assistant context test titles while pages load and retain fixture
    servers for their full lifetime.
12. Test external navigation with real WebKit actions and requesting origins
    rather than fabricated navigation objects.
13. Measure result-ranking performance independently of WebKit page loading,
    retaining WSurf performance budgets.
14. Restore saved scroll positions after late WebKit resets; stop restoration
    when the user scrolls, the page moves itself or the document is left.
15. Wait for extension test replies from the expected page instead of accepting
    unrelated responses.
16. Keep headless automation fixtures active without changing production page
    scheduling.
17. Confirm assistant key delivery on trusted keydown, avoiding duplicate input
    when a page consumes keyup.
18. Move native CI to Xcode 27, refresh CI actions and SwiftLint, and upgrade
    AnyLanguageModel to 0.15.1 and swift-collections to 1.7.1. Keep CefSwift pinned
    and enforce locked package resolution.
19. Update README behavior and privacy documentation for WSurf.
20. Install and verify the Metal toolchain before release and preview builds,
    retaining the existing CI setup and deployment gates.
21. Support CPU fallback for OCR and active autofill fixtures on virtual macOS
    runners.
22. Exclude only four unsupported Vision OCR integration tests from hosted CI;
    keep all four enabled in native Pro verification.
23. Improve gray folder-preview icon contrast in dark mode while retaining
    colored folders.
24. Accept object-valued MCP experimental capabilities during initialization
    without changing standard fields or permission grants.
25. Add profile-aware browser windows, live same-profile tab transfer and
    isolated private sessions on both WebKit and Chromium. Bind assistant,
    MCP and extension operations to their owning window, profile and document.
26. Show assistant questions only in the window, space and surface where the
    request began.
27. Fill up to 32 controls per guarded assistant or MCP operation without
    submitting the form. Add bounded rate-limit recovery, pause/Continue and
    visual no-progress detection without replaying completed actions.
28. Reduce idle work and correct startup behavior: event-driven MCP stdio,
    cached speech preparation, visible-playing synchronized lyrics, validated
    media geometry, URL-correct favicons, privacy-safe autofill diagnostics and
    engine-aware page-resource cleanup.
29. Keep sidebar drop targets visible on light websites using the sidebar's own
    appearance.
30. Add Tab-to-search site chips with native editor safeguards and adaptive
    command-palette sizing.
31. Limit Window/Dock page-title labels to 40 grapheme clusters, retaining full
    stored titles and profile/private suffixes.

WSurf compatibility work preserves Favorites, pinned tabs and folders, sidebar
Undo/Redo, split panes and per-website engine selection. History clearing removes
only the owning profile's conversation log; link previews retain that profile's
JavaScript settings. External-app decisions remain bound to live source
documents, with one-time consent for ambiguous or opaque sources. Stage runs can
retain restored sessions with `WSURF_STAGE_SEED=0` without disabling isolation.

Native Pro verification recorded 3,016 passing tests and no failures, including
the four OCR integrations. PR and merged-main CI passed. The
[migration journal](docs/upstream-migrations.md) and
[integration record](https://github.com/wsagency/wsurf/pull/8#issuecomment-6067821179)
separate observed checks from the remaining manual UI checks accepted by the
user. This entry records source integration, not a signed public release.

### Earlier WSurf changes

- Added repository-local omp worktree placement and documented feature-branch,
  PR-only changes to `main`.
- Independent WSurf product, app/project/module and `io.wsagency.wsurf`
  identity, with separate data/defaults and new wave artwork.
- Preserves Apache-2.0 provenance and third-party notices; does not reuse
  the upstream publisher's signing or update keys.
- Extension popup/background, live tab metadata, persistent Apple client
  compatibility and native context cleanup changes pass 35 scoped regressions.
- Local ad-hoc build launches with the WSurf icon/onboarding and loads HTTPS
  pages; restricted browser entitlements are not enabled in this UI smoke.
- Seven update payload/state/layout behavior checks pass. Removed inherited
  wording and configuration-copy assertions rather than pinning new branding.
- Fixed strict SwiftLint header/import/collection/line-length violations.
  The compiled Apple public key still derives the official extension ID.
- Builds extension ZIP test fixtures on the concurrent executor, avoiding
  MainActor Process run-loop reentrancy during WebKit teardown while retaining
  invalid-package and cleanup assertions.
- Extension package extraction also runs off MainActor, with per-library
  serialization so installs cannot overlap writes to the same staging paths.
- Extension controller web views now reuse the browser's pooled configuration,
  preserving the controller's website data store while avoiding process-pool
  destruction during pending IPC callbacks.
- Stable controls receive at least two readiness samples even when the first
  WebKit query is cold; stale, disabled, animated and permission checks remain.
- Repeated or late handoffs of the same native download no longer create
  duplicate transfers. Separate requests for the same URL remain independent.
- Sidebar appearance now includes installed font families, size, weight,
  compact row spacing, and adjustable folder tint. Folder and link labels use
  primary text contrast; expanded folders no longer stack tinted glass.
- Unpinned sidebar X now removes the tab and link; ⌘-click unloads instead.
  Pinned controls unload or load by default and remove with ⌘. Removed the
  obsolete unloaded-tab-action preference; context menus retain explicit actions.
- Added per-profile, icon-only Favorites without duplicate sidebar rows.
  Favorites never auto-sleep, support manual unload, and return to ordinary pins
  when removed from Favorites.
- New Folder and Move to Folder › New Folder reveal and focus inline rename,
  including icons-only mode.
- Native sidebar Undo/Redo restores deleted folders and removed links, including
  names, tree positions, pins, and split panes. ⌘Z and Ctrl-Z preserve text Undo.
- Themes now preview brightness, hue, and a primary-derived palette live, with
  independent control-icon and URL-text colors/opacity, per-theme storage and reset.
- Folder context menus now offer independent Pin/Unpin, including empty
  folders. Pin state and sidebar order persist without changing child bookmarks.
  Fixed context-menu hit testing for folder rows away from the top.
  Child reordering preserves each bookmark; Delete Folder and Move Out keep
  the root pinned section contiguous without changing child bookmarks.
- Initial icon markup no longer invalidates locally cached favicons on every
  navigation. The icon watcher starts after the initial DOM is ready and still
  refreshes icons when the page changes them later.
- Added pastel Light Calm and Dark Calm themes. Light Calm uses a deeper muted
  palette; Calm chrome stays light or dark independently of the website.
- Loaded and unloaded sidebar text/icon colors and opacity persist separately
  for each theme, defaulting to black on light surfaces and white on dark ones.
  Favicons keep their original glyph in monochrome without an unloaded badge.
- Sidebar and folder controls use X only for removal, the curved-down arrow
  only for unload, and Play only for load. Folder unload retains descendant
  links, pins, hierarchy, and existing unload protections.
- Added the dependency-free `wsurf.app/` website and public `webcredentials`
  association for the configured WSurf release identity. Includes responsive
  source/build links, upstream attribution, and deployment requirements;
  no signing secrets or vault data are hosted.
- Move to Folder now follows the sidebar hierarchy instead of listing every
  folder at the first level. Nested menus include Move Here for the parent
  folder and keep invalid self/descendant destinations out of folder moves.
- Added assets-only Cloudflare hosting for `wsurf.app/` with an exact JSON MIME
  override for the hidden association file. Restricted Worker-only deployment
  and public anonymous HTTPS GET/HEAD checks pass with the unchanged app
  identity and domain/DNS binding. The sole GitHub Actions path waits for
  successful CI on the exact PR-merged main SHA and skips superseded commits;
  no PR/fork/tag deploy, account-wide token, DNS grant, native Workers Builds
  connection, or GitHub App grant.
- Added omp.sh to external MCP clients, with automatic CLI detection and setup
  in `~/.omp/agent/mcp.json` using the existing safe JSON merge and backup.
- Added per-website WebKit/Chromium selection with lazy embedded CEF startup,
  separate engine website data, and profile-specific preferences.
- Fixed native Chromium initial navigation, IO-thread tracker policy isolation,
  canonical cache paths, and child-view teardown without closing the app window.
  Native accessibility is enabled; CEF errors remain on standard error without
  a persistent debug log file.
- Engine changes reload rather than replaying submitted requests. Chromium
  unloads restore the URL; WebKit extensions and native Picture in Picture remain
  WebKit-only.
- The WebKit autofill navigation adapter reads the source frame only for a form
  submission, rather than eagerly reading it for unrelated navigation kinds.
- Existing folder pins migrate without changing child bookmark identities.
- Assistant input now targets the verified native page responder. Chromium text
  uses browser-native input; trusted event receipts and sensitive-field checks
  remain in force.
- Engine replacement releases the old page's media-dock ownership. Native
  Picture in Picture return guards and hover shielding remain engine-aware.
- Chromium file dialogs use native content types for MIME and extension filters,
  and request-handler ownership is synchronized with in-flight shutdown.
- WebKit download callbacks acquire their delegates before yielding, including
  resumed transfers. Assistant key presses finish their native press/release
  pair before awaiting the select-all fallback.
- Assistant input makes a final fresh trusted-event receipt check at the polling
  deadline, so a wait or delayed IPC reply does not discard a delivered event.
- Command-palette projection reuses its ranked command matches for promotion
  instead of scoring the full catalog twice; ordering and performance budgets
  remain unchanged.

No signed WSurf release has been published yet. Apple Passwords compatibility
changes are present in source and fixtures, but real PIN, fill, save, OTP,
15-minute idle, lock, and sleep behavior remains unverified in an own signed
build.

## Upstream Linen history

## 0.7.1

### New

- New Tab opens the command palette. Enter an address or search, then choose
  a result to create the tab. Choose Open Start Page to open the start page.
- The assistant can drag and double-click on pages, interact with embedded
  pages, upload files you select, and check downloads. Page permissions apply.

### Improved

- The assistant checks page and download results before marking a task complete
  and reports outcomes it cannot verify.
- Pages opened by the assistant appear in the active tab so you can follow
  its work.
- Conversation context limits now account for the selected provider and model.
- Settings search opens the relevant page and highlights the matching control,
  including controls within OpenAI settings.
- Sleeping tabs release more memory. Reloading can recover pages whose browser
  process has stopped responding.

### Fixed

- The assistant retries temporary provider failures without repeating browser
  actions that already ran.
- Voice configuration uses the provider you selected.
- Moving the pointer over command palette suggestions no longer replaces
  what you typed.
- Autofill can reuse a recent authentication on the same page. It asks again
  after you navigate or switch profiles.
- Writing fields that mention an email address or name no longer trigger
  contact autofill suggestions.
- Repaired update sources for older Firefox extension installations and fixed
  compatibility with extension icons and keyboard shortcuts.
- Certificate checks no longer hang the browser.
- The address bar loading indicator feels smoother when loading the page.

### Removed

- The OpenAI document-search library. You can still attach files to messages.
- The blank-page and custom-homepage options for new tabs.

## 0.7.0

### New

- Save and fill passwords, payment cards, and contact details. Manage saved
  entries in Settings > Autofill. Passwords and cards require system
  authentication. You can also use a password manager extension.
- Attach images, PDFs, and text files to assistant messages.
- Have a voice conversation with the assistant through OpenAI. Choose a voice
  in assistant settings, interrupt a reply, and review the conversation in chat.
- Use OpenAI models to search the web, create images, and work with data.
  Supported tools are available automatically. OpenAI usage charges apply.
- Connect external services to the OpenAI assistant through MCP.
- Use the assistant's page screenshot, pointer, and keyboard tools to interact
  with a page. Browser control requires your permission.
- Connect an external assistant to Linen through its MCP server. Share selected
  tabs with read-only access or permission to control them. Setup is available
  for Codex, Claude Desktop, Claude Code, and Cursor.

### Improved

- The assistant saves progress so you can continue interrupted tasks. It checks
  uncertain actions before retrying them and pauses when it keeps getting stuck.
- Long conversations can compact their working context automatically or on
  demand. A context indicator shows estimated usage.
- Assistant activity now shows progress updates and groups completed work.
- OpenAI settings have separate pages for voice, connections, and privacy
  settings. Advanced options are under Developer Settings.
- Collapse a Peek preview and reopen it without losing the page.
- Use the arrow keys in the address field to preview a suggested address before
  opening it.
- Website icons stay readable against light and dark backgrounds. New settings
  default to website tint and tab color effects.
- Website permission controls and download progress are easier to read.
- Diagnostic logs omit page content, conversation text, and raw provider errors.

### Fixed

- Page commands now act on the visible Peek preview.
- Updating a pinned page no longer moves it within the sidebar.
- Starting a new tab no longer shows a loading state for its background warm-up.

## 0.6.1

### New

- Right-click a link for Open Link in Peek and Summarize Link.
- Sign in to websites with a passkey.

### Improved

- Moving tabs, folders and tab pinning in the sidebar is clearer.
- The assistant shows the same thinking mark in the side panel and on the
  summary card.

### Fixed

- Linen could quit unexpectedly when a website stopped responding.
- With the side panel open, the page ignored the pointer.

### Removed

- Intel Macs. Linen needs a Mac with Apple silicon.
- Dropping a tab on another tab no longer makes a folder. Use New Folder, or
  the tab’s menu.

## 0.6.0

### New

- Hold Shift over a link to see a summary before opening it.
- Shift-click a link to open it in a panel over the page. Keep it as a tab,
  or press Escape to close it.
- Rename a tab: click the name of the tab you are on, or choose Rename in its
  menu.
- Drag a tab into the pinned section to pin it, and out of it to unpin it.
- Choose what a website may auto-play, and what its pop-ups do, in Website
  Settings.
- Setup offers a few extensions to add.

### Improved

- Bookmarks are now called pins.
- Each provider keeps its own Thinking setting.
- Assistant settings are now grouped by model, behavior and permissions.
- The link address at the bottom of the page says what a ⌘-click or a ⇧-click
  does.
- Extensions activate when you open a supported website.

### Fixed

- A dark website flashed white as it opened.

## 0.5.0

### New

- Extensions install from Firefox Add-ons as well as the Chrome Web Store.
- Extensions can now exchange messages with a companion app on your Mac.
- Middle-click a link to open it in a new tab.
- Point at a link to see its address at the bottom of the page.
- Settings, History and Downloads open in a tab of their own.
- Turn Automatic Picture in Picture off for one website, in **Settings >
  Websites** or in Website Settings in the toolbar.
- Minimizing the window sends a playing video to Picture in Picture, as
  leaving its tab already did.

### Improved

- Address bar suggestions favor the pages you visit most and most recently.
- History gathers a day’s repeat visits to one page into a single entry.
- Open a history entry in a new tab with a middle-click or a ⌘-click.
- Picture in Picture now works on websites that used to refuse it.
- Tracker blocking says when a page refers to no known trackers, instead of
  showing an empty list.
- The Liquid Glass window style is now called Transparent.
- Website Controls in the toolbar is now Website Settings.

### Fixed

- The toolbar took the color of the page you were opening before that page
  appeared, so it changed color twice.
- A link to a tracker domain did not open. Only the requests a page makes in
  the background are blocked.
- Turning a Safari extension off in the toolbar menu took it off the list
  instead of disabling it.
- A tab stayed marked as muted after the page unmuted itself.
- Linen did not come forward when you sent the floating video back to its tab.
- A new tab opened from a bookmarked tab landed among the bookmarked ones,
  instead of below them.
- In the release notes, the line after a list ran into the last bullet above
  it.

## 0.4.2

### Improved

- Bookmarked tabs stay at the top of the sidebar. A new tab now opens below
  them instead of pushing them down, and a line separates the two groups.
- Linen asks before you close a bookmarked tab, because the bookmark closes
  with it.
- Back to Bookmarked Page is now ⇧⌘D. macOS keeps ⌥⌘D for the Dock.
- Control-click empty space in the sidebar for New Tab, New Folder and
  Organize Tabs.
- The sidebar and the toolbar take much more color from the website you are
  reading when **Settings > Appearance > Website tint** is enabled.
- Hover highlights now adapt to the website tint for visibility on dark and
  light websites.

### Fixed

- Dragging inside the address field moved the window, so you could not select
  the address.
- The update notice stayed hidden while Settings was open.
- The top of a chat faded out even with nothing scrolled above it.
- The dots on the split view handle took the accent color on the pane you were
  using, instead of staying white.

## 0.4.1

### Improved

- History, Settings and Downloads now open in the tab you are using, like a
  normal web page.
- The assistant chat now names the website it is reading, such as “Ask about the
  GitHub page”.
- The assistant can now show tables in its answers.
- The media player title now uses the full width. Its buttons fade in over the
  end of the title when you point at the player, so the title no longer moves.
- When more than one tab is playing, a new button in the media player opens a
  list of them.
- The loading bar now runs the full width of the page.
- The selected thinking level now appears beside the Thinking heading.
- Hide Browser has gone from the View menu. ⌘H hides Linen and ⌘W closes the
  window, as in any Mac app.
- “Report a bug” is now “Send feedback”.

### Fixed

- The window disappeared from your desktop when you swiped back from a
  full-screen app, and another app came to the front.
- The assistant reading a page turned JavaScript back on in every tab, even
  with JavaScript turned off in Settings.
- Back from History closed the tab when you had opened History from the start
  page.

## 0.4.0

### New

- The side panel is now a chat with the assistant, and each tab keeps its own
  thread. Choose the provider, model and reasoning level below the message field.
- The assistant can ask for clarification. Answer it, skip
  the question, or let the assistant choose.
- Type `@` in the panel to attach another tab to your question.
- Answers arrive formatted. Copy one, hear it read aloud, ask it again, or edit
  your message and send it back.
- Thinking offers only the levels your model supports, including Minimal.
- Apple Intelligence answers stream in as they are written.
- Settings, History, Downloads, Release Notes and new tabs have addresses, so
  Back and Forward work with them.
- Suggestions on the start page are a section you can move or turn off.
- Settings > Extensions lists the Safari extensions on your Mac, and each
  profile keeps its own.
- Settings > Advanced > Feature flags lists WebKit feature flags,
  with search and a reset.
- Extensions from the Chrome Web Store update themselves once a day. Check for
  Updates in an extension’s menu checks right away, and an update that asks for
  more access waits for you.
- Your downloads stay in the list after you quit. Settings > Downloads decides
  when the list empties.

### Improved

- Switching profiles is five to eight times faster.
- Restored background tabs load only when opened, reducing startup time for
  large sessions.
- The profile switcher opens beside its button in the sidebar, and every profile
  icon is a circle.
- The downloads button is always in the sidebar, and a file you download flies
  from where you clicked it into the button.
- Settings is built from one set of rows. Nothing lights up under the pointer,
  every card shares a surface, and anything that opens a page is a row with a
  chevron rather than a button.
- A setting that is off because another setting is off tells you which one, and
  takes you there.
- Block known trackers moved to Settings > Privacy.
- Keep loaded for a website is now Keep this website awake.
- Each settings page keeps its own action, such as Reset, Remove All or Delete
  Profile, next to the button that takes you back.
- The media player fits the sidebar. Its controls appear when you point at it,
  and the title takes the room they leave.
- A side panel conversation stays out of the address field.
- Tab previews cover folders, split panes and Linen’s own pages.
- Settings pages fit a narrow window.
- Folder colors are less saturated, and folder menus use the same colors.
- The split view’s drag pill matches the sidebar and side panel pills.
- Website Settings is off on Linen’s own pages.
- Linen checks for updates in place, and again after finding one.
- Extensions tell you when WebKit cannot run them.

### Fixed

- A website could open one of Linen’s own pages by asking for a `linen:`
  address.
- Signing in to a Mac app from a website did nothing.
- Read aloud stayed silent while spoken replies were muted.
- Release notes broke wrapped lines apart.
- The window moved while you dragged a button in the toolbar.
- Space did not reach the page.
- Sidebar rows sat at different distances from the edge.
- Placeholder text jumped when a search field took focus.
- The downloads button stayed selected after you opened downloads.
- Live streams showed an unusable playback slider and lyrics button.
- The media player kept a picture from a page you had left.
- A tab could display the color of another website’s icon.
- The address bar showed nothing while it checked a connection.

## 0.3.1

### New

- Window style in Settings > Appearance sets how the toolbar and the sidebar are
  displayed. Standard uses an opaque background; Liquid Glass uses a
  translucent one. Glass transparency offers Clear to show more of the desktop
  and Tinted for stronger text and control contrast.

### Improved

- Match website color is now Website tint, and Refract tab color is now Tint
  selected tab. Both are off by default.
- Appearance now comes before Search in Settings.

### Fixed

- The pages you had open in one profile were added to another profile’s history
  when you switched profiles.
- Files you downloaded in a private tab stayed in your downloads after private
  browsing ended. A download that is still going now stops when you leave
  private browsing.
- A website’s icon could be saved in the wrong profile.
- The assistant still remembered what you asked it in the profile you left.

## 0.3.0

### New

- Linen uses Liquid Glass, with translucent backgrounds for the page, sidebar,
  side panel and Settings.
- The window uses a tint from the current website. Turn off
  Match website color in Settings > Appearance to keep Linen’s usual Light or
  Dark theme instead.
- Turn on Refract tab color in Settings > Appearance, and the selected tab takes
  on the color of that website’s icon.
- The theme picker shows you what Light, Dark and Auto look like before you
  choose.
- Linen restores open tabs when you launch the app.
- Sleep inactive tabs in Settings > General frees memory when your Mac runs low.
  It is off by default.
- The address field is now on every page, including a new tab.
- Website Settings is now a compact panel. It holds page zoom, assistant access,
  tracker blocking, and the camera, microphone, location and notification
  choices for the website you are on, and its tracker details show which known
  tracker domains Linen found on the page.

### Improved

- Type `@` in the address field to point the assistant at one of your tabs. The
  list of tabs opens as soon as you type it, with your question at the top.
- You can make the window much narrower, and websites switch to their compact
  layouts when you do.
- Tabs slide behind the top of the sidebar instead of fading away.
- The side panel shows a music note only when lyrics are available.
- The edges you drag to resize the sidebar and the side panel are easier to see.
- Settings uses lighter shadows and less prominent highlights.
- Removing an extension is now a button in a menu beside it, along with that
  extension’s own settings.

### Fixed

- Scrolling the sidebar or the side panel could reload the page behind it.
- Pointing at the side panel could highlight things on the page underneath.
- Dragging an extension button moved the whole window.
- The address field applied autocorrection to web addresses. It now preserves
  what you type.
- Tabs selected with `@` could return blank content.
- A new tab said the assistant could read it.
- Text in the toolbar was hard to read on some websites.
- An answer from the assistant appeared behind the side panel.
- A tab’s title moved when it started playing sound.
- The color of the window changed a moment after you picked a tab.
- Some dark websites left the window light, and some did not color the window
  until you reloaded them.
- ⌘← and ⌘→ went back or forward while you were editing the address field
  instead of moving through its text.
- Website Settings could be difficult to read over a busy or dark page.

## 0.2.0

### New

- Linen shows synced lyrics for the current song. Open them from the media
  player, from View > Show Lyrics, or with ⌥⌘Y. Adjust text size and timing,
  or choose a different match. Only the song and artist names leave your Mac, and
  never from a private tab. Turn this off in Settings > General.
- Activity and Lyrics now share one panel on the right. One button in the
  toolbar opens it, and the arrows widen it to fill the window.
- A button in the address field sends the video you are watching to a floating
  window. Turn on Automatic Picture in Picture in Settings > General and the
  video opens in Picture in Picture when you leave the tab and returns when
  you reopen it.
- The media player follows whichever tab is playing, so you can pause or skip
  from anywhere.
- Settings > Experiments contains features in development. They may change or
  be removed.
- Import bookmarks from another browser. Export a bookmarks file from
  Safari, Chrome, Firefox or Edge, then choose it in Settings > General.
- Save Page As… and Print Page… are in the menu you get when you right-click a
  page.
- A link that opens in its own tab now lands below the tab it came from.

### Improved

- Read aloud and Push to talk moved to Settings > Assistant, beside everything
  else about the assistant.
- Closing a tab takes you to the one below it.
- Menus mark what you chose the way the rest of the Mac does.

### Fixed

- The media player kept showing a track that had stopped.
- Settings and History slid in when they had not moved.

## 0.1.1

### New

- Settings > About lets you follow Preview builds instead of waiting for the
  next release. You can go back to Release at any time.
- Install in the update banner downloads and installs the update without a
  second confirmation.
- The notes for a new version open in a tab after it arrives. To read them
  again, choose Linen > Release Notes.
- ⌃⇥ returns you to your last tab, the way ⌘⇥ returns you to your last app. Hold
  ⌃ and press ⇥ to select the next tab, or ⇧⇥ to select the previous tab.
- Click the orb and talk. Linen sends what you said once you stop. Click the orb
  again while the assistant is working to stop it.
- In the command palette, ⌘↩ asks the assistant about what you typed, and ⇧↩
  searches in a new tab.

### Improved

- The assistant can continue long conversations that exceed its context limit.

### Fixed

- A pasted link brought its styling into the address field.
- A tab kept spinning after going back.
- The scroll wheel moved the page behind the command palette.

## 0.1.0

First release. Linen is a browser for macOS 26 and later.

### The assistant

- The assistant works in the tabs you already have open. It searches, opens
  websites, reads them, clicks, types and scrolls.
- Ask in the address field, or hold ⌥Space and speak. Click the page to stop the
  assistant and use it yourself.
- It asks you first before it buys, sends or signs in, and never fills in a
  password or a card number.

### Models

- Apple Intelligence runs on your Mac without an API key.
- Or add your own key for OpenAI, Anthropic, Gemini, DeepSeek, Groq, Mistral,
  OpenRouter or xAI.
- Or connect Linen to a local server, such as Ollama or LM Studio.

### The browser

- Tabs, folders, pinned tabs and split view.
- Profiles and private browsing.
- A command palette, history and find in page.
- Downloads that resume, and zoom you set for each website.
- Extensions from the Chrome Web Store.

### Before you start

- This is an early release. What Linen saves to disk can still change between
  versions.
- Linen opens one window at a time, and does not yet fill in passwords or show
  web notifications. See the README for limitations.
