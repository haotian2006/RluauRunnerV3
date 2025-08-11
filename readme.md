A discord bot that executes Luau code in a Roblox game.

To set up copy and paste `LuauBot.luau` into workspace as a module script
workspace
    - LuauBot

Make sure to have these .env variables set:

```
BOT_TOKEN=Discord_Bot_Token
CLIENT_ID=Discord_Bot_Client_Id
PORT=Port_You_Want_to_Use_Default_3000
UNIVERSE_ID=Roblox_Universe_Id
PLACE_ID=Roblox_Place_Id
ROBLOX_API_KEY=Roblox_Api_Key
```
`TUNNEL_URL` is the ip that the bot should bind to.

Run `commands.js` to register the commands with Discord.
Run `Main.js` to start the bot.

For `ROBLOX_API_KEY` you need to create a new API key in the Roblox developer hub with the permissions of `luau-execution-sessions` and Experience Operations of `universe.place.luau-execution-session:write`
