## RichPresence 3.3.2

### PS Remote Play: keep the controller to the overlay (Windows)
PS Remote Play passes your controller to the PlayStation even when another window is in front, so the
console followed everything you did in the overlay. There is now a setting for that, at the bottom of
**Settings**: **Pause PS Remote Play while the overlay is open**. It is off by default.

With it on, Remote Play is paused shortly after the overlay opens and carries on when it closes.

Good to know:
- While it is paused its picture freezes too. The game on the PlayStation keeps running without you.
- The button press that opens the overlay still reaches the PlayStation, so its own menu may pop up.
- It was tried on one PC and the connection held. How long a PlayStation puts up with it isn't known; if
  yours drops the connection, keep overlay visits short or leave the setting off.
- Remote Play is un-paused when the overlay closes and when RichPresence quits. If RichPresence is ever
  ended in the middle, starting it again un-pauses Remote Play.

### The overlay takes over properly when opened from a controller (Windows)
Opened with the controller's logo button, the overlay used to appear on top while the game underneath was
still the active window. It now becomes the active window however it was opened, and hands that back to
the game when it closes, so you don't have to click back in. Games that only listen while they are active
stop reacting to the controller while the overlay is up.

Linux, Android and iPhone: no changes, only the version number.

## RichPresence 3.3.1

### Use Discord in the overlay with your controller (Windows)
Discord is a web page, so inside it the controller works as a mouse.

| Control | What it does |
|---|---|
| **Left stick** | Moves the pointer: gentle near the middle, fast at the edge |
| **A** / **Cross** | Click (hold to drag) |
| **X** / **Square** | Right-click |
| **Right stick** | Scroll |
| **D-pad** | Arrow keys |
| **Start** / **Options** | Enter |
| **Y** / **Triangle** | Opens the controller keyboard |
| **B** / **Circle** | Back to the overlay's widgets |

### Controller keyboard
Click a text box with the pointer, then press **Y / Triangle**. A keyboard appears at the bottom of Discord.
Move with the d-pad or left stick and press **A / Cross** to type. **X / Square** deletes, **Y / Triangle**
is a space, **Start / Options** is Enter and **B / Circle** closes it. **Shift** capitalises the next letter,
and **#+=** switches to symbols and back.

Good to know:
- The game underneath still gets the same stick and button presses.
- Tried with a DualSense. An Xbox controller should behave the same but **hasn't been tried**; if a button
  does the wrong thing, please open an issue and say which controller.

Linux, Android and iPhone: no changes, only the version number.

## RichPresence 3.3.0

### Discord inside the overlay (Windows)
Press **Discord** in the overlay's top bar and Discord opens right there, over your game. It is Discord's
own web app in a built-in browser, so it is the real thing: every chat in Discord's order, pins, group
chats, full history, pictures and voice calls. **Back** returns to the widgets.

- Sign in once on Discord's own page (scanning the QR code with your phone is quickest). RichPresence
  never sees your password; the sign-in is kept in the browser's own folder on your PC.
- A call keeps going when you close the overlay.
- Links people send open in your normal browser, not in the overlay.
- **Sign out and forget** in the Discord column closes it and deletes that saved sign-in.

Good to know:
- It needs Microsoft's WebView2 Runtime, which is part of Windows 11. On Windows 10, install it from
  microsoft.com/edge/webview2.
- The controller opens and closes the overlay but can't click around inside Discord; that needs a mouse
  and keyboard.
- It uses about as much memory as a Discord browser tab, and only once you've opened it.
- RichPresence is still one file and downloads nothing for this: three small Microsoft files that drive
  the browser are inside the EXE and are unpacked the first time you open Discord.

### Phone (Windows)
A **Phone** box in the overlay: type a number and press **Call** or **Text**, and Windows' Phone Link takes
over with your paired phone. **Open Phone Link** opens it directly. Your texts are not shown in the
overlay; Windows gives apps no way to read them. These buttons were **not yet tried end to end**.

### Layout
On screens 1600 pixels wide or more the overlay has a fourth column (Discord and Phone). On smaller
screens a **More** button in the top bar swaps it with the Games column.

Linux, Android and iPhone: no changes, only the version number.

## RichPresence 3.2.2

### Use the overlay with your controller (Windows)
Once the overlay is open, the controller drives it. A blue frame shows where you are.

- **D-pad or left stick**: move. Hold to keep moving.
- **A** (Xbox) / **Cross** (PlayStation): press the button, tick the box or start the highlighted game.
  On the OBS scene list each press goes to the next scene.
- **Left and right on a slider**: change the volume or the brightness.
- **B** / **Circle**, or the logo button again: close.

Good to know:
- The game still gets the same presses. Nothing is put inside the game, so RichPresence can't hide the
  controller from it; a game that listens while it's in the background will react too.
- This was checked with simulated presses and a connected DualSense, **not yet with real presses on every
  controller**. If a button does the wrong thing, please open an issue and say which controller and
  whether it's on USB or Bluetooth.

Linux, Android and iPhone: no changes, only the version number.

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
