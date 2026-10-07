#!/bin/sh
set -eu

umask 077

settings_path="${LIVESYNC_SETTINGS_PATH:-/data/.livesync/settings.json}"
settings_dir=$(dirname "$settings_path")
interval="${LIVESYNC_INTERVAL_SECONDS:-}"
mkdir -p "$settings_dir"

if [ "${LIVESYNC_REWRITE_SETTINGS:-false}" = "true" ] || [ ! -s "$settings_path" ]; then
    : "${COUCHDB_URI:?COUCHDB_URI is required}"
    : "${COUCHDB_USER:?COUCHDB_USER is required}"
    : "${COUCHDB_PASSWORD:?COUCHDB_PASSWORD is required}"
    : "${COUCHDB_DBNAME:?COUCHDB_DBNAME is required}"

    node - "$settings_path" <<'NODE'
const fs = require("node:fs");

const settingsPath = process.argv[2];
const env = process.env;
const encrypt = env.LIVESYNC_ENCRYPT !== "false";
const passphrase = env.LIVESYNC_PASSPHRASE || "";
const customChunkSize = Number(env.LIVESYNC_CUSTOM_CHUNK_SIZE || "0");

if (encrypt && passphrase.length === 0) {
  throw new Error("LIVESYNC_PASSPHRASE is required when LIVESYNC_ENCRYPT is not false");
}
if (!Number.isInteger(customChunkSize) || customChunkSize < 0) {
  throw new Error("LIVESYNC_CUSTOM_CHUNK_SIZE must be a non-negative integer");
}

const settings = {
  couchDB_URI: env.COUCHDB_URI,
  couchDB_USER: env.COUCHDB_USER,
  couchDB_PASSWORD: env.COUCHDB_PASSWORD,
  couchDB_DBNAME: env.COUCHDB_DBNAME,
  liveSync: true,
  syncOnSave: true,
  syncOnStart: true,
  encrypt,
  passphrase,
  E2EEAlgorithm: env.LIVESYNC_E2EE_ALGORITHM || "v2",
  usePathObfuscation: env.LIVESYNC_USE_PATH_OBFUSCATION === "true",
  encryptInternalMetadata: env.LIVESYNC_ENCRYPT_INTERNAL_METADATA === "true",
  useRequestAPI: env.LIVESYNC_USE_REQUEST_API === "true",
  usePluginSync: false,
  usePluginSyncV2: env.LIVESYNC_USE_PLUGIN_SYNC_V2 === "true",
  customChunkSize,
  isConfigured: true,
  suspendFileWatching: false,
  maxMTimeForReflectEvents: 0,
};

const temporaryPath = `${settingsPath}.tmp`;
fs.writeFileSync(temporaryPath, `${JSON.stringify(settings, null, 2)}\n`, {
  encoding: "utf8",
  mode: 0o600,
});
fs.renameSync(temporaryPath, settingsPath);
NODE
fi

if [ -n "$interval" ]; then
    case "$interval" in
        ''|*[!0-9]*|0)
            echo "LIVESYNC_INTERVAL_SECONDS must be empty or a positive integer" >&2
            exit 2
            ;;
    esac
    set -- --interval "$interval" "$@"
fi

exec /usr/local/bin/livesync-cli "$@"
