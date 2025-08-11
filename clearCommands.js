require('dotenv').config();
const { REST, Routes } = require('discord.js');

const rest = new REST({ version: '10' }).setToken(process.env.BOT_TOKEN);

(async () => {
  try {
    console.log('deleting');

    await rest.put(
      Routes.applicationCommands(process.env.CLIENT_ID),
      { body: [] } 
    );

    console.log('deleted');
  } catch (error) {
    console.error(error);
  }
})();
