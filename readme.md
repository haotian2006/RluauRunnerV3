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
      - LoadEnv
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

For `apiKey` you need to create an API key in the Roblox developer hub with the
permission `luau-execution-sessions` and Experience Operations of
`universe.place.luau-execution-session:write`.

### 3. Tool binaries

`luau-compile`, `luau-analyze`, `luau-ast`, `stylua` and `lune` live in `bin/`
and are downloaded from the upstream GitHub releases:

```
npm run fetch-tools            # fetch whatever is missing
npm run fetch-tools -- --force # re-download, e.g. to pick up a new Luau release
```

This runs automatically on `npm install`. Windows, Linux and macOS (x64 and
arm64) are all handled;

### 4. `.env`

```
BOT_TOKEN=Discord_Bot_Token
CLIENT_ID=Discord_Bot_Client_Id
PORT=Port_You_Want_to_Use_Default_3000
CALLBACK_URL=http://your-host:3000
ENABLE_DISCORD=true(OPTIONAL, default true)
ENABLE_WEB=false(OPTIONAL, default false)
ENABLE_LOCAL_EXEC=false(OPTIONAL, default false)
LOCAL_TIMEOUT_MS=30000(OPTIONAL, default 30000 / 30 seconds for automatically routed Lune scripts)
LOCAL_FORCED_TIMEOUT_MS=60000(OPTIONAL, default 60000 / 1 minute for --!lune scripts)
LOCAL_MAX_CONCURRENT=2(OPTIONAL, default 2, global cap on concurrent Lune runs)
LOCAL_MEMORY_LIMIT_MB=256(OPTIONAL, default 256, Linux only)
LOCAL_CPU_QUOTA_PERCENT=0(OPTIONAL, default 0/disabled, Linux only, needs systemd)
MAX_ROBLOX_WORKERS=4(OPTIONAL, default 4, per enabled profile)
STORE_COMPILE_SOURCE=false(OPTIONAL, default false, adds a "see raw" link to results)
COMPILE_SOURCE_TTL_MS=86400000(OPTIONAL, default 86400000 / 24 hours)
COMPILE_SOURCE_MAX_BYTES=1048576(OPTIONAL, default 1 MB per source)
COMPILE_SOURCE_TOTAL_BYTES=209715200(OPTIONAL, default 200 MB for all stored sources)
PLAYGROUND_URL=https://haotian2006.github.io/LuauBotSite/playground.html(OPTIONAL, blank disables the redirect)
TRUST_PROXY=false(OPTIONAL, default false)
FORM_ID=Google_Form_Id(OPTIONAL)
FORM_ENTRY_NAME=entry.0000000000(OPTIONAL)
FORM_ENTRY_USER_ID=entry.0000000000(OPTIONAL)
FORM_ENTRY_COMMAND=entry.0000000000(OPTIONAL)
FORM_ENTRY_DATA=entry.0000000000(OPTIONAL)
```

`CALLBACK_URL` is the address the Roblox session sends its requests back to.
It must include the scheme and no trailing slash.

`STORE_COMPILE_SOURCE` is covered in [Source links](#source-links-optional).

Roblox credentials are **not** read from `.env` any more. They live in
`profiles/`. The `FORM_*` variables are covered in
[Usage logging](#usage-logging-optional).

### 5. Run

```
npm install                 # also fetches the tool binaries
npm run register-commands   # register slash + context-menu commands (once)
npm start                   # start the bot
```

Other helpers:

| Command | What it does |
| --- | --- |
| `npm run clear-commands` | Deregister every command from Discord |
| `npm run tunnel` | Print a public URL for `CALLBACK_URL` via tunnelmole |
| `npm run fetch-tools` | Re-fetch `bin/` binaries (`-- --force` to redownload) |

## Front ends

`ENABLE_DISCORD` and `ENABLE_WEB` choose which front ends run. Startup fails if
both are disabled.

`ENABLE_WEB` defaults to **false** deliberately: the web routes execute
arbitrary Luau for anyone who can reach the port, with no authentication. When
it is off those routes are never registered at all. With `ENABLE_DISCORD=false`
the bot never logs in and `BOT_TOKEN` is not required, which is the setup for
running the web runner alone.

`TRUST_PROXY` defaults to **false**: without a real reverse proxy in front of
the app, trusting `X-Forwarded-For` lets a direct client spoof it and rotate
their apparent IP on every request, defeating the web runner's per-IP rate
limiting and abuse tracking outright. Only set this (to a trusted hop count or
proxy IP/CIDR - see [Express's `trust proxy` docs](https://expressjs.com/en/guide/behind-proxies.html))
if you're actually running behind a reverse proxy that overwrites that header
itself.

`LOCAL_MAX_CONCURRENT` is a global cap shared by every user, not per-user (a
separate per-actor cap of 10 also exists, hardcoded, and only matters if the
global cap is raised above it). `LOCAL_CPU_QUOTA_PERCENT` throttles each Lune
job to that percent of one core via `systemd-run --scope` (Linux only, needs
systemd; no-op elsewhere). Size these together: on a small box, a high
`LOCAL_MAX_CONCURRENT` with no CPU quota lets sandboxed scripts starve the
bot's own event loop under load.

## Execution

Both front ends share one Roblox worker pool. The pool scales up when tasks are
queued, is capped by `MAX_ROBLOX_WORKERS` per enabled profile (default 4 each,
so two enabled profiles allow up to 8 workers total), and gives responsive
workers one new task per poll, so another task can run while existing code is
yielding. A non-yielding script can temporarily pause tasks sharing its
worker, but queued work moves to a responsive or replacement worker.

## Source links (optional)

With `STORE_COMPILE_SOURCE=true`, every Discord compile writes the source it is
about to run to `<tmp>/rluau-sources/` and the result embed gains a **see raw**
link. Off by default, since that is user code sitting on the host disk.

What is stored is what actually ran, not what was typed: a script routed to Lune
is desugared first ([`src/local/constDesugar.js`](src/local/constDesugar.js)),
and the stored copy is replaced with the desugared one.

Two routes serve it:

- `GET /raw/:id` returns the text as `text/plain`.
- `GET /source/:id` is what the embed links to. When the playground is usable
  (`ENABLE_WEB=true` and `PLAYGROUND_URL` set) it redirects to
  `PLAYGROUND_URL?source=<id>`; otherwise it serves the text itself.

Only the id travels to the playground. The playground already knows this host
address, so it builds the `/raw/:id` URL and fetches the code itself.

A miss is not an HTTP error: `/raw/:id` answers 200 with runnable Luau -
`error("EXPIRED")` for an id whose source is gone, `error("DOES NOT EXIST")`
for one that was never stored - so the playground can drop the reply straight
into its editor. `X-Source-Status: expired|unknown` marks those replies for
anything that needs to tell them apart.

Opening a source in the playground needs the playground to read that `source`
query parameter and fetch `/raw/<id>`. Without that support on the site, set
`PLAYGROUND_URL=` (blank) so links serve plain text instead.

The id is a UUID and is the only thing guarding the source, so treat the link as
the secret: anyone holding it can read that script until it expires.

Three limits bound the store, all tunable in `.env`: `COMPILE_SOURCE_TTL_MS`
(24h default - the link sits in a Discord message forever, so a short TTL means
most clicks 404), `COMPILE_SOURCE_MAX_BYTES` (1 MB, above which no link is
offered at all), and `COMPILE_SOURCE_TOTAL_BYTES` (200 MB, oldest evicted
first). Nothing survives a restart.

## Usage logging (optional)

Usage is logged by submitting to a Google Form. It is **off unless `FORM_ID`
is set**. Nothing is sent anywhere without it, and failures are always
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

**2. Get `FORM_ID`.** Open the form and read it out of the address bar. It is
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
