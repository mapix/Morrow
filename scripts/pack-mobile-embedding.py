#!/usr/bin/env python3
"""Pack exact EmbeddingGemma 2 language weights without media encoders.

No quantization or conversion is performed. The checksum manifest records the
source; all retained tensors preserve name, dtype, shape, and byte content.
"""
import argparse
import hashlib
import json
import shutil
import struct
from pathlib import Path


def sha256(path):
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(8 * 1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    checkpoint = json.loads((args.source / "smail-manifest.json").read_text())
    assert checkpoint["repo"] == "mlx-community/embeddinggemma-2-bf16"
    assert checkpoint["revision"] == "1a4ffddb7905d3f63486748deabe091a01fb6201"
    source_model = args.source / "model.safetensors"
    output_model = args.output / "model.safetensors"
    with source_model.open("rb") as source:
        header_size = struct.unpack("<Q", source.read(8))[0]
        header = json.loads(source.read(header_size))
        retained = {key: item for key, item in header.items() if key.startswith("language_model.")}
        assert retained, "No language tensors found"
        new_header, cursor = {}, 0
        for key, value in retained.items():
            length = value["data_offsets"][1] - value["data_offsets"][0]
            new_header[key] = dict(value, data_offsets=[cursor, cursor + length])
            cursor += length
        if "__metadata__" in header:
            new_header["__metadata__"] = header["__metadata__"]
        encoded = json.dumps(new_header, separators=(",", ":")).encode()
        encoded += b" " * (-len(encoded) % 8)
        with output_model.open("wb") as output:
            output.write(struct.pack("<Q", len(encoded)))
            output.write(encoded)
            for value in retained.values():
                start, end = value["data_offsets"]
                source.seek(8 + header_size + start)
                remaining = end - start
                while remaining:
                    chunk = source.read(min(8 * 1024 * 1024, remaining))
                    assert chunk, "Truncated source tensor"
                    output.write(chunk)
                    remaining -= len(chunk)
    for path in args.source.iterdir():
        if path.name.endswith(".safetensors") or path.name == "model.safetensors.index.json":
            continue
        target = args.output / path.name
        if path.is_dir():
            shutil.copytree(path, target, dirs_exist_ok=True)
        else:
            shutil.copy2(path, target)
    checkpoint["packing"] = "text-only-exact-bf16-v1"
    checkpoint["retained_tensor_count"] = len(retained)
    checkpoint["source_model_sha256"] = sha256(source_model)
    checkpoint["packed_model_sha256"] = sha256(output_model)
    (args.output / "smail-manifest.json").write_text(json.dumps(checkpoint, indent=2) + "\n")
    print(json.dumps({"tensor_count": len(retained), "bytes": output_model.stat().st_size,
                      "sha256": checkpoint["packed_model_sha256"]}))


if __name__ == "__main__":
    main()
