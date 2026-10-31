#!/usr/bin/env python3
"""Move an existing workspace without duplicating it; preserve mail and vector content.

Dry-run unless --apply. The application must be stopped. Credentials remain in
the existing Keychain namespace. Only owned absolute file references change.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import subprocess

PATH_FIELDS = {"storedPath", "path", "embeddingDirectory", "localPath"}

def rewrite(value, mappings):
    if isinstance(value, list):
        return [rewrite(item, mappings) for item in value]
    if not isinstance(value, dict):
        return value
    result = {}
    for key, item in value.items():
        if key in PATH_FIELDS and isinstance(item, str):
            for old, new in mappings:
                if item == old or item.startswith(old + "/"):
                    item = new + item[len(old):]
                    break
            result[key] = item
        else:
            result[key] = rewrite(item, mappings)
    return result

def content_digest(connection, reverse_mappings=()):
    digest = hashlib.sha256()
    counts = {}
    for table in ["messages", "objects", "vectors", "index_state", "mail_fts"]:
        rows = connection.execute("SELECT * FROM " + table + " ORDER BY rowid")
        columns = [column[0] for column in rows.description]
        count = 0
        for row in rows:
            count += 1
            for name, item in zip(columns, row):
                if name == "json":
                    item = json.dumps(rewrite(json.loads(item), reverse_mappings), sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode()
                elif not isinstance(item, bytes):
                    item = json.dumps(item, ensure_ascii=False).encode()
                digest.update(len(item).to_bytes(8, "big") + item)
        counts[table] = count
    return digest.hexdigest(), counts

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--from", dest="source", required=True, type=Path)
    parser.add_argument("--to", dest="destination", required=True, type=Path)
    parser.add_argument("--old-app", type=Path)
    parser.add_argument("--new-app", type=Path)
    parser.add_argument("--defaults-domain", default="app.smail.desktop")
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    source, destination = args.source.expanduser().resolve(), args.destination.expanduser().resolve()
    if destination.exists() or not (source / "mail.sqlite").is_file() or source.is_symlink():
        parser.error("Source must contain a workspace; destination must not exist.")
    if destination.is_relative_to(source) or source.is_relative_to(destination):
        parser.error("Workspaces cannot be nested.")
    if args.apply and subprocess.run(["pgrep", "-x", "Smail"], capture_output=True).returncode == 0:
        parser.error("Stop the existing application before migrating.")
    if args.apply and subprocess.run(["pgrep", "-x", "Morrow"], capture_output=True).returncode == 0:
        parser.error("Stop Morrow before migrating.")
    mappings = [(str(source), str(destination))]
    if args.old_app and args.new_app:
        mappings.append((str(args.old_app.resolve()), str(args.new_app.resolve())))
    connection = sqlite3.connect((source / "mail.sqlite").as_uri() + ("?mode=rw" if args.apply else "?mode=ro"), uri=True)
    original_digest, counts = content_digest(connection)
    if connection.execute("PRAGMA quick_check").fetchone()[0] != "ok":
        raise RuntimeError("Workspace integrity check failed.")
    if not args.apply:
        print(json.dumps({"mode": "dry-run", "counts": counts, "duplicatesCreated": 0}))
        connection.close(); return
    if args.new_app and not args.new_app.exists():
        parser.error("Install the new app before applying application path mappings.")
    connection.execute("PRAGMA wal_checkpoint(TRUNCATE)"); connection.close()
    destination.parent.mkdir(parents=True, exist_ok=True)
    if source.stat().st_dev != destination.parent.stat().st_dev:
        raise RuntimeError("Move requires the same filesystem; no fallback copy is performed.")
    os.rename(source, destination)
    committed = False
    try:
        connection = sqlite3.connect(destination / "mail.sqlite")
        connection.execute("BEGIN IMMEDIATE")
        changes = {}
        for table, key in [("messages", "id"), ("objects", "rowid")]:
            changed = 0
            for identifier, payload in connection.execute("SELECT " + key + ",json FROM " + table):
                old = json.loads(payload); new = rewrite(old, mappings)
                if new != old:
                    connection.execute("UPDATE " + table + " SET json=? WHERE " + key + "=?", (json.dumps(new, ensure_ascii=False, separators=(",", ":")).encode(), identifier)); changed += 1
            changes[table] = changed
        verified_digest, verified_counts = content_digest(connection, [(new, old) for old, new in mappings])
        if (verified_digest, verified_counts) != (original_digest, counts):
            raise RuntimeError("Content preservation verification failed.")
        if connection.execute("PRAGMA quick_check").fetchone()[0] != "ok":
            raise RuntimeError("Migrated workspace integrity check failed.")
        connection.commit(); committed = True; connection.close()
        subprocess.run(["defaults", "write", args.defaults_domain, "SmailWorkspaceRoot", "-string", str(destination)], check=True)
        print(json.dumps({"mode": "moved", "counts": counts, "pathReferencesUpdated": changes, "contentPreserved": True, "keychainUnchanged": True, "duplicatesCreated": 0}))
    except BaseException:
        if not committed:
            try: connection.rollback(); connection.close()
            except Exception: pass
            os.rename(destination, source)
        raise

if __name__ == "__main__":
    main()
