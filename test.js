const zstd = require("zstd-napi")

let str = 'KLUv/SAvdQAAMGhlbGxvMAIAYIgXaAE='

const data = Buffer.from(str,'base64');
const decompressed = zstd.decompress(data);
console.log(decompressed.toString());