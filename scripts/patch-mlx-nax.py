#!/usr/bin/env python3
"""Repair the wide-head NAX JIT template arguments in pinned MLX Swift 0.33.0.

Upstream: https://github.com/ml-explore/mlx-swift
Revision: 7ede4fd6d05f63305c1c0ebf4f8c1909a637c574

The dsplit Metal template has no BV parameter. Passing the normal attention
template's BV argument shifts WM, WN and MaskType and prevents compilation.
This patch changes only JIT instantiation, preserving bf16 weights and kernels.
Pass --checkout for another resolved checkout, including Xcode SourcePackages.
Unknown revisions or source changes fail before any write.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

UPSTREAM_REVISION = "7ede4fd6d05f63305c1c0ebf4f8c1909a637c574"
SOURCE_RELATIVE_PATH = Path("Source/Cmlx/mlx/mlx/backend/metal/jit_kernels.cpp")
ORIGINAL_SHA256 = "ca1bb384d25625fb73e25e5e0782df13a3e5de7177f603b09843b8cdb502b9c9"
PATCHED_SHA256 = "dc2f5dcd11c9970e9a2db6e50f57564e81806ded78a140807a1f69b7323767e0"

ORIGINAL = """    concatenate(
        kernel_source,
        metal::utils(),
        metal::steel_attention_nax(),
        get_template_definition(
            lib_name,
            split_d ? "attention_nax_dsplit" : "attention_nax",
            get_type_string(q.dtype()),
            bq,
            bk,
            bd,
            bv,
            wm,
            wn,
            get_type_string(m.dtype())));
"""

PATCHED = """    concatenate(
        kernel_source,
        metal::utils(),
        metal::steel_attention_nax());
    if (split_d) {
      kernel_source += get_template_definition(
          lib_name,
          "attention_nax_dsplit",
          get_type_string(q.dtype()),
          bq,
          bk,
          bd,
          wm,
          wn,
          get_type_string(m.dtype()));
    } else {
      kernel_source += get_template_definition(
          lib_name,
          "attention_nax",
          get_type_string(q.dtype()),
          bq,
          bk,
          bd,
          bv,
          wm,
          wn,
          get_type_string(m.dtype()));
    }
"""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--checkout", type=Path,
        default=Path(__file__).resolve().parent.parent / ".build/checkouts/mlx-swift",
    )
    parser.add_argument("--check", action="store_true", help="Check without writing; exit 1 when the patch is needed.")
    args = parser.parse_args()
    checkout = args.checkout.resolve(strict=True)
    revision = subprocess.check_output(
        ["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True,
        stderr=subprocess.PIPE,
    ).strip()
    if revision != UPSTREAM_REVISION:
        raise ValueError(f"Unsupported MLX revision {revision}; expected {UPSTREAM_REVISION}.")

    path = checkout / SOURCE_RELATIVE_PATH
    if path.is_symlink():
        raise ValueError("The MLX source must be a regular checkout file.")
    data = path.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    source = data.decode("utf-8")
    if digest == PATCHED_SHA256 and source.count(PATCHED) == 1 and ORIGINAL not in source:
        action = "already_patched"
    elif digest == ORIGINAL_SHA256 and source.count(ORIGINAL) == 1 and PATCHED not in source:
        if args.check:
            print(json.dumps({"action": "needs_patch", "revision": revision, "source_sha256": digest}))
            return 1
        updated = source.replace(ORIGINAL, PATCHED, 1).encode("utf-8")
        if hashlib.sha256(updated).hexdigest() != PATCHED_SHA256:
            raise ValueError("The repaired source does not match the reviewed patch.")
        temporary_path = None
        try:
            with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".morrow-nax-", delete=False) as temporary:
                temporary_path = Path(temporary.name)
                temporary.write(updated)
            os.chmod(temporary_path, path.stat().st_mode & 0o777)
            # Refuse to overwrite a concurrently edited dependency checkout.
            if path.read_bytes() != data:
                raise ValueError("The MLX source changed while preparing the patch.")
            os.replace(temporary_path, path)
        finally:
            if temporary_path is not None:
                temporary_path.unlink(missing_ok=True)
        digest = PATCHED_SHA256
        action = "patched"
    else:
        raise ValueError(f"Unrecognized MLX JIT source SHA256 {digest}; no files changed.")
    print(json.dumps({"action": action, "revision": revision, "source_sha256": digest}))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"MLX NAX patch refused: {error}", file=sys.stderr)
        sys.exit(2)
