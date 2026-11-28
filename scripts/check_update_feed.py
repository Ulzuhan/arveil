"""Check the public channel using the distribution embedded in a trusted release."""
import argparse
import base64
from datetime import timedelta
import json
from pathlib import Path
import subprocess
import sys
import tempfile

import client_updates
import release_clients


def verify(wire, config, minimum_sequence, minimum_days):
    if len(wire) > 65536:
        raise ValueError("Oversized update manifest.")
    envelope = json.loads(wire)
    payload = base64.b64decode(envelope["payload"], validate=True)
    signature = base64.b64decode(envelope["signature"], validate=True)
    key = base64.b64decode(config["ARVEIL_UPDATE_PUBLIC_KEY"], validate=True)
    if envelope["schema"] != 1 or len(key) != 32 or len(signature) != 64:
        raise ValueError("Invalid update key or envelope.")
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        (root / "key").write_bytes(client_updates.PUBLIC_DER_PREFIX + key)
        (root / "message").write_bytes(client_updates.DOMAIN + payload)
        (root / "signature").write_bytes(signature)
        client_updates.openssl("openssl", "pkeyutl", "-verify", "-rawin", "-pubin", "-keyform", "DER",
                               "-inkey", str(root / "key"), "-in", str(root / "message"),
                               "-sigfile", str(root / "signature"))
    signed = json.loads(payload)
    if signed["schema"] != 1 or signed["channel"] != config["ARVEIL_UPDATE_CHANNEL"]:
        raise ValueError("Incorrect signed schema or channel.")
    if not client_updates.integer(signed["sequence"], minimum_sequence, client_updates.MAX_SEQUENCE):
        raise ValueError("The signed sequence is below the release baseline or invalid.")
    if release_clients.remaining(signed) <= timedelta(days=minimum_days):
        raise ValueError(f"Sequence {signed['sequence']} expires {signed['expires']} (threshold {minimum_days} days).")
    return signed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", type=Path, required=True, help="independently verified BUILD-android.json")
    parser.add_argument("--min-sequence", type=int, required=True)
    parser.add_argument("--min-days", type=int, default=7)
    args = parser.parse_args()
    if args.min_sequence < 1 or args.min_days < 0:
        parser.error("use a positive sequence and nonnegative days")
    config = json.loads(args.build.read_bytes())["update_config"]
    wire = release_clients.fetch_live_manifest(client_updates.https_url(config["ARVEIL_UPDATE_URL"], query=False))
    signed = verify(wire, config, args.min_sequence, args.min_days)
    print(f"Verified {signed['channel']} sequence {signed['sequence']}, expires {signed['expires']}.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError, subprocess.CalledProcessError, release_clients.ReleaseError) as error:
        sys.exit(f"Update feed check failed: {error}")
