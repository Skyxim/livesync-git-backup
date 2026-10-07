#!/bin/sh
set -eu

umask 077

settings_path="${LIVESYNC_SETTINGS_PATH:-/data/.livesync/settings.json}"
settings_dir=$(dirname "$settings_path")
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

if (encrypt && passphrase.length === 0) {
  throw new Error("LIVESYNC_PASSPHRASE is required when LIVESYNC_ENCRYPT is not false");
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
  usePluginSync: false,
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

exec /usr/local/bin/livesync-cli "$@"
