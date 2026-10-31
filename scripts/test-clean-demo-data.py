#!/usr/bin/env python3
"""Synthetic safety/rollback checks for the demo cleanup utility; no live data."""
import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile

spec = importlib.util.spec_from_file_location("cleanup", Path(__file__).with_name("clean-demo-data.py"))
cleanup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cleanup)


def fixture(base):
    root = (base / "workspace").resolve()
    root.mkdir()
    (root / "attachments").mkdir()
    (root / "raw").mkdir()
    c = sqlite3.connect(root / "mail.sqlite")
    c.executescript("""
    PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;
    CREATE TABLE objects(kind TEXT,id TEXT,json BLOB,PRIMARY KEY(kind,id));
    CREATE TABLE messages(id TEXT PRIMARY KEY,account TEXT,canonical TEXT,json BLOB);
    CREATE TABLE vectors(id TEXT PRIMARY KEY,message TEXT REFERENCES messages(id) ON DELETE CASCADE,vector BLOB);
    CREATE TABLE index_state(message TEXT PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,hash TEXT);
    CREATE VIRTUAL TABLE mail_fts USING fts5(id UNINDEXED,body);
    CREATE TABLE cloud_context(singleton INTEGER PRIMARY KEY,device TEXT,clock INTEGER,importing INTEGER);
    INSERT INTO cloud_context VALUES(1,'device',10,0);
    CREATE TABLE cloud_journal(kind TEXT,id TEXT,payload BLOB,clock INTEGER,device TEXT,dirty INTEGER,PRIMARY KEY(kind,id));
    CREATE TRIGGER cloud_delete AFTER DELETE ON objects WHEN OLD.kind IN ('chat','chat-session','agent-memory','agent-artifact')
    BEGIN
      UPDATE cloud_context SET clock=clock+1;
      INSERT INTO cloud_journal SELECT OLD.kind,OLD.id,NULL,clock,device,1 FROM cloud_context WHERE singleton=1
      ON CONFLICT(kind,id) DO UPDATE SET payload=NULL,clock=excluded.clock,dirty=1;
    END;
    CREATE TRIGGER cloud_update AFTER UPDATE ON objects WHEN NEW.kind IN ('chat','chat-session','agent-memory','agent-artifact')
    BEGIN
      UPDATE cloud_context SET clock=clock+1;
      INSERT INTO cloud_journal SELECT NEW.kind,NEW.id,NEW.json,clock,device,1 FROM cloud_context WHERE singleton=1
      ON CONFLICT(kind,id) DO UPDATE SET payload=NEW.json,clock=excluded.clock,dirty=1;
    END;
    """)

    def obj(kind, oid, **data):
        c.execute("INSERT INTO objects VALUES(?,?,?)", (kind, oid, cleanup.encoded({"id": oid, **data})))

    shared = root / "attachments/shared"
    owned = root / "attachments/demo-owned"
    shared.write_bytes(b"real shared bytes")
    owned.write_bytes(b"demo cached bytes")
    obj("account", "demo", isDemo=True)
    obj("account", "real", isDemo=False, name="private fixture identity")
    obj("folder", "demo:INBOX", accountID="demo")
    obj("folder", "real:INBOX", accountID="real")
    obj("draft", "draft-demo", accountID="demo", attachments=[])
    obj("draft", "draft-real", accountID="real", attachments=[])
    obj("agent-run", "run-demo", isDemo=True, sourceMailIDs=["dm"], delegationID="deleg-demo")
    obj("agent-run", "run-mixed", isDemo=True, sourceMailIDs=["dm", "rm"])
    obj("delegation", "deleg-demo", processedMessageIDs=["demo:canonical"])
    obj("agent-artifact", "artifact-demo", runID="run-demo", sourceMailIDs=["dm"])
    obj("agent-artifact", "artifact-mixed", runID="run-mixed", sourceMailIDs=["dm", "rm"])
    obj("agent-decision", "decision-demo", runID="run-demo", artifactID="artifact-demo")
    obj("event", "event-demo", messageIDs=["dm"])
    obj("event", "event-real", messageIDs=["rm"])
    obj("responder", "responder-demo", accountID="demo")
    obj("responder-receipt", "receipt-demo", responderID="responder-demo", mailID="dm")
    obj("openui-interaction", "openui-demo", runID="run-demo")
    obj("contact-profile", "contact-demo", mailIDs=["dm"], accountIDs=["demo"])
    obj("contact-profile", "contact-mixed", mailIDs=["dm", "rm"], accountIDs=["demo", "real"])
    obj("attachment-text", "demo-owned", result={"text": "synthetic"})
    obj("attachment-text", "shared", result={"text": "synthetic"})
    obj("chat", "user-chat", text="Keep the user's words", messageIDs=["dm", "rm"], context={"accountID": "demo", "mailIDs": ["dm"], "runID": "run-demo"})
    obj("chat-session", "user-session", title="Keep user session", pinnedContext={"mailIDs": ["dm", "rm"]})
    obj("agent-memory", "user-memory", content="Keep user's memory", source="用户说明", sourceMailIDs=["dm"])
    obj("settings", "main", embeddingDirectory="private-model-dir")
    for mid, account, canonical, attachments in [
        ("dm", "demo", "demo:canonical", [{"id": "demo-owned", "storedPath": str(owned)}, {"id": "shared", "storedPath": str(shared)}]),
        ("rm", "real", "real:canonical", [{"id": "shared", "storedPath": str(shared)}]),
    ]:
        c.execute("INSERT INTO messages VALUES(?,?,?,?)", (mid, account, canonical, cleanup.encoded({"id": mid, "text": "synthetic private bytes " + mid, "attachments": attachments})))
        c.execute("INSERT INTO vectors VALUES(?,?,?)", (mid + "-vector", mid, b"finite fixture vector"))
        c.execute("INSERT INTO index_state VALUES(?,?)", (mid, "fixture-hash"))
        c.execute("INSERT INTO mail_fts VALUES(?,?)", (mid, "fixture source"))
        (root / "raw" / (cleanup.hashlib.sha256(mid.encode()).hexdigest() + ".eml")).write_bytes(b"fixture eml " + mid.encode())
    c.commit()
    return root, c


with tempfile.TemporaryDirectory(prefix="morrow-demo-cleanup-test-") as temp:
    base = Path(temp)
    root, c = fixture(base)
    before = cleanup.real_fingerprint(c, {"demo"})
    plan = cleanup.plan_cleanup(c, root)
    assert plan["messages"] == {"dm"}
    assert ("agent-run", "run-demo") in plan["remove"]
    assert ("agent-run", "run-mixed") not in plan["remove"]
    assert ("attachment-text", "shared") not in plan["remove"]
    assert ("chat", "user-chat") not in plan["remove"]
    assert ("agent-memory", "user-memory") not in plan["remove"]
    assert len(plan["files"]) == 2
    c.execute("BEGIN IMMEDIATE")
    backup = cleanup.apply_cleanup(c, root, plan, base / "backups")
    assert cleanup.real_fingerprint(c, {"demo"}) == before
    assert not c.execute("SELECT 1 FROM messages WHERE id='dm'").fetchone()
    assert (root / "attachments/shared").read_bytes() == b"real shared bytes"
    assert not (root / "attachments/demo-owned").exists()
    assert (backup / "quarantine/attachments/demo-owned").read_bytes() == b"demo cached bytes"
    assert c.execute("SELECT payload FROM cloud_journal WHERE kind='agent-artifact' AND id='artifact-demo'").fetchone() == (None,)
    chat = json.loads(c.execute("SELECT json FROM objects WHERE kind='chat'").fetchone()[0])
    assert chat["text"] == "Keep the user's words" and chat["messageIDs"] == ["rm"]
    memory = json.loads(c.execute("SELECT json FROM objects WHERE kind='agent-memory'").fetchone()[0])
    assert memory["content"] == "Keep user's memory" and memory["sourceMailIDs"] == []
    assert not cleanup.plan_cleanup(c, root)["accounts"]
    assert json.loads((backup / "manifest.json").read_bytes())["state"] == "committed"
    c.close()

with tempfile.TemporaryDirectory(prefix="morrow-demo-cleanup-rollback-test-") as temp:
    base = Path(temp)
    root, c = fixture(base)
    plan = cleanup.plan_cleanup(c, root)
    original = cleanup.real_fingerprint
    calls = 0

    def fail_second(*args):
        global calls
        calls += 1
        return original(*args) if calls == 1 else {"injected": "verification failure"}

    cleanup.real_fingerprint = fail_second
    c.execute("BEGIN IMMEDIATE")
    try:
        cleanup.apply_cleanup(c, root, plan, base / "backups")
        raise AssertionError("The injected verification failure must abort")
    except RuntimeError:
        pass
    finally:
        cleanup.real_fingerprint = original
    assert c.execute("SELECT 1 FROM messages WHERE id='dm'").fetchone()
    assert (root / "attachments/demo-owned").read_bytes() == b"demo cached bytes"
    manifest = next((base / "backups").glob("*/manifest.json"))
    assert json.loads(manifest.read_bytes())["state"] == "rolled_back"
    c.close()

print("PASS: precise demo ownership, mixed references, preserved user records, provider byte equality, shared files, tombstones, idempotency, transaction/file rollback")
