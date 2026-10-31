#!/usr/bin/env python3
"""Fail unless an APK's v2 signing-block certificate SHA-1 matches the
expected value (a public certificate fingerprint, safe to hard-code in
CI). This is the tripwire that makes a silent signing-key change
impossible: the build stops instead of shipping an APK that cannot
install as an update over the previous release.

Usage: check_release_cert.py <apk> <expected-sha1-colon-hex>
Exit 0 on match, 1 on mismatch or unparseable input.

Layout of the v2 block value (this is where an earlier version of this
script went wrong, so it is spelled out): the value starts with a
uint32 SEQUENCE length covering the signers that follow; each signer
is itself length-prefixed, and only then comes the length-prefixed
signed data (digests, certificates, additional attributes), the
length-prefixed signatures, and the length-prefixed public key. The
old script treated the sequence length as the signer length, shifting
its whole parse by one length field: it ended up hashing bytes from
inside the SIGNATURES region instead of the certificate. Signature
bytes change whenever the APK content changes (per version) and stay
stable across runs of the same commit (deterministic RSA), which is
exactly the phantom "key rotation" pattern the old script reported
while the real certificate never changed. The fix below skips the
sequence length first, and additionally refuses any blob that does
not start with a DER SEQUENCE tag (0x30) so a mis-parse fails loudly
instead of producing a plausible-looking wrong fingerprint.
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
    # Block value = length-prefixed SEQUENCE of signers; each signer is
    # length-prefixed. Our builds have exactly one signer; we use it.
    if len(block_value) < 8:
        raise SystemExit('v2 block value too small for a signer')
    seq_len = u32(block_value, 0)
    if seq_len + 4 > len(block_value):
        raise SystemExit('v2 signer sequence overruns block value')
    pos = 4
    signer_len = u32(block_value, pos)
    pos += 4
    if pos + signer_len > len(block_value):
        raise SystemExit('v2 signer overruns block value')
    signer = block_value[pos:pos + signer_len]
    # Signer = signed_data (len-prefixed), signatures (len-prefixed),
    # public_key (len-prefixed).
    if len(signer) < 4:
        raise SystemExit('v2 signer too small for signed data')
    sd_len = u32(signer, 0)
    if 4 + sd_len > len(signer):
        raise SystemExit('v2 signed data overruns signer')
    signed_data = signer[4:4 + sd_len]
    # Signed data = digests (len-prefixed), certificates
    # (len-prefixed), additional attributes (len-prefixed).
    p = 0
    digests_len = u32(signed_data, p)
    p += 4 + digests_len
    if p + 4 > len(signed_data):
        raise SystemExit('v2 digests overrun signed data')
    certs_len = u32(signed_data, p)
    p += 4
    certs_end = p + certs_len
    if certs_end > len(signed_data):
        raise SystemExit('certificate sequence overruns signed data')
    cert_len = u32(signed_data, p)
    cert = signed_data[p + 4:p + 4 + cert_len]
    if len(cert) != cert_len:
        raise SystemExit('certificate truncated')
    if not cert or cert[0] != 0x30:
        raise SystemExit(
            'extracted blob is not a DER certificate (missing 0x30 tag); '
            'the v2 parse is wrong, refusing to hash it')
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
