# Chrome Web Store listing

Everything the Chrome Web Store developer dashboard asks for, ready to paste.
Upload file: `RichPresence-extension.zip` from the latest release (or `dist\RichPresence-extension.zip`).

## Store listing tab

**Name** (comes from the manifest): RichPresence - what you're watching

**Summary** (max 132 characters, from the manifest description is fine, or use this):
> Show the show and episode you're watching on Netflix, Hulu, Disney+, Prime Video and more on your Discord status.

**Description:**
> Show what you're watching on your Discord status: the show, the episode, its poster and how far in you are.
>
> Watching Netflix
> Stranger Things
> S4:E1 Chapter One: The Hellfire Club
>
> Works on Netflix, Hulu, Disney+, Prime Video, Max, Crunchyroll, Paramount+, Peacock, Apple TV+, Plex, YouTube and Twitch.
>
> HOW IT WORKS
> This extension is the companion to RichPresence, a free, open-source app for Windows that shows what you're playing, listening to and watching on Discord. On a streaming site's player page, the extension reads the title, the episode and whether the video is playing, and passes them to the RichPresence app on your own computer. RichPresence then shows them on your Discord status, with the show's poster and a progress bar. Pause, and the status goes away.
>
> You need:
> - the RichPresence app for Windows, version 1.6.0 or newer (free): https://github.com/noice912/RichPresence/releases/latest
> - the Discord desktop app, with "Share your detected activity with others" turned on
>
> Click the extension's icon to check that it's connected and to see what it's reading.
>
> PRIVATE BY DESIGN
> - What the extension reads goes only to the RichPresence app on your own computer (127.0.0.1). It is never sent to the author or to any server.
> - It only runs on the supported streaming sites, only reads the player, and stores nothing.
> - No account, no analytics, no ads. The source code is public.
>
> RichPresence is a fan project, not affiliated with or endorsed by Discord or any streaming service.

**Category:** Social & Communication (or Entertainment)

**Language:** English

**Store icon (128x128):** `extension/icon128.png`

**Screenshots (1280x800):** `store/screenshot-1.png`, `store/screenshot-2.png`

**Small promo tile (440x280, optional):** `store/promo-small.png`

**Website / Support URL:** https://github.com/noice912/RichPresence

## Privacy practices tab

**Single purpose:**
> Shows the title of the show or video you're watching on supported streaming sites on your Discord status, by passing it to the RichPresence desktop app on your own computer.

**Permission justification - host permission `http://127.0.0.1/*`:**
> Sends what's playing (title, episode, play state, position) to the RichPresence desktop app running on the user's own computer, which puts it on their Discord status. Only 127.0.0.1 (the local machine) is contacted; no remote servers.

**Permission justification - content scripts on the streaming sites:**
> The extension reads the title, episode and play state from the video player on Netflix, Hulu, Disney+, Prime Video, Max, Crunchyroll, Paramount+, Peacock, Apple TV+, Plex, YouTube and Twitch. It runs only on those sites. On amazon.* it only acts on the Prime Video player, never on product pages.

**Are you using remote code?** No. All code is in the package.

**Data usage - what user data is collected:** tick **Website content** only (the title and episode of the video being watched).
Leave everything else unticked (personally identifiable info, health, financial, authentication, personal communications, location, web history, user activity).

**Certify all three:**
- I do not sell or transfer user data to third parties, outside of the approved use cases
- I do not use or transfer user data for purposes that are unrelated to my item's single purpose
- I do not use or transfer user data to determine creditworthiness or for lending purposes

**Privacy policy URL:** https://github.com/noice912/RichPresence/blob/main/PRIVACY.md

## Distribution tab

**Visibility:** Public (or Unlisted, if you only want people with the link to find it)
**Regions:** All regions
**Pricing:** Free

## After it's published

Put the store link in the README's "The browser extension" section in place of the "Load unpacked" steps.
Updates: bump `version` in `extension/manifest.json`, upload the new zip under Package, submit for review.
