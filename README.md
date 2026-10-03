# Queue-T for VLC

Automatically add later episodes from the current video's season folder,
followed by episodes from its matching next season folder. Open an episode
normally; Queue-T finds similarly named video files and queues them without
interrupting playback.

## Features

- Queues remaining episodes in the current season, then episodes from the
  best-matching next season folder (such as `Show S01` / `Show S02` or
  `Show Season 1` / `Show Season 2`).
- Supports common video formats; by default, queued files must use the same
  extension as the currently playing episode.
- Avoids adding files already in the playlist.
- Runs quietly in VLC and reports its decisions in VLC's Messages window.
- Processes files locally; it does not connect to the internet or send media
  information anywhere.

## Requirements

- VLC media player 3.x with Lua support.
- Windows for the included automatic installer. Other platforms can use the
  manual installation steps below.

## Install on Windows

1. Exit VLC completely.
2. [Download Queue-T.zip](https://raw.githubusercontent.com/Noris92/Queue-T/main/Queue-T.zip)
   and extract it.
3. Open PowerShell in the extracted folder and run:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
   ```

4. Start VLC and open an episode. Later matching episodes should appear in the
   playlist, followed by episodes from the matching next season folder.

The installer copies the interface to the current Windows user's VLC profile
and enables it when VLC starts. These files and settings remain in place across
Windows restarts. VLC must be fully closed while installing or uninstalling.
The installer preserves other VLC extra interfaces and saves the prior values
of settings it changes in the VLC profile, not in this project.

## Manual installation

Copy `autoqueue.lua` into VLC's `lua/intf` folder in your VLC user profile:

- Windows: `%APPDATA%\vlc\lua\intf`
- Linux: `~/.local/share/vlc/lua/intf`
- macOS: `~/Library/Application Support/org.videolan.vlc/lua/intf`

Create the folder if it does not exist. Enable the Lua interface by setting
`lua-intf=autoqueue` in VLC's Lua settings and adding `luaintf` to the
`extraintf` setting. In VLC 3, these settings are stored in the `vlcrc`
configuration file. Restart VLC after changing them.

To uninstall a Windows installation made with the included installer, exit VLC
and run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
```

Manual installations can be removed by deleting `autoqueue.lua` from the
interface folder and reverting the two VLC settings.

## Filename matching

Queue-T replaces numbers in filenames with a placeholder when comparing
names, then compares their shared prefix and suffix. Candidates must meet the
similarity threshold configured near the top of `autoqueue.lua` and sort after
the currently playing file by their numbers. When the current episode is inside
a season folder, Queue-T queues later episodes in that folder first, then
queues episodes from the best-matching higher-numbered sibling season folder.
Season folder names can include a series name and release details around a
season marker such as `S01` or `Season 1`; matching ignores capitalization.
All supported video files with the current episode's extension in the selected
next-season folder are queued in episode-number order, even when their episode
titles or release tags differ. They are queued after the remaining current-season
episodes.

Edit these settings at the top of the script if needed:

- `SIMILARITY`: minimum filename similarity, from `0` to `1` (default `0.25`).
- `SAME_EXTENSION_ONLY`: require the same file extension (default `true`).
- `VIDEO_EXTENSIONS`: supported extensions.

## Troubleshooting

Open **Tools → Messages**, set verbosity to **2**, and filter for `[Queue-T]`.
On startup, the log should contain `Queue-T 1.0.0 loaded`. The following
messages explain why an episode was or was not queued.

## License

MIT. See [LICENSE](LICENSE).
