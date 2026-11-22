## RichPresence 3.2.1

### Open the overlay from your controller (Windows)
The **Xbox button**, or the **PS button** on a DualSense or DualShock 4, now opens and closes the overlay.
It's on by default; turn it off at the bottom of **Settings**.

Two other programs want that button too:
- **Xbox Game Bar**: tick **Stop that button opening Xbox Game Bar** in Settings. It turns off the Windows
  switch for it and puts it back when you untick.
- **Steam**: in Steam, go to **Settings > Controller** and turn off **Guide button focuses Steam**.
  RichPresence can't change that one for you.

The overlay itself still needs a mouse. Seeing the controller was checked with a DualSense; an actual button
press and the Game Bar switch were **not yet tried**. If one misbehaves, please open an issue.

Linux, Android and iPhone: no changes, only the version number.

## RichPresence 3.2.0

### In-game overlay (Windows)
Press **Ctrl+Alt+G** while you play and a panel opens over the game. Esc, the shortcut again or a click
outside closes it.

- **Music**: the song and its live lyric line, with previous, play/pause and next
- **Volume**: a slider and mute for the whole PC and for each app making sound
- **Games**: your library with search; click a game to start it
- **Steam, Xbox & PlayStation**: Steam library, Big Picture and friends; the Xbox app and Cloud Gaming; PS Remote Play
- **OBS**: start or stop recording, go live, save a replay, switch scene
- **Lights**: your RGB lights follow the colour of the screen, through OpenRGB
- **Discord**: presence on or off and your custom statuses

Change or turn off the shortcut at the bottom of **Settings**.

Good to know:
- It shows over borderless and windowed games (most games today), not over true exclusive fullscreen.
  Nothing is put inside the game, so anti-cheat has nothing to object to.
- OBS needs **Tools > WebSocket Server Settings > Enable WebSocket server**.
- Lights need [OpenRGB](https://openrgb.org) open with its **SDK server** running. Turning the sync off
  leaves the lights on the last colour.
- OBS control and the light sync were built against their documented interfaces but **not yet tried
  end to end**. If one misbehaves, please open an issue.

### Linux, Android and iPhone
No changes in this release; only the version number moves to 3.2.0 so every platform matches.

## RichPresence 2.1.6

### Spotify with live lyrics (Windows)
The music card now works with the **Spotify** app as well as Apple Music: the song, its album art and the
**current lyric line**, updating as the song plays. It's on by default; turn it off under **Music & Apps**.

If your Spotify is linked to Discord, Discord shows its own Spotify card too. To keep just the one with
lyrics, turn off **Display Spotify as your status** in Discord's Connections settings.

### Fixes: Windows
- A game's desktop shortcut now starts the game when RichPresence is already running in the tray
- Typing `[` in the game search no longer empties the grid; searching no longer uses more memory with every key
- Updates never install while any game from your library is running, even with presence off or Discord closed
- "Quit when my game closes" works while Discord is closed
- A failed update is not retried in a loop, and the update file is checked again right before it installs
- A wrong custom App ID is reported once in the Log instead of every few seconds
- If presence stops on its own, the reason now appears in the Log
- The window no longer freezes on Stop, Apply or Quit when Discord or Windows is slow to answer
- Add game and Save & rescan during a scan are no longer ignored
- The Watching progress bar is right on PCs that write decimals with a comma

### Fixes: browser extension (1.2.0)
- Two tabs of the same site no longer overwrite each other
- Closing the tab clears the card; a video paused for a minute clears it too
- Skipping forward or back updates the progress bar straight away
- Apple TV+ and Peacock preview trailers no longer count as watching
- No more leftover title from the previous video on Plex, Prime Video and YouTube

### Fixes: Linux
- A game's menu shortcut starts the game when RichPresence is already running
- "Quit when the game I launched closes" works for games hidden from Discord
- One rejected card no longer takes the other cards down with it
- A lyrics or album-art lookup that fails once is tried again later
- Games keep their Discord match when the game list can't be downloaded
- A failed update no longer freezes the status and log; restarting after an update is more reliable
- Games and apps started from the AppImage use the system's own libraries

### Fixes: Android and iPhone
These were built by GitHub but **have not been tested on a phone**. If something is worse than 1.6.0,
please open an issue.
- Android: if the system restarts RichPresence in the background, a notification asks you to open it to reconnect to Discord
- Android: reconnects to Discord after the connection drops; the Start/Stop button shows the real state; the screen fits under the status bar on Android 15
- iPhone: cancelling a Discord link no longer leaves the button stuck on "Waiting for Discord..."
- iPhone: the game you set is remembered if iOS restarts the app; reconnects to Discord after a drop
- iPhone: stays running after a phone call interrupts it; a failed lyrics lookup is tried again

Every file is built by GitHub Actions from this repository's source.

## RichPresence 1.6.0

### The browser extension now covers every streaming service
`RichPresence-extension.zip` (version 1.1.0) now reads what you're watching on **Netflix, Hulu, Disney+,
Prime Video (including amazon.com), Max, Crunchyroll, Paramount+, Peacock, Apple TV+, Plex, YouTube
and Twitch**:
- the show and episode from each site's player, falling back to the page's media info and its tab title
- an exact progress bar, and the card goes away as soon as you pause
- Crunchyroll's player frame reports play/pause to the page around it
- YouTube and Twitch cards get the video's thumbnail

**Update the extension:** unzip the new version over your old extension folder, then click the reload
icon on it in `edge://extensions` (or `chrome://extensions`). New install: see the steps below.

## RichPresence 1.5.0

### Browser extension for Netflix and Hulu
Netflix and Hulu don't tell Windows what you're watching, so the new **RichPresence browser extension**
(`RichPresence-extension.zip`, for Edge, Chrome, Brave and Opera) reads it from the player page:
- the show and episode ("Stranger Things", "S4:E1 Chapter One: The Hellfire Club"), or the movie
- an exact progress bar, and the card goes away as soon as you pause
- it only talks to RichPresence on your own PC, which only accepts it from a browser extension

Install: unzip it, open `edge://extensions` (or `chrome://extensions`), turn on Developer mode,
**Load unpacked**, pick the folder. Click its icon to see that it's connected.

### From 1.4.1
- the app card no longer shows next to the Watching card
- no more "Watch" as a title or wrong posters; Edge tab titles are tidied up

## RichPresence 1.4.1

### Fixes
- Watching: the app card ("Microsoft Edge") no longer shows next to the Watching card
- Watching: pages that only say "Watch" (Hulu, Netflix) no longer show "Watch" as the title or a wrong poster
- Posters only match a show whose name is the start of the title (no more "Watch" -> "Watch the Skies")
- Browser tab titles no longer show "and 3 more pages - Personal - Microsoft Edge", and Edge's name is no longer garbled

## RichPresence 1.4.0

### Watching (Windows)
A **"Watching"** card for **Netflix, Hulu, Disney+, Prime Video, Max, Crunchyroll, Paramount+, Peacock,
Apple TV+ and Plex**, plus YouTube and Twitch (optional):
- shows the show or movie name, taken from what the site reports to Windows' media controls or from the tab title
- shows the show's poster, looked up on TVMaze (TV) and Cinemeta (movies), with the service's logo in the corner
- shows a progress bar when the site reports where you are
- works in Chrome, Edge, Firefox, Brave, Opera, Vivaldi and the services' Windows apps
- each service has its own Discord card with its name and logo (Plex, YouTube and Twitch use the app card)
- each part can be turned off under **Music & Apps**. It never reads the page itself, your cookies or your account.

### From 1.3.0
- **Custom status** tab: your own cards with your own text, pictures and buttons, shown separately or merged into one.

Every file is built by GitHub Actions from this repository's source.
