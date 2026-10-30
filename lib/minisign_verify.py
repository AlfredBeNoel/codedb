"""Verify a minisign signature without the minisign tool.

Usage: minisign_verify.py <public-key-base64> <file> <file.minisig> <expected-file-name>
Exit 0 only if the signature, the trusted comment signature and the file name all check out.
Ed25519 verification follows the RFC 8032 section 6 reference code.
"""
import base64
import hashlib
import sys

P = 2**255 - 19
Q = 2**252 + 27742317777372353535851937790883648493
D = -121665 * pow(121666, P - 2, P) % P
SQRT_M1 = pow(2, (P - 1) // 4, P)


def point_add(a, b):
    pa = (a[1] - a[0]) * (b[1] - b[0]) % P
    pb = (a[1] + a[0]) * (b[1] + b[0]) % P
    pc = 2 * a[3] * b[3] * D % P
    pd = 2 * a[2] * b[2] % P
    e, f, g, h = pb - pa, pd - pc, pd + pc, pb + pa
    return (e * f % P, g * h % P, f * g % P, e * h % P)


def point_mul(s, pt):
    acc = (0, 1, 1, 0)
    while s > 0:
        if s & 1:
            acc = point_add(acc, pt)
        pt = point_add(pt, pt)
        s >>= 1
    return acc


def point_equal(a, b):
    return (a[0] * b[2] - b[0] * a[2]) % P == 0 and (a[1] * b[2] - b[1] * a[2]) % P == 0


def recover_x(y, sign):
    if y >= P:
        return None
    x2 = (y * y - 1) * pow(D * y * y + 1, P - 2, P)
    if x2 % P == 0:
        return None if sign else 0
    x = pow(x2, (P + 3) // 8, P)
    if (x * x - x2) % P != 0:
        x = x * SQRT_M1 % P
    if (x * x - x2) % P != 0:
        return None
    if (x & 1) != sign:
        x = P - x
    return x


def point_decompress(s):
    y = int.from_bytes(s, "little")
    sign = y >> 255
    y &= (1 << 255) - 1
    x = recover_x(y, sign)
    return None if x is None else (x, y, 1, x * y % P)


G_Y = 4 * pow(5, P - 2, P) % P
G_X = recover_x(G_Y, 0)
G = (G_X, G_Y, 1, G_X * G_Y % P)


def ed25519_verify(public, msg, sig):
    if len(public) != 32 or len(sig) != 64:
        return False
    a = point_decompress(public)
    r = point_decompress(sig[:32])
    if a is None or r is None:
        return False
    s = int.from_bytes(sig[32:], "little")
    if s >= Q:
        return False
    h = int.from_bytes(hashlib.sha512(sig[:32] + public + msg).digest(), "little") % Q
    return point_equal(point_mul(s, G), point_add(r, point_mul(h, a)))


def main():
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    pubkey_b64, path, sig_path, expected_name = sys.argv[1:]
    pk = base64.b64decode(pubkey_b64)
    if len(pk) != 42 or pk[:2] != b"Ed":
        sys.exit("bad public key")
    lines = open(sig_path, encoding="utf-8").read().splitlines()
    if len(lines) < 4 or not lines[2].startswith("trusted comment: "):
        sys.exit("bad signature file")
    sig_blob = base64.b64decode(lines[1])
    if len(sig_blob) != 74 or sig_blob[2:10] != pk[2:10]:
        sys.exit("signature is not from the expected key")
    alg, sig = sig_blob[:2], sig_blob[10:]
    data = open(path, "rb").read()
    if alg == b"ED":
        data = hashlib.blake2b(data, digest_size=64).digest()
    elif alg != b"Ed":
        sys.exit("unknown signature algorithm")
    if not ed25519_verify(pk[10:], data, sig):
        sys.exit("signature does not match the file")
    trusted = lines[2][len("trusted comment: "):]
    if not ed25519_verify(pk[10:], sig + trusted.encode(), base64.b64decode(lines[3])):
        sys.exit("trusted comment signature does not match")
    # A valid signature for a different tarball must not pass.
    if "file:" + expected_name not in trusted.split():
        sys.exit(f"signature is for another file: {trusted}")


if __name__ == "__main__":
    main()
