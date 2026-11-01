"""Scoped, read-only mail data for coding in the Morrow sandbox.

query(sql, max_rows=1000) -> {columns, rows, truncated, coverage}
Tables: mail_index (fast metadata), mail (same columns plus lazy full text),
contacts (interaction counts), accounts (nonsecret addresses).
Use SQL WHERE/GROUP BY/JOIN or Python's standard library; print conclusions
and actual source IDs, not entire data dumps. Large results must be paged by
id/date. Text cells above 64 KiB and responses above 512 KiB are marked truncated.
"""
import json
import socket
from pathlib import Path


def query(sql, max_rows=1000):
    request = json.dumps({"sql": sql, "max_rows": max_rows}, ensure_ascii=False).encode("utf-8") + b"\n"
    if len(request) > 65536:
        raise ValueError("Mail data request exceeds budget")
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as channel:
        channel.settimeout(10)
        channel.connect(str(Path(__file__).resolve().parent / "mail-data.sock"))
        channel.sendall(request)
        with channel.makefile("rb") as stream:
            response = stream.readline(2 * 1024 * 1024)
    result = json.loads(response)
    if "error" in result:
        raise ValueError(result["error"])
    return result
