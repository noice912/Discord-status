# Privacy policy

This policy covers the **RichPresence** desktop app and the **RichPresence browser extension**
("RichPresence - what you're watching"). Last updated: 2026-10-01.

## The short version

RichPresence has no accounts, no analytics and no servers. Nothing you do is ever sent to the author.
What the browser extension reads stays on your computer: it goes only to the RichPresence app running
on the same PC, which shows it on your Discord status through the Discord app on that PC.

## The browser extension

**What it reads.** Only on the supported streaming sites (Netflix, Hulu, Disney+, Prime Video, Max,
Crunchyroll, Paramount+, Peacock, Apple TV+, Plex, YouTube and Twitch), and only on their player pages,
it reads:

- the title of the show, movie, video or stream, and the episode name or channel shown by the player;
- whether the video is playing or paused, its current position and its length;
- on YouTube and Twitch, the address of the video's thumbnail image.

On Netflix, if the title isn't on screen yet, it asks netflix.com for the title of the video you
opened, the same way Netflix's own website does, using your existing session. It doesn't read or store
your session, cookies or account details.

**Where it goes.** Only to `http://127.0.0.1:47610`, which is the RichPresence app on your own
computer. It is never sent to the author or to any other server. If RichPresence isn't running, the
information goes nowhere.

**What it doesn't do.** It doesn't read anything on other websites, doesn't read your browsing history,
passwords, cookies, payment details, messages or personal information, doesn't store anything, and
doesn't use or sell data for advertising, profiling or any purpose other than showing what you're
watching on your Discord status.

## The desktop app

The app shows what you're playing, listening to and watching on your Discord status, through the
Discord app on your computer. It uses these websites only when the matching feature is on: discord.com
(the public list of known games, and app icons), itunes.apple.com (album art), lrclib.net (lyrics),
enka.network (a Genshin Impact profile, if you enter a UID), google.com/s2/favicons (app and site
icons), api.tvmaze.com and v3-cinemeta.strem.io (show and movie posters). Those requests contain only
what they need, such as a song or show name. Like any web request, those sites can see your IP address.
Settings are stored on your computer in `%APPDATA%\RichPresence` (Windows) or `~/.config/RichPresence`
(Linux).

## What others see

Whatever RichPresence shows on your Discord status can be seen by the people who can see your Discord
profile, under Discord's own privacy settings. You can turn each card off in the app, or hide the show
names, at any time.

## Children

RichPresence doesn't collect personal information from anyone, including children.

## Changes and contact

Changes to this policy are published in this file in the
[RichPresence repository](https://github.com/noice912/RichPresence). Questions: open an issue at
https://github.com/noice912/RichPresence/issues.
