#!/usr/bin/env python3
"""Prepare and publish a client release with two commands.

  prepare  builds (or reuses) both packages for the checked-out revision,
           stages them, signs the update announcement and creates a draft
           prerelease on GitHub. Nothing is public yet.
  publish  checks the draft against the staged files, publishes it, then
           puts the signed announcement and the download links on the
           website, deploys it and bumps the Homebrew cask.

Both commands can be run again after a failure: finished steps are checked,
not repeated. Keys never leave this machine. package_clients.py signs the APK
locally, and client_updates.py asks for the update key's passphrase on this
terminal. Operator paths and hosts come from the ignored .local/release.json,
never from the repository. See docs/CLIENT_RELEASES.md.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
CONFIG = ROOT / ".local/release.json"
RELEASES = ROOT / ".local/releases"
TAG = re.compile(r"clients-v(\d+\.\d+\.\d+)(?:-([a-z]+)\.(\d+))?")
PLATFORMS = (("android", ".apk"), ("macos", ".zip"))
GOOD_CHECKS = {"success", "skipped", "neutral"}


class ReleaseError(Exception):
    pass


def run(command, *, cwd=ROOT, capture=True, env=None):
    """Run a command; its output, or a ReleaseError naming the step."""
    try:
        result = subprocess.run(command, cwd=cwd, env=env, check=True, text=True,
                                stdout=subprocess.PIPE if capture else None,
                                stderr=subprocess.PIPE if capture else None)
    except FileNotFoundError:
        raise ReleaseError(f"{command[0]} is not installed.") from None
    except subprocess.CalledProcessError as error:
        detail = (error.stderr or "").strip().splitlines()[-1:] if capture else []
        raise ReleaseError(f"{' '.join(command[:3])} failed" + (f": {detail[0]}" if detail else ".")) from None
    return result.stdout if capture else ""


def shown(path):
    """A path for messages: relative to the checkout, never the home directory."""
    try:
        return path.relative_to(ROOT)
    except ValueError:
        return path.name


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as file:
        for chunk in iter(lambda: file.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


# --- Inputs -----------------------------------------------------------------

def parse_tag(tag):
    """clients-v0.1.0-beta.3 → ("0.1.0", "0.1.0 beta 3")."""
    match = TAG.fullmatch(tag)
    if not match:
        raise ReleaseError("Use a client tag such as clients-v0.1.0-beta.3.")
    version, stage, number = match.groups()
    return version, f"{version} {stage} {number}" if stage else version


def local_path(value):
    path = Path(value).expanduser()
    return path if path.is_absolute() else ROOT / path


def load_config(path=CONFIG):
    """The operator's settings. Only the three local files are required."""
    try:
        config = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise ReleaseError(f"Cannot read .local/release.json ({error.__class__.__name__}); "
                           "see docs/CLIENT_RELEASES.md.") from None
    for key in ("signing_config", "update_config", "update_key"):
        if not isinstance(config.get(key), str):
            raise ReleaseError(f".local/release.json needs {key}.")
        config[key] = local_path(config[key])
    web, tap = config.get("web"), config.get("tap")
    if web is not None:
        for key in ("repo", "site"):
            if not isinstance(web.get(key), str):
                raise ReleaseError(f".local/release.json web needs {key}.")
        web["repo"] = local_path(web["repo"])
        if not re.fullmatch(r"https://[a-z0-9.-]+", web["site"]):
            raise ReleaseError("web site must be an https:// origin without a path.")
        if web.get("ssh") is not None:
            for key in ("known_hosts", "dir", "container"):
                if not isinstance(web.get(key), str):
                    raise ReleaseError(f".local/release.json web needs {key} to deploy.")
            web["known_hosts"] = local_path(web["known_hosts"])
    if tap is not None:
        if not isinstance(tap.get("repo"), str) or not isinstance(tap.get("cask"), str):
            raise ReleaseError(".local/release.json tap needs repo and cask.")
        tap["repo"] = local_path(tap["repo"])
    return config


def update_config(config):
    distribution = json.loads(config["update_config"].read_text(encoding="utf-8"))
    channel = distribution.get("ARVEIL_UPDATE_CHANNEL")
    if not isinstance(channel, str) or not re.fullmatch(r"[a-z][a-z0-9-]{0,31}", channel):
        raise ReleaseError("The update configuration has no valid channel.")
    return distribution, channel


def ledger(config, channel):
    path = config["update_key"].parent / "sequences.json"
    if not path.exists():
        return []
    entries = json.loads(path.read_text(encoding="utf-8")).get("channels", {}).get(channel, [])
    return [e for e in entries if isinstance(e, dict)]


def pubspec_version():
    text = (ROOT / "clients/flutter/pubspec.yaml").read_text(encoding="utf-8")
    match = re.search(r"^version:\s*(\d+\.\d+\.\d+)\+\d+\s*$", text, re.M)
    if not match:
        raise ReleaseError("clients/flutter/pubspec.yaml has no version.")
    return match[1]


def repository():
    return run(["gh", "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"]).strip()


# --- Checks -----------------------------------------------------------------

def release_revision(requested=None):
    """The commit to release: the checkout's by default, or an earlier tested one.

    It must already be on origin/main. Packages are only built from a clean
    checkout of that very commit; a release of an earlier commit reuses the
    packages already built for it."""
    run(["git", "fetch", "--quiet", "origin", "main"])
    head = run(["git", "rev-parse", "HEAD"]).strip()
    revision = run(["git", "rev-parse", "--verify", f"{requested or head}^{{commit}}"]).strip()
    try:
        run(["git", "merge-base", "--is-ancestor", revision, "origin/main"])
    except ReleaseError:
        raise ReleaseError("Release only commits that are on origin/main.") from None
    return revision, head


def checks_passed(repo, revision):
    runs = json.loads(run(["gh", "api", f"repos/{repo}/commits/{revision}/check-runs?per_page=100"]))
    results = runs.get("check_runs", [])
    if not results:
        raise ReleaseError("No CI results on this commit yet.")
    failing = sorted({r["name"] for r in results
                      if r.get("status") != "completed" or r.get("conclusion") not in GOOD_CHECKS})
    if failing:
        raise ReleaseError("CI is not green on this commit: " + ", ".join(failing[:5]))


def package_dir(version, build, platform):
    return ROOT / "dist/clients" / f"{version}+{build}" / platform


def check_package(directory, platform, suffix, revision, build, distribution):
    """The package in [directory] and its BUILD.json, if it is exactly this release."""
    info = json.loads((directory / "BUILD.json").read_text(encoding="utf-8"))
    expected = {"platform": platform, "revision": revision, "build": build,
                "dirty_source": False, "update_config": distribution}
    wrong = [key for key, value in expected.items() if info.get(key) != value]
    if wrong:
        raise ReleaseError(f"{shown(directory)} was not built for this release ({', '.join(wrong)}). "
                           "Move it aside to rebuild.")
    sums = {}
    for line in (directory / "SHA256SUMS.txt").read_text(encoding="utf-8").splitlines():
        digest, name = line.split("  ", 1)
        sums[name] = digest
    artifacts = list(directory.glob(f"*{suffix}"))
    if len(artifacts) != 1:
        raise ReleaseError(f"Expected one {suffix} in {shown(directory)}.")
    for file in (artifacts[0], directory / "BUILD.json"):
        if sums.get(file.name) != sha256(file):
            raise ReleaseError(f"{file.name} no longer matches its checksums.")
    return artifacts[0], info


def stage(tag, packages):
    """Copy both packages and their metadata into .local/releases/<tag>/."""
    target = RELEASES / tag
    files = {}
    for platform, (artifact, _) in packages.items():
        files[artifact.name] = artifact
        files[f"BUILD-{platform}.json"] = artifact.parent / "BUILD.json"
    if target.exists():
        for name, source in files.items():
            if not (target / name).is_file() or sha256(target / name) != sha256(source):
                raise ReleaseError(f".local/releases/{tag} does not match the packages; move it aside.")
    else:
        target.mkdir(parents=True, mode=0o700)
        for name, source in files.items():
            shutil.copyfile(source, target / name)
    sums = "".join(f"{sha256(target / name)}  {name}\n" for name in files)
    manifest = target / "SHA256SUMS-clients.txt"
    if manifest.exists() and manifest.read_text(encoding="utf-8") != sums:
        raise ReleaseError(f".local/releases/{tag}/SHA256SUMS-clients.txt does not match; move it aside.")
    manifest.write_text(sums, encoding="utf-8")
    return [target / name for name in files] + [manifest]


def notes_templates(label, version, revision, build, android):
    """Release notes for GitHub and for the app, prefilled with the facts."""
    short = revision[:7]
    github = f"""# Arveil {label}

TODO: one sentence on what this beta is and who it is for. The project has not had an independent security review.

## Packages

- Client version `{version}+{build}`, clean source `{revision}`.
- **Android** ARM64, Android 7.0 (API 24) or newer, signed with the maintained release certificate, SHA-256 `{android.get("certificate_sha256", "TODO")}`. **Settings → Updates** offers this version to earlier betas; you can also install the APK over the existing app. Never uninstall or clear the app's storage to update.
- **macOS** ARM64, macOS 12 or newer, ad-hoc signed, with no Developer ID or Apple notarization. With updates turned on, the app announces new versions and opens their download; replace the app in Applications, or run `brew upgrade --cask arveil`.
- Check `SHA256SUMS-clients.txt`, `BUILD-android.json` and `BUILD-macos.json`. The `clients-*.json` file is the signed update announcement for this build.

## Changes

- TODO

## Acceptance

- Both packages passed the signature, architecture, checksum and content-privacy audits and report clean source `{short}` and build {build}; the APK's versionCode is {build}.
- Every CI check passes on `{short}`.
- TODO: what was tried on which devices.

## Not yet verified

TODO
"""
    app = f"""Arveil {label} — TODO (español).

Arveil {label} — TODO (English).
"""
    return github, app


def notes(tag, label, version, revision, build, android):
    github, app = RELEASES / f"{tag}-notes.md", RELEASES / f"{tag}-app-notes.txt"
    written = []
    if not (github.exists() and app.exists()):
        for path, text in zip((github, app), notes_templates(label, version, revision, build, android)):
            if not path.exists():
                path.write_text(text, encoding="utf-8")
                written.append(path)
    if written or any("TODO" in p.read_text(encoding="utf-8") for p in (github, app)):
        raise ReleaseError("Write the release notes, remove every TODO, then run prepare again:\n  "
                           + "\n  ".join(str(shown(p)) for p in (github, app)), )
    return github, app


def announcement(feed, channel, build, packages):
    """The signed announcement for this build, if one was already written."""
    if not feed.is_dir():
        return None
    for path in sorted(feed.glob(f"clients-{channel}-*.json")):
        payload = json.loads(base64.b64decode(json.loads(path.read_text(encoding="utf-8"))["payload"]))
        platforms = payload.get("platforms", {})
        if all(platforms.get(f"{name}-arm64", {}).get("build") == build for name, _ in PLATFORMS):
            for name, _ in PLATFORMS:
                if platforms[f"{name}-arm64"].get("sha256") != sha256(packages[name][0]):
                    raise ReleaseError(f"{shown(path)} announces other packages for build {build}.")
            return path
    return None


def sign(config, channel, tag, repo, packages, app_notes, build):
    feed = RELEASES / f"{tag}-feed"
    existing = announcement(feed, channel, build, packages)
    if existing:
        return existing
    entries = ledger(config, channel)
    if not entries:
        raise ReleaseError(f"No {channel} announcement is recorded in the ledger; sign the first one "
                           "with scripts/client_updates.py and --sequence.")
    # The same build again is a retry whose announcement was never written;
    # a lower one would be refused by every app that has the higher one.
    if any(e.get("build", 0) > build for e in entries):
        raise ReleaseError(f"Build {build} is lower than a build already announced on {channel}.")
    sequence = max((e.get("sequence", 0) for e in entries), default=0) + 1
    feed.mkdir(parents=True, exist_ok=True, mode=0o700)
    output = feed / f"clients-{channel}-{sequence}.json"
    base = f"https://github.com/{repo}/releases"
    command = [sys.executable, str(ROOT / "scripts/client_updates.py"), "sign",
               "--key", str(config["update_key"]), "--config", str(config["update_config"]),
               "--package", str(packages["android"][0].parent), "--asset-url",
               f"{base}/download/{tag}/{packages['android'][0].name}",
               "--macos-package", str(packages["macos"][0].parent), "--macos-asset-url",
               f"{base}/download/{tag}/{packages['macos'][0].name}",
               "--notes", str(app_notes), "--notes-url", f"{base}/tag/{tag}",
               "--sequence", str(sequence), "--output", str(output)]
    # Interactive: the update key's passphrase is typed on this terminal.
    run(command, capture=False)
    if not output.is_file():
        raise ReleaseError("The announcement was not written; nothing was published.")
    return output


def release(repo, tag):
    """The GitHub release for [tag], draft or not, or None."""
    try:
        return json.loads(run(["gh", "api", f"repos/{repo}/releases/tags/{tag}"]))
    except ReleaseError:
        pass
    # Drafts have no tag yet, so the API does not find them by tag.
    for item in json.loads(run(["gh", "api", f"repos/{repo}/releases?per_page=50"])):
        if item.get("tag_name") == tag:
            return item
    return None


def assets_match(item, files):
    """Whether the release holds exactly [files], byte for byte."""
    remote = {a["name"]: a.get("digest") for a in item.get("assets", [])}
    local = {f.name: "sha256:" + sha256(f) for f in files}
    return remote == local


# --- Commands ---------------------------------------------------------------

def prepare(args):
    config = load_config()
    version, label = parse_tag(args.tag)
    if version != pubspec_version():
        raise ReleaseError(f"The tag says {version}; clients/flutter/pubspec.yaml says {pubspec_version()}.")
    distribution, channel = update_config(config)
    revision, head = release_revision(args.revision)
    repo = repository()
    checks_passed(repo, revision)
    existing = release(repo, args.tag)
    if existing and not existing.get("draft"):
        raise ReleaseError(f"{args.tag} is already published; run publish to finish the remaining steps.")

    packages = {}
    for platform, suffix in PLATFORMS:
        directory = package_dir(version, args.build, platform)
        if not directory.exists():
            if revision != head or run(["git", "status", "--porcelain"]).strip():
                raise ReleaseError(f"No {platform} package for {revision[:7]}; build it from a clean checkout "
                                   "of that commit, or release the checked-out one.")
            command = [sys.executable, str(ROOT / "scripts/package_clients.py"), "build", platform,
                       "--update-config", str(config["update_config"]), "--build-number", str(args.build)]
            if platform == "android":
                command += ["--signing-config", str(config["signing_config"])]
            print(f"Building {platform} {version}+{args.build}…", flush=True)
            run(command, capture=False)
        packages[platform] = check_package(directory, platform, suffix, revision, args.build, distribution)
    staged = stage(args.tag, packages)
    github_notes, app_notes = notes(args.tag, label, version, revision, args.build, packages["android"][1])
    feed = sign(config, channel, args.tag, repo, packages, app_notes, args.build)
    files = staged + [feed]

    if existing:
        if existing.get("target_commitish") != revision or not assets_match(existing, files):
            raise ReleaseError(f"A draft for {args.tag} exists with other contents; delete it on GitHub "
                               "and run prepare again.")
        url = existing["html_url"]
    else:
        run(["gh", "release", "create", args.tag, "--draft", "--prerelease", "--target", revision,
             "--title", f"Arveil {label}", "--notes-file", str(github_notes), *map(str, files)])
        url = release(repo, args.tag)["html_url"]
    print(f"Draft ready, nothing public yet: {url}\n"
          f"Review it, try the packages, then run: scripts/release_clients.py publish --tag {args.tag}")


def publish(args):
    config = load_config()
    version, label = parse_tag(args.tag)
    distribution, channel = update_config(config)
    repo = repository()
    staged = RELEASES / args.tag
    builds = {p: json.loads((staged / f"BUILD-{p}.json").read_text(encoding="utf-8")) for p, _ in PLATFORMS}
    revision, build = builds["android"]["revision"], builds["android"]["build"]
    packages = {p: (next(staged.glob(f"*{suffix}")), builds[p]) for p, suffix in PLATFORMS}
    feed = announcement(RELEASES / f"{args.tag}-feed", channel, build, packages)
    if feed is None:
        raise ReleaseError(f"No signed announcement for {args.tag}; run prepare first.")
    files = [staged / name for name in (*(p[0].name for p in packages.values()), "BUILD-android.json",
                                        "BUILD-macos.json", "SHA256SUMS-clients.txt")] + [feed]

    item = release(repo, args.tag)
    if item is None:
        raise ReleaseError(f"No release for {args.tag}; run prepare first.")
    if item.get("target_commitish") != revision or not item.get("prerelease") or not assets_match(item, files):
        raise ReleaseError(f"The {args.tag} release does not match the staged files; nothing was published.")
    if item.get("draft"):
        if not args.yes:
            if not sys.stdin.isatty():
                raise ReleaseError("Confirm on a terminal, or pass --yes once the draft is reviewed.")
            if input(f"Publish {args.tag}? It cannot be changed afterwards. "
                     "Type the tag to confirm: ").strip() != args.tag:
                raise ReleaseError("Not confirmed; nothing was published.")
        run(["gh", "release", "edit", args.tag, "--draft=false"])
        item = release(repo, args.tag)
    tag_commit = run(["git", "ls-remote", "origin", f"refs/tags/{args.tag}"]).split("\t")[0]
    if item.get("draft") or tag_commit != revision or not assets_match(item, files):
        raise ReleaseError(f"{args.tag} is not published as prepared; check it on GitHub.")
    print(f"Published {item['html_url']}")

    web = config.get("web")
    if web:
        publish_web(web, feed, channel, label, repo, args.tag, packages)
    tap = config.get("tap")
    if tap:
        bump_cask(tap, args.tag, version, build, packages["macos"][0])
    print("Done.")


# --- Website and Homebrew ---------------------------------------------------

def git_ready(repo):
    if run(["git", "status", "--porcelain"], cwd=repo).strip():
        raise ReleaseError(f"{repo.name} has local changes; commit or stash them first.")
    run(["git", "switch", "--quiet", "main"], cwd=repo)
    run(["git", "pull", "--quiet", "--ff-only"], cwd=repo)


def commit(repo, paths, message):
    run(["git", "add", *paths], cwd=repo)
    if run(["git", "status", "--porcelain"], cwd=repo).strip():
        run(["git", "commit", "--quiet", "-m", message], cwd=repo)
        run(["git", "push", "--quiet"], cwd=repo)
        return True
    return False


def publish_web(web, feed, channel, label, repo_name, tag, packages):
    repo = web["repo"]
    git_ready(repo)
    # Where the site keeps the announcement, and its tool that turns the
    # announcement into download links; both belong to the website.
    updates = web.get("updates", "arveil/updates")
    target = repo / updates / f"clients-{channel}.json"
    shutil.copyfile(feed, target)
    generator = web.get("generator", "tools/arveil-descargas.py")
    if (repo / generator).is_file():
        run([sys.executable, generator], cwd=repo)
    changed = [path for path in (updates.split("/")[0], "nginx") if (repo / path).exists()]
    commit(repo, changed, f"Arveil {label}: descargas y feed firmado")
    if web.get("ssh"):
        remote = (f"set -e; cd {web['dir']}; test -z \"$(git status --porcelain)\"; git pull --quiet --ff-only; "
                  f"docker compose up -d --quiet-pull >/dev/null; "
                  f"docker exec {web['container']} nginx -t -q; docker exec {web['container']} nginx -s reload")
        run(["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
             "-o", f"UserKnownHostsFile={web['known_hosts']}", web["ssh"], remote])
        check_live(web["site"], channel, feed, repo_name, tag, packages)
        lighthouse = f"cd {web['dir']} && tools/lighthouse.sh {web['site']}/ {web['site']}/es/"
        try:
            run(["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                 "-o", f"UserKnownHostsFile={web['known_hosts']}", web["ssh"], lighthouse])
            print("Lighthouse passed on the Arveil pages.")
        except ReleaseError:
            print("Warning: Lighthouse did not pass on the Arveil pages; review them.", file=sys.stderr)
    else:
        print("Website committed and pushed; deploy it yourself (no web ssh in .local/release.json).")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def check_live(site, channel, feed, repo, tag, packages):
    """The deployed feed is this one and /download/… point at this release."""
    opener = urllib.request.build_opener(NoRedirect)
    request = urllib.request.Request(f"{site}/updates/clients-{channel}.json", headers={"Cache-Control": "no-cache"})
    with opener.open(request, timeout=20) as response:
        if response.read() != feed.read_bytes():
            raise ReleaseError("The website does not serve the new announcement yet.")
    base = f"https://github.com/{repo}/releases"
    expected = {"android": f"{base}/download/{tag}/{packages['android'][0].name}",
                "macos": f"{base}/download/{tag}/{packages['macos'][0].name}",
                "notes": f"{base}/tag/{tag}"}
    for path, url in expected.items():
        try:
            opener.open(urllib.request.Request(f"{site}/download/{path}", method="HEAD"), timeout=20)
            location = None
        except urllib.error.HTTPError as error:
            location = error.headers.get("Location") if error.code == 302 else None
        if location != url:
            raise ReleaseError(f"{site}/download/{path} does not lead to this release.")
    print(f"{site} serves the announcement and /download/android, /download/macos and /download/notes.")


def cask_text(text, version, build, digest):
    """The cask with [version] and the ZIP's [digest]."""
    updated, count = re.subn(r'^(\s*version\s+)"[^"]*"', rf'\g<1>"{version},{build}"', text, count=1, flags=re.M)
    updated, count2 = re.subn(r'^(\s*sha256\s+)"[0-9a-f]{64}"', rf'\g<1>"{digest}"', updated, count=1, flags=re.M)
    if count != 1 or count2 != 1:
        raise ReleaseError("The cask has no version or sha256 line to update.")
    return updated


def bump_cask(tap, tag, version, build, archive):
    repo = tap["repo"]
    git_ready(repo)
    cask = repo / tap["cask"]
    cask_version = tag.removeprefix("clients-v")
    cask.write_text(cask_text(cask.read_text(encoding="utf-8"), cask_version, build, sha256(archive)),
                    encoding="utf-8")
    if commit(repo, [tap["cask"]], f"arveil {cask_version},{build}"):
        print(f"Homebrew cask bumped to {cask_version},{build}.")


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(required=True)
    first = commands.add_parser("prepare", help="build, stage, sign and create a draft prerelease")
    first.add_argument("--tag", required=True, help="for example clients-v0.1.0-beta.3")
    first.add_argument("--build", type=int, required=True, help="higher than every build already announced")
    first.add_argument("--revision", help="an earlier commit on origin/main whose packages are already built "
                                          "and tested (default: the checked-out one)")
    first.set_defaults(action=prepare)
    second = commands.add_parser("publish", help="publish the draft, then the website and the cask")
    second.add_argument("--tag", required=True)
    second.add_argument("--yes", action="store_true", help="do not ask to type the tag before publishing")
    second.set_defaults(action=publish)
    args = parser.parse_args()
    try:
        args.action(args)
    except ReleaseError as error:
        print(error, file=sys.stderr)
        return 1
    except (OSError, ValueError, KeyError, EOFError) as error:
        print(f"Release step failed ({error.__class__.__name__}); nothing further was done.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
