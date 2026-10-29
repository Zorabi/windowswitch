#!/usr/bin/env python3
"""Create a reusable, user-keychain code-signing identity once. Never export an existing key."""
import os
from pathlib import Path
import secrets
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
IDENTITY = "dongx WindowSwitch Signing"

def run(*args, **kwargs):
    result = subprocess.run(args, text=True, capture_output=True, **kwargs)
    if result.returncode:
        raise SystemExit(f"{args[0]} failed:\n{result.stderr}")
    return result.stdout

valid = run("security", "find-identity", "-v", "-p", "codesigning")
if f'"{IDENTITY}"' not in valid:
    existing = subprocess.run(["security", "find-certificate", "-c", IDENTITY], capture_output=True)
    if existing.returncode == 0:
        raise SystemExit("Signing certificate exists but is not a valid identity. Repair it in Keychain Access; do not regenerate it.")
    keychain = str(Path.home() / "Library/Keychains/login.keychain-db")
    (ROOT / "build").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="signing-", dir=ROOT / "build") as temp:
        temp = Path(temp)
        key, cert, p12 = (temp / x for x in ("key.pem", "cert.pem", "identity.p12"))
        password = secrets.token_urlsafe(32)
        env = dict(os.environ, WINDOWSWITCH_P12_PASSWORD=password)
        run("openssl", "req", "-x509", "-newkey", "rsa:3072", "-sha256", "-nodes",
            "-days", "3650", "-subj", f"/CN={IDENTITY}/O=dongx",
            "-addext", "basicConstraints=critical,CA:FALSE",
            "-addext", "keyUsage=critical,digitalSignature",
            "-addext", "extendedKeyUsage=critical,codeSigning",
            "-keyout", str(key), "-out", str(cert))
        key.chmod(0o600)
        run("openssl", "pkcs12", "-export", "-keypbe", "PBE-SHA1-3DES",
            "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1", "-name", IDENTITY,
            "-inkey", str(key), "-in", str(cert), "-out", str(p12),
            "-passout", "env:WINDOWSWITCH_P12_PASSWORD", env=env)
        p12.chmod(0o600)
        run("security", "import", str(p12), "-k", keychain, "-P", password,
            "-T", "/usr/bin/codesign")
        # Trust this certificate for code signing only, in the current user's keychain.
        run("security", "add-trusted-cert", "-r", "trustRoot", "-p", "codeSign",
            "-k", keychain, str(cert))

valid = run("security", "find-identity", "-v", "-p", "codesigning")
entry = next((line for line in valid.splitlines() if f'"{IDENTITY}"' in line), None)
if entry is None:
    raise SystemExit("The dedicated signing identity is unavailable. No application was installed.")
fingerprint = entry.split()[1]
pin = ROOT / "Config/signing-fingerprint.txt"
if pin.exists() and pin.read_text().strip() != fingerprint:
    raise SystemExit("Signing identity changed. Refusing to replace the pinned identity.")
pin.write_text(fingerprint + "\n")
print("Stable signing identity ready:", IDENTITY)
