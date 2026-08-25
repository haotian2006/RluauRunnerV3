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
FORM_ENTRY_NAME=entry.0000000000(OPTIONAL)
FORM_ENTRY_USER_ID=entry.0000000000(OPTIONAL)
FORM_ENTRY_COMMAND=entry.0000000000(OPTIONAL)
FORM_ENTRY_DATA=entry.0000000000(OPTIONAL)
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

### Usage logging (optional)

Usage is logged by submitting to a Google Form. It is **off unless `FORM_ID`
is set** — nothing is sent anywhere without it, and failures are always
swallowed, so logging can never break a command.

**1. Build the form.** Create a Google Form with four questions, in any order:

| Question | Type | Receives |
| --- | --- | --- |
| Name | Short answer | Discord username, `web`, or `BOT` |
| User id | Short answer | Discord user id, the hashed IP for web runs, or `0` for bot events |
| Command | Short answer | `compile`, `ping`, `tag`, `format`, … or the bot event name |
| Data | **Paragraph** | Free-form detail, e.g. `Code length: 240 characters` |

Make Data a paragraph question. Entries are truncated at 20,000 characters,
which a short-answer question will reject.

**2. Get `FORM_ID`.** Open the form and read it out of the address bar — it is
the segment after `/d/e/`:

```
https://docs.google.com/forms/d/e/1FAIpQLSc.../viewform
                                  ^^^^^^^^^^^^ FORM_ID
```

**3. Get the four `FORM_ENTRY_*` ids.** In the form editor choose **⋮ → Get
pre-filled link**, type a recognisable dummy answer into each question
(`AAA`, `BBB`, `CCC`, `DDD`), press **Get link**, then **Copy link**. The
copied URL contains one `entry.<id>` per question:

```
...viewform?usp=pp_url&entry.1569623480=AAA&entry.1249804528=BBB&entry.726094871=CCC&entry.182293982=DDD
```

Match each id to the answer you typed and set them accordingly:

```
FORM_ENTRY_NAME=entry.1569623480      # the id whose value was AAA
FORM_ENTRY_USER_ID=entry.1249804528   # BBB
FORM_ENTRY_COMMAND=entry.726094871    # CCC
FORM_ENTRY_DATA=entry.182293982       # DDD
```

The defaults built into the code are the ids of the form this bot was written
against and will not match your form, so set all four if you enable logging.
A wrong id is silently dropped by Google rather than reported.

`CALLBACK_URL` is the address the Roblox session sends its requests back to.
It must include the scheme and no trailing slash.

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

