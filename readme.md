A discord bot that executes Luau code in a Roblox game.

Check out the site here:
https://haotian2006.github.io/LuauBotSite/

Add the bot here:  https://discord.com/oauth2/authorize?client_id=1271610114062811176

## Setup

### 1. `luauBot.b64` (required)

The bot ships its own code to each execution session as a base64-encoded rbxm,
so the target place needs nothing installed in it. **The bot will not start
without `luauBot.b64` in the project root.**

Copy `LuauBot.luau` into `workspace` as a module script:

```
workspace
    - LuauBot
```

Then run this in Studio and save the output into `luauBot.b64`:

```lua
local EncodingService = game:GetService("EncodingService")
local ToEncode = workspace.LuauBot


local Ser = game:GetService("SerializationService"):SerializeInstancesAsync({ToEncode})
Ser = EncodingService:CompressBuffer(Ser,Enum.CompressionAlgorithm.Zstd,22)
local encodedString = buffer.tostring(EncodingService:Base64Encode(Ser))
if not workspace:FindFirstChild("Output") then
	Instance.new("ModuleScript",workspace).Name = "Output"
end
game:GetService("ScriptEditorService"):UpdateSourceAsync(workspace.Output,
	function() return encodedString end )
```

Re-generate it whenever `LuauBot.luau` changes.

### 2. Execution profiles

Each Roblox place the bot can run code in is one file in `profiles/`. Copy
`profiles/example.json.template` to `profiles/primary.json` and fill it in:

```json
{
  "name": "primary",
  "universeId": "0000000000",
  "placeId": "0000000000",
  "apiKey": "<Open Cloud API key>",
  "priority": 1,
  "enabled": true
}
```

| Field | Meaning |
| --- | --- |
| `universeId` / `placeId` | The place to open an execution session in |
| `apiKey` | Open Cloud key for that place |
| `priority` | Lower appears earlier in the rotation |
| `enabled` | Set `false` to keep a profile on disk without using it |

Add as many profiles as you like. The bot cycles through them in priority
order, so three profiles run as `A → B → C → A`. If the selected profile
fails to start a session, the bot tries the remaining profiles in that cycle.

`profiles/*.json` is gitignored, because the API key is stored inline.

For `apiKey` you need to create an API key in the Roblox developer hub with the
permission `luau-execution-sessions` and Experience Operations of
`universe.place.luau-execution-session:write`.

### 3. Tool binaries

`luau-compile`, `luau-analyze`, `luau-ast` and `stylua` live in `bin/` and are
downloaded from the upstream GitHub releases:

```
npm run fetch-tools            # fetch whatever is missing
npm run fetch-tools -- --force # re-download, e.g. to pick up a new Luau release
```

This runs automatically on `npm install`. Windows, Linux and macOS (x64 and
arm64) are all handled; `bin/` is gitignored, so the binaries are never
committed. Pin versions with `--luau-version 0.735 --stylua-version v2.5.2`.

**Linux notes.** The script sets the executable bit itself, so no `chmod` is
needed. It picks the right artefact for the machine automatically:

| Machine | luau | stylua |
| --- | --- | --- |
| x86_64, glibc 2.34+ | prebuilt | prebuilt (gnu) |
| x86_64, older glibc | built from source | prebuilt (musl, static) |
| **aarch64 (Oracle Ampere)** | **built from source** | prebuilt (arm64) |
| aarch64, older glibc / Alpine | built from source | prebuilt (musl, static) |

upstream luau ships an x86_64 build only, and its prebuilt binaries import
`GLIBC_2.34`, so on aarch64 or an older distro the script compiles luau from
the release source instead. That needs a toolchain:

```
sudo apt install cmake build-essential   # Debian/Ubuntu
sudo dnf install cmake gcc-c++ make      # Oracle Linux/RHEL
```

It takes a few minutes. Force a source build anywhere with
`npm run fetch-tools -- --build`.

Also make sure `bin/` is not on a filesystem mounted `noexec`.

### 4. `.env`

```
BOT_TOKEN=Discord_Bot_Token
CLIENT_ID=Discord_Bot_Client_Id
PORT=Port_You_Want_to_Use_Default_3000
FORM_ID=Google_Form_Id(OPTIONAL)
CALLBACK_URL=http://your-host:3000
ENABLE_DISCORD=true(OPTIONAL, default true)
ENABLE_WEB=false(OPTIONAL, default false)
```

`ENABLE_DISCORD` and `ENABLE_WEB` choose which front ends run. Both share one
Roblox session pool, so a single execution session can serve both.

`ENABLE_WEB` defaults to **false** deliberately: the web routes execute
arbitrary Luau for anyone who can reach the port, with no authentication. When
it is off those routes are never registered at all. With `ENABLE_DISCORD=false`
the bot never logs in and `BOT_TOKEN` is not required, which is the setup for
running the web runner alone. Startup fails if both are disabled.

`CALLBACK_URL` is the address the Roblox session sends its requests back to.
It must include the scheme and no trailing slash. The old name `TUNNEL_URL`
still works but warns on startup.

Roblox credentials are **not** read from `.env` any more — they live in
`profiles/`.

### 5. Run

```
npm install              # also fetches the tool binaries
npm run register-commands   # register slash + context-menu commands (once)
npm start                # start the bot
```

Other helpers:

| Command | What it does |
| --- | --- |
| `npm run clear-commands` | Deregister every command from Discord |
| `npm run tunnel` | Print a public URL for `CALLBACK_URL` via tunnelmole |
| `npm run fetch-tools` | Re-fetch `bin/` binaries (`-- --force` to redownload) |

## Script Discord API

Globals a running script can use to control its Discord response.

### Buttons

Running Luau can add interactive buttons to its Discord response. Buttons use
Discord's `Primary`, `Secondary`, `Success`, and `Danger` styles.

```lua
local button = discord.button({
	Label = "Confirm",
	Style = "Success",
	OwnerOnly = true, -- default; false allows any Discord user to click
})

button.Clicked:Connect(function(userId, username)
	print(username, "clicked")
	button:Update({ Label = "Done", Disabled = true })
end)

-- button:Destroy() removes it from the Discord message.
```

Each response can contain at most 25 buttons. Button callbacks are delivered
only to the process that created them, and all remaining buttons are removed
when that process finishes.

### Follow-ups

```lua
discord.followUpNext()
```

Sends the next response as a follow-up as well: ephemeral in a guild, a DM
outside one. Useful for long-running scripts, so the reader can keep sending
`/input` without scrolling back to the original message.

`io.followupnext()` is the old name and still works, but new scripts should
use `discord.followUpNext()`.

## Layout

```
Main.js                    entry point
bin/                       luau + stylua binaries (fetched, gitignored)
scripts/fetch-tools.js     downloads/builds those binaries
scripts/commands.js        registers Discord commands
scripts/clearCommands.js   deregisters Discord commands
scripts/generateTunnel.js  prints a public URL for CALLBACK_URL
src/config.js              env, constants, luauBot.b64 validation
src/profiles.js            profiles/*.json loading and ordering
src/state.js               shared runtime state and task dispatch
src/chunks.js              zstd encode/decode and outbound chunking
src/fetchFile.js           size-capped, host-pinned downloads
src/filter.js              censoring and doc-markdown parsing
src/tools/                 luau CLI wrappers (compile, analyze, ast, format)
src/web/                   browser front end, mounted only when ENABLE_WEB
src/roblox/session.js      execution-session lifecycle and failover
src/http/                  express app, routes, chunk reassembly
src/discord/               client, replies, embeds, modals, handlers
```
