#!/usr/bin/env python3
"""Build experimental client packages. Credentials and build logs stay local."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import zipfile

from client_updates import read_config


ROOT = Path(__file__).resolve().parents[1]
CLIENT = ROOT / "clients/flutter"
PRIVATE_PATH = re.compile(rb"/(?:Users|home)/[A-Za-z0-9._-]+/")


def run(args, *, cwd=ROOT, env=None):
    return subprocess.run(args, cwd=cwd, env=env, check=True, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT).stdout


def private_json(path, value):
    with open(path, "x", encoding="utf-8", opener=lambda p, flags: os.open(p, flags, 0o600)) as output:
        json.dump(value, output, indent=2)
        output.write("\n")


def init_android(args):
    directory = args.directory.resolve()
    if directory.exists():
        raise ValueError("Signing directory already exists; reuse its key, never replace it.")
    directory.mkdir(parents=True, mode=0o700)
    password = secrets.token_urlsafe(48)
    env = dict(os.environ, ARVEIL_KEYTOOL_PASSWORD=password)
    store = directory / "android-release.keystore"
    private_json(directory / "android-signing.json", {
        "keystore": str(store), "store_password": password,
        "key_alias": "arveil", "key_password": password,
    })
    # The certificate contains project metadata only. Passwords never enter argv.
    run([args.keytool, "-genkeypair", "-noprompt", "-keystore", str(store),
         "-storetype", "PKCS12", "-storepass:env", "ARVEIL_KEYTOOL_PASSWORD",
         "-keypass:env", "ARVEIL_KEYTOOL_PASSWORD", "-alias", "arveil",
         "-keyalg", "RSA", "-keysize", "3072", "-validity", "10000",
         "-dname", "CN=Arveil experimental releases,O=Arveil"], env=env)
    store.chmod(0o600)
    print("Created private signing material. Back up the entire directory securely before publishing.")


def signing_environment(path):
    if path.stat().st_mode & 0o077:
        raise ValueError("Signing JSON must be private (chmod 600).")
    config = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(config, dict):
        raise ValueError("Signing JSON must contain a JSON object.")
    store = Path(config["keystore"]).expanduser().resolve()
    if not store.is_file() or store.stat().st_mode & 0o077:
        raise ValueError("Signing keystore must exist and be private (chmod 600).")
    return {
        "ARVEIL_ANDROID_KEYSTORE": str(store),
        "ARVEIL_ANDROID_STORE_PASSWORD": config["store_password"],
        "ARVEIL_ANDROID_KEY_ALIAS": config["key_alias"],
        "ARVEIL_ANDROID_KEY_PASSWORD": config["key_password"],
    }


def audit_bytes(data, name):
    # Report the member name, never the matched private path or secret value.
    if PRIVATE_PATH.search(data):
        raise ValueError(f"Private home path embedded in {name}; package withheld.")
    for marker in (b"ARVEIL_TEST_",
                   b"BEGIN PRIVATE KEY", b"BEGIN RSA PRIVATE KEY"):
        if marker in data:
            raise ValueError(f"Test configuration or private key marker in {name}; package withheld.")


def audit_archive(path):
    with zipfile.ZipFile(path) as archive:
        for member in archive.infolist():
            if not member.is_dir():
                audit_bytes(archive.read(member), member.filename)


def prepare_macos(app):
    details = run(["codesign", "-d", "--verbose=4", str(app)])
    if "Signature=adhoc" not in details:
        raise ValueError("Expected explicit ad-hoc signing for this macOS package.")
    framework = app / "Contents/Frameworks/arveil_flutter.framework"
    # Cargokit's static library leaves a native debug symbol map in the linked
    # framework. Strip debug symbols only; exported FFI symbols are preserved.
    run(["strip", "-S", str(framework / "Versions/A/arveil_flutter")])
    for target in (framework, app):
        run(["codesign", "--force", "--sign", "-", "--timestamp=none",
             "--preserve-metadata=identifier,entitlements,flags", str(target)])
    run(["codesign", "--verify", "--deep", "--strict", str(app)])


def build_environment(source):
    env = dict(os.environ)
    # Discard inherited test defines and Xcode overrides; the package always
    # builds lib/main.dart. flutter clean removes previous test build settings.
    for key in list(env):
        if key.startswith(("DART_DEFINES", "FLUTTER_XCODE_", "ARVEIL_TEST_")):
            del env[key]
    mappings = [(source, "arveil"), (Path.home(), "build")]
    env["CARGO_ENCODED_RUSTFLAGS"] = "\x1f".join(
        f"--remap-path-prefix={source}={dest}" for source, dest in mappings)
    # cc-rs applies the generic flags after target-specific flags from Cargokit.
    # OpenSSL embeds its C compiler flags as diagnostic text. Do not put
    # personal paths in those flags, even as a prefix-map source.
    env["CFLAGS"] = f'-ffile-prefix-map="{source}"=arveil'
    env["CXXFLAGS"] = env["CFLAGS"]
    env["FLUTTER_XCODE_OTHER_CFLAGS"] = "$(inherited) " + env["CFLAGS"]
    env["FLUTTER_XCODE_OTHER_SWIFT_FLAGS"] = "$(inherited) " + " ".join(
        f'-debug-prefix-map "{source}"={dest}' for source, dest in mappings)
    # The macOS artifact is deliberately Apple silicon only for this milestone.
    env["FLUTTER_XCODE_ARCHS"] = "arm64"
    env["FLUTTER_XCODE_EXCLUDED_ARCHS"] = "x86_64"
    env["FLUTTER_XCODE_CODE_SIGN_IDENTITY"] = "-"
    # Android builds see the SDK through a temporary alias that is deleted
    # afterwards. A Gradle or Kotlin daemon kept alive with it breaks the next
    # build, and stopping shared daemons breaks concurrent builds elsewhere.
    # Run both in the build's own process instead; Xcode builds ignore these.
    env["GRADLE_OPTS"] = " ".join(filter(None, (env.get("GRADLE_OPTS"), "-Dorg.gradle.daemon=false")))
    env["ORG_GRADLE_PROJECT_kotlin.compiler.execution.strategy"] = "in-process"
    env["RUSTUP_TOOLCHAIN"] = re.search(
        r'channel\s*=\s*"([^"]+)"', (ROOT / "core/rust-toolchain.toml").read_text(encoding="utf-8"))[1]
    return env


def java_environment(env, flutter):
    """Return the environment for apksigner, a shell wrapper that runs `java` from PATH."""
    home = env.get("JAVA_HOME")
    if not home:
        # Default to the JDK Flutter builds with: its jdk-dir setting or
        # Android Studio's bundled JDK. The path itself is never printed.
        try:
            output = run([flutter, "config", "--machine"], env=env)
            config = json.JSONDecoder().raw_decode(output, output.index("{"))[0]
            home = config.get("jdk-dir") if isinstance(config, dict) else None
        except (ValueError, OSError, subprocess.CalledProcessError):
            home = None
    java = dict(env)
    if home:
        java["JAVA_HOME"] = str(home)
        java["PATH"] = os.pathsep.join((str(Path(home) / "bin"), env.get("PATH", "")))
    # Without a runtime, macOS's /usr/bin/java fails; say so before building.
    try:
        found = subprocess.run(["java", "-version"], env=java, stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL).returncode == 0
    except OSError:
        found = False
    if not found:
        raise ValueError("apksigner needs a Java runtime; set JAVA_HOME to a JDK such as Android Studio's.")
    return java


def android_details(badging, build, updates):
    """Check `aapt2 dump badging` output; return the facts BUILD.json records."""
    if "android.permission.INTERNET" not in badging or "application-debuggable" in badging:
        raise ValueError("Release APK must have network permission and must not be debuggable.")
    if "native-code: 'arm64-v8a'" not in badging:
        raise ValueError("Unexpected Android architecture.")
    # The installer permission is merged only into builds with an update feed.
    installer = re.search(r"^uses-permission: name='android\.permission\.REQUEST_INSTALL_PACKAGES'", badging, re.M)
    if updates and not installer:
        raise ValueError("An APK with an update feed must request REQUEST_INSTALL_PACKAGES; package withheld.")
    if not updates and "android.permission.REQUEST_INSTALL_PACKAGES" in badging:
        raise ValueError("An APK without an update feed must not request REQUEST_INSTALL_PACKAGES; package withheld.")
    identifier = re.search(r"^package: name='([^']+)'", badging, re.M)
    if not identifier:
        raise ValueError("Cannot determine the APK package name; package withheld.")
    # The updater announces BUILD.json's build; Android installs by versionCode.
    code = re.search(r"^package: .*\bversionCode='(\d+)'", badging, re.M)
    if not code or int(code[1]) != build:
        raise ValueError("The APK versionCode differs from the build number; package withheld.")
    minimum = re.search(r"(?:minSdkVersion|sdkVersion):'(\d+)'", badging)
    if not minimum:
        raise ValueError("Cannot determine the APK minimum SDK; package withheld.")
    return {"minimum_sdk": int(minimum[1]), "application_id": identifier[1]}


def package(args):
    if args.update_config and args.platform != "android":
        raise ValueError("--update-config applies only to Android; macOS has no signed updater yet.")
    update_config = read_config(args.update_config) if args.update_config else None
    if args.platform == "macos" and (sys.platform != "darwin" or platform.machine() != "arm64"):
        raise ValueError("The macOS package requires an Apple silicon Mac.")
    dirty = bool(run(["git", "status", "--porcelain", "--untracked-files=normal"]).strip())
    if dirty and not args.allow_dirty:
        raise ValueError("Commit the source first, or use --allow-dirty for a local, unpublished candidate.")
    version = re.search(r"^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$",
                        (CLIENT / "pubspec.yaml").read_text(encoding="utf-8"), re.M)
    if not version:
        raise ValueError("pubspec.yaml must contain a numeric version and build number.")
    name, default_build = version.groups()
    number = args.build_number or int(default_build)
    if not 1 <= number <= 2100000000:
        raise ValueError("Build number must be between 1 and 2100000000.")
    revision = run(["git", "rev-parse", "HEAD"]).strip()
    destination = ROOT / "dist/clients" / f"{name}+{number}" / args.platform
    if destination.exists():
        raise ValueError("Output directory exists; choose a new build number or move the old candidate.")
    env = dict(os.environ)
    if args.platform == "android":
        if args.signing_config:
            env.update(signing_environment(args.signing_config))
        for key in ("KEYSTORE", "STORE_PASSWORD", "KEY_ALIAS", "KEY_PASSWORD"):
            if not env.get("ARVEIL_ANDROID_" + key):
                raise ValueError("Android release signing is required; see docs/CLIENT_RELEASES.md.")
        # The build finds its own JDK; apksigner runs after it. Check first.
        java = java_environment(env, args.flutter)
    private = ROOT / ".local/client-builds"
    private.mkdir(parents=True, exist_ok=True, mode=0o700)
    # A real isolated source directory also removes Dart-generated absolute
    # source URIs and OpenSSL's compiled installation paths from the checkout.
    scratch_root = "/private/tmp" if sys.platform == "darwin" else "/tmp"
    with tempfile.TemporaryDirectory(dir=scratch_root, prefix="arveil-client-") as staging:
        scratch = Path(staging)
        source = scratch / "source"
        for name_in_git in run(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"]).split("\0"):
            if not name_in_git:
                continue
            original = ROOT / name_in_git
            if not original.exists():  # --allow-dirty may include deletions.
                continue
            target = source / name_in_git
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(original, target, follow_symlinks=False)
        client = source / "clients/flutter"
        env = build_environment(source)
        # build_environment starts from the process environment; restore JSON credentials.
        if args.platform == "android" and args.signing_config:
            env.update(signing_environment(args.signing_config))
        env["ARVEIL_REVISION"] = revision
        if args.platform == "android":
            real_sdk = Path(env.get("ANDROID_HOME") or env.get("ANDROID_SDK_ROOT") or "")
            if not real_sdk.is_absolute() or not real_sdk.is_dir():
                raise ValueError("Set ANDROID_HOME to the Android SDK directory.")
            sdk_alias = scratch / "android-sdk"
            sdk_alias.mkdir()
            for child in real_sdk.iterdir():
                (sdk_alias / child.name).symlink_to(child, target_is_directory=child.is_dir())
            env["ANDROID_HOME"] = env["ANDROID_SDK_ROOT"] = str(sdk_alias)
        staged = scratch / "packages"
        staged.mkdir()
        # Debug symbols stay private; the signed packages contain only runtime files.
        symbols = scratch / "symbols"
        # The app's diagnostic report names the version and commit it was built from.
        command = [args.flutter, "build", "macos" if args.platform == "macos" else "apk",
                   "--release", "--target=lib/main.dart", f"--build-name={name}",
                   f"--build-number={number}", f"--split-debug-info={symbols}",
                   f"--dart-define=ARVEIL_VERSION={name}+{number}",
                   f"--dart-define=ARVEIL_REVISION={revision}"]
        if update_config:
            defines = scratch / "update-config.json"
            private_json(defines, update_config)
            command.append(f"--dart-define-from-file={defines}")
        if args.platform == "android":
            command += ["--target-platform=android-arm64"]
        log = private / f"{args.platform}-{number}.log"
        with open(log, "w", opener=lambda p, flags: os.open(p, flags, 0o600)) as output:
            for step in ([args.flutter, "clean"], [args.flutter, "pub", "get", "--enforce-lockfile"], command):
                print(f"Running {step[1]} ({args.platform})…", flush=True)
                result = subprocess.run(step, cwd=client, env=env,
                                        stdout=output, stderr=subprocess.STDOUT)
                if result.returncode:
                    raise ValueError("Build failed; inspect the private log in .local/client-builds.")
        if symbols.exists():
            shutil.copytree(symbols, private / f"symbols-{args.platform}-{number}", dirs_exist_ok=True)
        metadata = {"version": name, "build": number, "revision": revision,
                    "dirty_source": dirty, "platform": args.platform,
                    "architecture": "arm64", "experimental": True}
        if update_config:
            # These are public distribution settings embedded in the APK;
            # the input file path, private key and realm settings never travel.
            metadata["update_config"] = update_config
        stem = f"arveil-{name}-{number}"
        if args.platform == "macos":
            app = client / "build/macos/Build/Products/Release/arveil.app"
            info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
            architectures = run(["lipo", "-archs", str(app / "Contents/MacOS" / info["CFBundleExecutable"])]).strip()
            if architectures != "arm64":
                raise ValueError("Unexpected macOS architecture; package withheld.")
            prepare_macos(app)
            metadata.update(minimum_os=info["LSMinimumSystemVersion"],
                            signing="ad-hoc; no Developer ID or notarization")
            artifact = staged / f"{stem}-macos-arm64.zip"
            run(["ditto", "-c", "-k", "--keepParent", "--norsrc", "--noextattr", str(app), str(artifact)])
        else:
            artifact = staged / f"{stem}-android-arm64.apk"
            shutil.copyfile(client / "build/app/outputs/flutter-apk/app-release.apk", artifact)
            sdk = Path(env.get("ANDROID_HOME") or env.get("ANDROID_SDK_ROOT") or "")
            if not sdk.is_absolute():
                raise ValueError("Set ANDROID_HOME to verify the APK with the Android build tools.")
            build_tools = sorted((sdk / "build-tools").glob("*/apksigner"),
                                 key=lambda p: tuple(int(n) for n in re.findall(r"\d+", p.parent.name)))
            if not build_tools:
                raise ValueError("Android build tools (apksigner) are required.")
            details = run([str(build_tools[-1]), "verify", "--verbose", "--print-certs", str(artifact)], env=java)
            fingerprint = re.search(r"certificate SHA-256 digest: ([0-9a-f]{64})", details)
            if not fingerprint or "CN=Android Debug" in details:
                raise ValueError("Expected a valid release certificate, not debug signing.")
            badging = run([str(build_tools[-1].with_name("aapt2")), "dump", "badging", str(artifact)], env=env)
            metadata.update(android_details(badging, number, bool(update_config)),
                            certificate_sha256=fingerprint[1], signing="private release key")
        # Retain an unverified copy privately so audit failures can be diagnosed
        # without rebuilding. Only verified copies reach dist/clients.
        shutil.copyfile(artifact, private / f"unverified-{args.platform}-{number}{artifact.suffix}")
        audit_archive(artifact)
        (staged / "BUILD.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
        (staged / "SHA256SUMS.txt").write_text("".join(
            f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n"
            for p in (artifact, staged / "BUILD.json")), encoding="utf-8")
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(staged, destination)
    print(f"Package verified: {destination.relative_to(ROOT)}")
    if dirty:
        print("Local candidate only: source contains uncommitted changes.")


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    init = commands.add_parser("init-android-key", help="Create a persistent private release key once")
    init.add_argument("--directory", type=Path, default=ROOT / ".local/signing")
    init.add_argument("--keytool", default="keytool")
    init.set_defaults(action=init_android)
    build = commands.add_parser("build", help="Build, verify and package a release client")
    build.add_argument("platform", choices=["macos", "android"])
    build.add_argument("--flutter", default="flutter")
    build.add_argument("--signing-config", type=Path)
    build.add_argument("--update-config", type=Path, help="Private JSON with public feed URL, update public key and channel")
    build.add_argument("--build-number", type=int)
    build.add_argument("--allow-dirty", action="store_true")
    build.set_defaults(action=package)
    args = parser.parse_args()
    try:
        args.action(args)
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        # External tool output can contain signing paths; do not print it.
        if isinstance(error, subprocess.CalledProcessError):
            message = "An external packaging check failed; no package was published."
        elif isinstance(error, OSError):
            message = "A required file or tool is unavailable; check prerequisites and permissions."
        else:
            message = str(error)
        print(message, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
