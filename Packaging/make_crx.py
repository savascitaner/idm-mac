#!/usr/bin/env python3
"""Packs the Chrome extension folder into a signed CRX3 file.

usage: make_crx.py <extension dir> <private key .pem> <out.crx>

Chrome derives the extension ID from the public key, so the same key must be used for every
build. Prints the extension ID. Needs only Python 3 and the openssl command line tool.
"""
import hashlib
import io
import os
import struct
import subprocess
import sys
import zipfile


def varint(n: int) -> bytes:
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        out.append(b | (0x80 if n else 0))
        if not n:
            return bytes(out)


def field(number: int, payload: bytes) -> bytes:
    return varint((number << 3) | 2) + varint(len(payload)) + payload


def openssl(args, data=None) -> bytes:
    return subprocess.run(["openssl", *args], input=data, check=True, capture_output=True).stdout


def extension_id(public_der: bytes) -> str:
    return "".join(chr(ord("a") + int(c, 16)) for c in hashlib.sha256(public_der).hexdigest()[:32])


def main() -> None:
    src, pem, out = sys.argv[1:4]
    public_der = openssl(["rsa", "-in", pem, "-pubout", "-outform", "DER"])
    crx_id = hashlib.sha256(public_der).digest()[:16]

    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for root, dirs, files in os.walk(src):
            dirs.sort()
            for name in sorted(files):
                if name.startswith("."):
                    continue
                path = os.path.join(root, name)
                z.write(path, os.path.relpath(path, src))
    archive = buf.getvalue()

    signed_data = field(1, crx_id)  # SignedData { crx_id }
    to_sign = b"CRX3 SignedData\x00" + struct.pack("<I", len(signed_data)) + signed_data + archive
    signature = openssl(["dgst", "-sha256", "-sign", pem], to_sign)
    proof = field(1, public_der) + field(2, signature)  # AsymmetricKeyProof { public_key, signature }
    header = field(2, proof) + field(10000, signed_data)  # CrxFileHeader

    with open(out, "wb") as f:
        f.write(b"Cr24" + struct.pack("<II", 3, len(header)) + header + archive)
    print(extension_id(public_der))


if __name__ == "__main__":
    main()
