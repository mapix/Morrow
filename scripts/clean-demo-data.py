#!/usr/bin/env python3
"""Quarantine explicitly marked demo data. Dry run by default; app must be stopped.

No content-based classification is used. User chats, sessions, memories, settings,
and unrelated objects survive. An apply creates a SQLite backup and private plan
before touching rows/files; retained provider records are SHA-checked unchanged.
"""
from __future__ import annotations

import argparse
import collections
import datetime
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import uuid

CLOUD_KINDS = {"chat-session", "chat", "agent-memory", "contact", "agent-artifact"}
SOURCE_FIELDS = ("sourceMailIDs", "messageIDs", "mailIDs", "processedMessageIDs", "processedIDs")
PROTECTED_KINDS = {"chat", "chat-session", "agent-memory", "settings", "workspace-preferences"}


def encoded(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()


def digest_rows(rows):
    h = hashlib.sha256()
    count = 0
    for row in rows:
        count += 1
        for item in row:
            if isinstance(item, bytes):
                data, tag = item, b"b"
            else:
                data, tag = encoded(item), b"j"
            h.update(tag + len(data).to_bytes(8, "big") + data)
    return {"rows": count, "sha256": h.hexdigest()}


def file_sha(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            h.update(chunk)
    return h.hexdigest()


def real_fingerprint(c, demo_accounts):
    """Stream rows; never retain or print private provider message contents."""
    params = tuple(sorted(demo_accounts))
    where = "account NOT IN (" + ",".join("?" for _ in params) + ")" if params else "1"
    result = {"messages": digest_rows(c.execute("SELECT * FROM messages WHERE " + where + " ORDER BY id", params))}
    for table, fk in (("vectors", "message"), ("index_state", "message"), ("mail_fts", "id")):
        result[table] = digest_rows(c.execute(
            "SELECT t.* FROM " + table + " t JOIN messages m ON m.id=t." + fk +
            " WHERE " + where.replace("account", "m.account") + " ORDER BY m.id,t.rowid", params))
    result["accounts"] = digest_rows(c.execute(
        "SELECT kind,id,json FROM objects WHERE kind='account' ORDER BY id"
    ) if not params else c.execute(
        "SELECT kind,id,json FROM objects WHERE kind='account' AND id NOT IN (" +
        ",".join("?" for _ in params) + ") ORDER BY id", params))
    return result


def object_fingerprint(c, excluded):
    return digest_rows(row for row in c.execute("SELECT kind,id,json FROM objects ORDER BY kind,id")
                       if (row[0], row[1]) not in excluded)


def paths_in(value):
    if isinstance(value, dict):
        for key, item in value.items():
            if key in {"storedPath", "path"} and isinstance(item, str) and item:
                yield Path(item)
            else:
                yield from paths_in(item)
    elif isinstance(value, list):
        for item in value:
            yield from paths_in(item)


def plan_cleanup(c, root):
    objects = {(k, i): json.loads(j) for k, i, j in c.execute("SELECT kind,id,json FROM objects")}
    demo_accounts = {i for (k, i), j in objects.items() if k == "account" and j.get("isDemo") is True}
    demo_messages = {}
    for account in sorted(demo_accounts):
        for mid, canonical, data in c.execute("SELECT id,canonical,json FROM messages WHERE account=?", (account,)):
            demo_messages[mid] = (canonical, json.loads(data))
    mids = set(demo_messages)
    canonicals = {canonical for canonical, _ in demo_messages.values() if canonical}
    mail_refs = mids | canonicals
    attachment_ids = {a["id"] for _, j in demo_messages.values() for a in j.get("attachments", []) if a.get("id")}
    attachment_refs = attachment_ids | {canonical + ":attachment:" + str(slot)
        for canonical, j in demo_messages.values() for slot, _ in enumerate(j.get("attachments", []))}
    removed = set()
    updates = {}

    def refs(j):
        return {x for field in SOURCE_FIELDS for x in j.get(field, []) if isinstance(x, str)}

    def only_demo(j):
        found = refs(j)
        return bool(found) and found <= mail_refs

    for key, j in objects.items():
        kind, oid = key
        if kind == "account" and oid in demo_accounts:
            removed.add(key)
        elif kind in {"folder", "draft", "responder", "account-sync-state"} and j.get("accountID") in demo_accounts:
            removed.add(key)
        elif kind == "agent-run" and not (refs(j) - mail_refs) and (j.get("isDemo") is True or only_demo(j)):
            removed.add(key)
        elif kind == "contact-profile" and (only_demo(j) or (j.get("accountIDs") and set(j["accountIDs"]) <= demo_accounts)):
            removed.add(key)

    # A delegation linked exclusively to demo runs is part of their execution.
    runs = [(i, j) for (k, i), j in objects.items() if k == "agent-run"]
    for key, j in objects.items():
        if key[0] != "delegation":
            continue
        associated = [rid for rid, run in runs if run.get("delegationID") == key[1]]
        if associated and all(("agent-run", rid) in removed for rid in associated) and not (refs(j) - mail_refs):
            removed.add(key)

    # Fixed-point closure follows typed ownership links, never text/addresses.
    while True:
        previous = len(removed)
        for key, j in objects.items():
            kind, _ = key
            if key in removed or kind in PROTECTED_KINDS:
                continue
            has_real_refs = bool(refs(j) - mail_refs)
            if kind == "agent-artifact" and not has_real_refs and (("agent-run", j.get("runID")) in removed or only_demo(j)):
                removed.add(key)
            elif kind == "agent-decision" and any((k, j.get(f)) in removed for k, f in (
                    ("agent-run", "runID"), ("agent-artifact", "artifactID"), ("delegation", "delegationID"))):
                removed.add(key)
            elif kind == "responder-receipt" and not (j.get("mailID") and j["mailID"] not in mids) and (
                    j.get("mailID") in mids or ("responder", j.get("responderID")) in removed):
                removed.add(key)
            elif kind == "openui-interaction" and ("agent-run", j.get("runID")) in removed:
                removed.add(key)
            elif kind == "event" and not has_real_refs and (
                    only_demo(j) or ("delegation", j.get("delegationID")) in removed):
                removed.add(key)
        if len(removed) == previous:
            break

    # Never remove a preview/file still referenced by a real email or retained draft.
    retained_attachment_ids = set()
    retained_paths = set()
    for mid, account, data in c.execute("SELECT id,account,json FROM messages"):
        if account in demo_accounts:
            continue
        message = json.loads(data)
        retained_attachment_ids.update(a["id"] for a in message.get("attachments", []) if a.get("id"))
        retained_paths.update(p.resolve() for p in paths_in(message))
        retained_paths.add((root / "raw" / (hashlib.sha256(mid.encode()).hexdigest() + ".eml")).resolve())
    for key, j in objects.items():
        if key not in removed:
            retained_paths.update(p.resolve() for p in paths_in(j))
            retained_attachment_ids.update(a["id"] for a in j.get("attachments", []) if a.get("id"))
        elif key[0] == "draft":
            attachment_ids.update(a["id"] for a in j.get("attachments", []) if a.get("id"))
    removed.update(("attachment-text", aid) for aid in attachment_ids - retained_attachment_ids
                   if ("attachment-text", aid) in objects)
    removed_contacts = {i for k, i in removed if k == "contact-profile"}
    deleted_ids = collections.defaultdict(set)
    for kind, oid in removed:
        deleted_ids[kind].add(oid)

    def prune(j):
        if isinstance(j, list):
            return [prune(item) for item in j]
        if not isinstance(j, dict):
            return j
        out = {}
        for field, value in j.items():
            if field in SOURCE_FIELDS and isinstance(value, list):
                out[field] = [x for x in value if x not in mail_refs]
            elif field == "accountIDs" and isinstance(value, list):
                out[field] = [x for x in value if x not in demo_accounts]
            elif field == "attachmentIDs" and isinstance(value, list):
                out[field] = [x for x in value if x not in attachment_refs]
            elif field in {"accountID", "mailID", "runID", "draftID", "artifactID", "delegationID", "responderID", "contactEmail"}:
                obsolete = ((field == "accountID" and value in demo_accounts) or
                            (field == "mailID" and value in mail_refs) or
                            (field == "contactEmail" and value in removed_contacts) or
                            (field == "runID" and value in deleted_ids["agent-run"]) or
                            (field == "draftID" and value in deleted_ids["draft"]) or
                            (field == "artifactID" and value in deleted_ids["agent-artifact"]) or
                            (field == "delegationID" and value in deleted_ids["delegation"]) or
                            (field == "responderID" and value in deleted_ids["responder"]))
                if not obsolete:
                    out[field] = value
            elif field == "claims" and isinstance(value, list):
                out[field] = [prune(x) for x in value if x.get("mailID") not in mail_refs]
            elif field == "artifactIDs" and isinstance(value, list):
                out[field] = [x for x in value if x not in deleted_ids["agent-artifact"]]
            else:
                out[field] = prune(value)
        return out

    for key, j in objects.items():
        if key in removed:
            continue
        # Excluded provider records stay byte-identical. User objects lose only
        # known demo references; content, drafts, preferences and assets survive.
        if key[0] in {"account", "folder", "draft", "responder", "settings", "account-sync-state"}:
            continue
        value = prune(j)
        if value != j:
            updates[key] = encoded(value)

    candidates = set()
    for mid, (_, j) in demo_messages.items():
        candidates.add(root / "raw" / (hashlib.sha256(mid.encode()).hexdigest() + ".eml"))
        candidates.update(paths_in(j))
    for key in removed:
        candidates.update(paths_in(objects[key]))
    # Only owned cached mail files are quarantined. Chat files are user assets.
    files = []
    for path in sorted(candidates, key=str):
        resolved = path.resolve()
        if resolved in retained_paths or not path.exists() or path.is_symlink() or not path.is_file():
            continue
        if not any(resolved.is_relative_to(root / name) for name in ("raw", "attachments")):
            continue
        files.append({"relative_path": str(resolved.relative_to(root)), "bytes": resolved.stat().st_size, "sha256": file_sha(resolved)})
    summary = {
        "demo_accounts": len(demo_accounts), "demo_messages": len(mids),
        "retained_provider_messages": c.execute("SELECT count(*) FROM messages").fetchone()[0] - len(mids),
        "remove_objects": dict(sorted(collections.Counter(k for k, _ in removed).items())),
        "prune_references": dict(sorted(collections.Counter(k for k, _ in updates).items())),
        "quarantine_files": len(files), "quarantine_bytes": sum(f["bytes"] for f in files),
        "retained_user_sessions": sum(k == "chat-session" for k, _ in objects),
        "retained_user_memories": sum(k == "agent-memory" for k, _ in objects),
    }
    return {"accounts": demo_accounts, "messages": mids, "remove": removed, "updates": updates, "files": files, "summary": summary}


def private_json(path, value):
    temp = path.with_suffix(".tmp")
    temp.write_bytes(encoded(value))
    os.chmod(temp, 0o600)
    os.replace(temp, path)


def apply_cleanup(c, root, plan, backup_parent):
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup = backup_parent / (stamp + "-" + uuid.uuid4().hex[:8])
    backup.mkdir(parents=True, mode=0o700)
    os.chmod(backup, 0o700)
    backup_path = backup / "mail.sqlite"
    # The caller holds BEGIN IMMEDIATE, so no writer can alter this snapshot.
    source = sqlite3.connect("file:" + str(root / "mail.sqlite") + "?mode=ro", uri=True)
    target = sqlite3.connect(backup_path)
    try:
        source.backup(target)
    finally:
        target.close()
        source.close()
    os.chmod(backup_path, 0o600)
    real_before = real_fingerprint(c, plan["accounts"])
    excluded = plan["remove"] | set(plan["updates"])
    kept_before = object_fingerprint(c, excluded)
    manifest = {
        "version": 1, "state": "prepared", "created_utc": stamp,
        "root": str(root), "summary": plan["summary"],
        "removed": [list(x) for x in sorted(plan["remove"])],
        "pruned": [list(x) for x in sorted(plan["updates"])],
        "message_ids": sorted(plan["messages"]), "files": plan["files"],
        "real_records": real_before, "retained_objects": kept_before,
    }
    manifest_path = backup / "manifest.json"
    private_json(manifest_path, manifest)
    moved = []
    committed = False
    try:
        for f in plan["files"]:
            src, dst = root / f["relative_path"], backup / "quarantine" / f["relative_path"]
            if src.is_symlink() or file_sha(src) != f["sha256"]:
                raise RuntimeError("A planned cache file changed; cleanup stopped.")
            dst.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
            os.replace(src, dst)
            moved.append((src, dst))
        for mid in sorted(plan["messages"]):
            c.execute("DELETE FROM vectors WHERE message=?", (mid,))
            c.execute("DELETE FROM index_state WHERE message=?", (mid,))
            c.execute("DELETE FROM mail_fts WHERE id=?", (mid,))
            c.execute("DELETE FROM messages WHERE id=?", (mid,))
        has_journal = c.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='cloud_journal'").fetchone() is not None
        for kind, oid in sorted(plan["remove"]):
            c.execute("DELETE FROM objects WHERE kind=? AND id=?", (kind, oid))
            if has_journal and kind in CLOUD_KINDS:
                # Existing triggers create current deletion tombstones. Never
                # erase them, since another device may have the previous record.
                c.execute("UPDATE cloud_journal SET payload=NULL,dirty=1 WHERE kind=? AND id=?", (kind, oid))
        for (kind, oid), payload in sorted(plan["updates"].items()):
            c.execute("UPDATE objects SET json=? WHERE kind=? AND id=?", (payload, kind, oid))
        if real_fingerprint(c, plan["accounts"]) != real_before or object_fingerprint(c, excluded) != kept_before:
            raise RuntimeError("Retained provider/user record verification failed; cleanup rolled back.")
        if c.execute("PRAGMA foreign_key_check").fetchone() is not None:
            raise RuntimeError("Foreign-key verification failed; cleanup rolled back.")
        if c.execute("PRAGMA quick_check").fetchone()[0] != "ok":
            raise RuntimeError("SQLite integrity verification failed; cleanup rolled back.")
        c.commit()
        committed = True
        manifest["state"] = "committed"
        manifest["verified_real_records_unchanged"] = True
        manifest["verified_retained_objects_unchanged"] = True
        private_json(manifest_path, manifest)
        return backup
    except BaseException:
        if committed:
            # A receipt write failure after COMMIT must not restore quarantined
            # files against an already committed database. The prepared backup
            # and manifest still contain a complete recovery plan.
            raise RuntimeError("Cleanup committed; final receipt write failed. The prepared backup remains available.")
        c.rollback()
        for src, dst in reversed(moved):
            if dst.exists() and not src.exists():
                os.replace(dst, src)
        manifest["state"] = "rolled_back"
        private_json(manifest_path, manifest)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True, help="Exact existing Morrow data directory")
    parser.add_argument("--apply", action="store_true", help="Apply the private backed-up plan; default only reports counts")
    parser.add_argument("--backup-dir", type=Path, help="Private backup parent, outside the data root")
    args = parser.parse_args()
    root = args.root.expanduser().resolve()
    if not (root / "mail.sqlite").is_file():
        parser.error("The specified root has no existing mail.sqlite.")
    if (root / "mail.sqlite").is_symlink():
        parser.error("The workspace database must not be a symbolic link.")
    backup_parent = (args.backup_dir or root.parent / "demo-cleanup-backups").expanduser().resolve()
    if backup_parent.is_relative_to(root):
        parser.error("Backup directory must be outside the workspace data root.")
    if args.apply and sys.platform == "darwin":
        p = subprocess.run(["/usr/bin/pgrep", "-x", "Morrow"], capture_output=True)
        if p.returncode == 0:
            parser.error("Morrow is running. Stop the app before applying a cleanup.")
    c = sqlite3.connect("file:" + str(root / "mail.sqlite") + ("?mode=rw" if args.apply else "?mode=ro"), uri=True)
    try:
        c.execute("PRAGMA foreign_keys=ON")
        c.execute("PRAGMA busy_timeout=5000")
        if args.apply:
            c.execute("BEGIN IMMEDIATE")
        plan = plan_cleanup(c, root)
        result = {"mode": "apply" if args.apply else "dry-run", **plan["summary"]}
        if args.apply and plan["accounts"]:
            backup = apply_cleanup(c, root, plan, backup_parent)
            result.update({"verified_real_records_unchanged": True, "backup": str(backup)})
        elif args.apply:
            c.rollback()
            result["already_clean"] = True
        print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    finally:
        c.close()


if __name__ == "__main__":
    main()
