function isUserRestricted(interaction) {
  if (!interaction.inGuild()) return false;
  const member = interaction.member;
  if (!member) return false;
  if (typeof member.isCommunicationDisabled === "function") {
    if (member.isCommunicationDisabled()) return true;
  } else if (member.communication_disabled_until) {
    if (new Date(member.communication_disabled_until) > new Date()) return true;
  }
  const perms = interaction.memberPermissions;
  if (perms && !perms.has("SendMessages")) return true;
  return false;
}

function wrapEphemeral(interaction) {
  if (!isUserRestricted(interaction)) return;
  const origDefer = interaction.deferReply.bind(interaction);
  const origReply = interaction.reply.bind(interaction);
  interaction.deferReply = (opts = {}) =>
    origDefer({ ...opts, ephemeral: true });
  interaction.reply = (opts = {}) => {
    console.log("User is restricted, forcing ephemeral reply.");
    if (typeof opts === "string")
      return origReply({ content: opts, ephemeral: true });
    return origReply({ ...opts, ephemeral: true });
  };
}

module.exports = { wrapEphemeral };
