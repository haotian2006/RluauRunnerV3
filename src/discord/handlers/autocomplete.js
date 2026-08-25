const { getResources, resourceDisplayName } = require("../resources");

const MAX_CHOICES = 25;

async function handleAutocomplete(interaction) {
  if (interaction.commandName !== "tag") return;

  const focused = interaction.options.getFocused().toLowerCase();
  try {
    const files = await getResources();
    const choices = files
      .filter((f) =>
        resourceDisplayName(f.name).toLowerCase().includes(focused),
      )
      .slice(0, MAX_CHOICES)
      .map((f) => ({
        name: resourceDisplayName(f.name),
        value: f.name,
      }));
    await interaction.respond(choices);
  } catch (e) {
    await interaction.respond([]);
  }
}

module.exports = { handleAutocomplete };
