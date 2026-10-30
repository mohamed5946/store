#!/usr/bin/env python3
"""Fail unless an APK's v2 signing-block certificate SHA-1 matches the
expected value (a public certificate fingerprint, safe to hard-code in
CI). This is the tripwire that makes a silent signing-key change
impossible: the build stops instead of shipping an APK that cannot
install as an update over the previous release.

Usage: check_release_cert.py <apk> <expected-sha1-colon-hex>
Exit 0 on match, 1 on mismatch or unparseable input.
"""
import hashlib
import struct
import sys


def u32(data, off):
    return struct.unpack_from('<I', data, off)[0]


def u64(data, off):
    return struct.unpack_from('<Q', data, off)[0]


def find_eocd(data):
    start = max(0, len(data) - 65557)
    idx = data.rfind(b'PK\x05\x06', start)
    if idx < 0:
        raise SystemExit('EOCD record not found')
    return idx


def v2_cert_sha1(block_value):
    # Block value = sequence of signers; each is length-prefixed.
    # We use the first signer (our builds have exactly one).
    pos = 0
    signer_len = u32(block_value, pos)
    signer = block_value[pos + 4:pos + 4 + signer_len]
    # Signer = signed_data (len-prefixed), signatures (len-prefixed),
    # public_key (len-prefixed).
    sd_len = u32(signer, 0)
    signed_data = signer[4:4 + sd_len]
    # Signed data = digests (len-prefixed), certificates
    # (len-prefixed), additional attributes (len-prefixed).
    p = 0
    digests_len = u32(signed_data, p)
    p += 4 + digests_len
    certs_len = u32(signed_data, p)
    p += 4
    certs_end = p + certs_len
    if certs_end > len(signed_data):
        raise SystemExit('certificate sequence overruns signed data')
    cert_len = u32(signed_data, p)
    cert = signed_data[p + 4:p + 4 + cert_len]
    if len(cert) != cert_len:
        raise SystemExit('certificate truncated')
    return ':'.join('%02X' % b for b in hashlib.sha1(cert).digest())


def cert_sha1(apk_path):
    with open(apk_path, 'rb') as f:
        data = f.read()
    eocd = find_eocd(data)
    cd_offset = u32(data, eocd + 16)
    footer = cd_offset - 24
    if footer < 0:
        raise SystemExit('file too small for a signing block')
    size = u64(data, footer)
    magic = data[footer + 8:footer + 24]
    if magic != b'APK Sig Block 42':
        raise SystemExit('APK signing block magic not found')
    block_start = cd_offset - (size + 8)
    if block_start < 0:
        raise SystemExit('signing block start out of range')
    pos = block_start + 8
    end = footer
    while pos < end:
        entry_len = u64(data, pos)
        entry_id = u32(data, pos + 8)
        value = data[pos + 12:pos + 8 + entry_len]
        if entry_id == 0x7109871A:
            return v2_cert_sha1(value)
        pos += 8 + entry_len
    raise SystemExit('v2 signing block (0x7109871a) not found')


def main(argv):
    if len(argv) != 3:
        print(__doc__)
        return 2
    apk_path, expected = argv[1], argv[2].upper()
    got = cert_sha1(apk_path)
    print('APK cert SHA-1:', got)
    if got != expected:
        print('FAIL: expected', expected)
        return 1
    print('OK: certificate matches expected fingerprint')
    return 0


if __name__ == '__main__':
    raise SystemExit(main(sys.argv))
