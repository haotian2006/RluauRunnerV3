class ImportError extends Error {
  constructor(message, status = 422) {
    super(message);
    this.name = "ImportError";
    this.status = status;
  }
}

// Files Rojo's sync rules can turn into instances; everything else is dropped on download.
const SYNCED = /\.(luau?|json|toml|txt|csv|rbxmx?)$/i;
const MAX_FILE_BYTES = 4 * 1024 * 1024;
const MAX_TOTAL_BYTES = 32 * 1024 * 1024;
const MAX_FILES = 5000;
const FETCH_TIMEOUT_MS = 30 * 1000;

module.exports = { ImportError, SYNCED, MAX_FILE_BYTES, MAX_TOTAL_BYTES, MAX_FILES, FETCH_TIMEOUT_MS };
