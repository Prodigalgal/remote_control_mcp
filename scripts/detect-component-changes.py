#!/usr/bin/env python3
"""Select component checks from a Git diff or its last published release."""

import argparse
import json
import os
import subprocess


RELEASE_TAGS = {"center": "center-published-*", "agent": "agent-published-*",
                "console": "console-published-*"}
JAVA_SHARED = {"java/build.gradle.kts", "java/settings.gradle.kts", "java/gradle.properties",
               "java/gradlew", "java/gradlew.bat"}


def matches(component: str, path: str) -> bool:
    common = path in JAVA_SHARED or path.startswith("java/gradle/")
    protocol = path.startswith("java/protocol/")
    if component != "contract" and path == "scripts/prepare-component-release.py":
        return True
    if component == "contract":
        return common or protocol
    if component == "center":
        return (common or protocol or path.startswith("java/center/")
                or path.startswith("java/Dockerfile.center")
                or path.startswith("web/src/artifact-viewer/")
                or path.startswith("scripts/sync-artifact-viewer")
                or path.startswith("scripts/verify-native-bundle")
                or path == ".github/workflows/center-release.yml")
    if component == "agent":
        return (common or protocol or path.startswith(("java/agent/", "java/desktop/", "java/browser/", "java/updater/"))
                or path.startswith(("java/Dockerfile.agent", "java/Dockerfile.desktop", "java/Dockerfile.browser", "java/Dockerfile.updater"))
                or path.startswith(("scripts/install-agent", "scripts/first-install-agent",
                                    "scripts/build-native", "scripts/verify-agent-boundaries.py",
                                    "scripts/detect-component-changes.py",
                                    "scripts/deploy-desktop-browser", "scripts/browser-worker",
                                    "scripts/repair-agent-task", "scripts/test-windows-scripts", "scripts/wake-machine",
                                    "scripts/smoke-browser-runtime", "scripts/normalize-native-isa",
                                    "scripts/verify-native-bundle", "scripts/browser-runtime/", "deploy/systemd/"))
                or path in {".github/workflows/agent-release.yml", ".github/workflows/agent-publish.yml",
                            "scripts/verify-release-recovery.py"})
    if component == "console":
        return path.startswith("web/") or path == ".github/workflows/console-release.yml"
    raise ValueError(f"unknown component: {component}")


def git(*args: str) -> str:
    return subprocess.check_output(["git", *args], text=True, encoding="utf-8").strip()


def changed_files(head: str, base: str | None) -> list[str]:
    if base:
        return git("diff", "--name-only", base, head).splitlines()
    return git("ls-tree", "-r", "--name-only", head).splitlines()


def published_component_tags(component: str, releases: list[dict]) -> list[str]:
    import re
    prefix = {"agent": "java-", "center": "center-", "console": "console-"}[component]
    return sorted({release['tag_name'] for release in releases
                   if release.get('draft') is False and release.get('published_at')
                   and re.fullmatch(re.escape(prefix) + r'v[0-9A-Za-z][0-9A-Za-z._+-]{0,127}', release.get('tag_name', ''))})


def published_agent_tags(releases: list[dict]) -> list[str]:
    return published_component_tags('agent', releases)


def last_release(component: str, head: str) -> str | None:
    matches = [RELEASE_TAGS[component]]
    if os.environ.get('GITHUB_REPOSITORY'):
        pages = json.loads(subprocess.check_output(
            ['gh', 'api', f"repos/{os.environ['GITHUB_REPOSITORY']}/releases?per_page=100",
             '--paginate', '--slurp'], text=True, encoding='utf-8'))
        published = published_component_tags(component, [release for page in pages for release in page])
        matches = published + ([] if component == 'agent' else matches)
        if not published and component == 'agent':
            return None
    try:
        return subprocess.check_output(
            ["git", "describe", "--tags", "--first-parent",
             *[arg for pattern in matches for arg in ('--match', pattern)], "--abbrev=0", head],
            text=True, encoding="utf-8", stderr=subprocess.DEVNULL).strip()
    except subprocess.CalledProcessError:
        return None


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("component", choices=(*RELEASE_TAGS, "contract"))
    parser.add_argument("--head", required=True)
    baseline = parser.add_mutually_exclusive_group(required=True)
    baseline.add_argument("--base", help="explicit PR comparison commit")
    baseline.add_argument("--since-release", action="store_true",
                          help="compare with the last published component tag")
    args = parser.parse_args()
    base = last_release(args.component, args.head) if args.since_release else args.base
    print("true" if any(matches(args.component, path) for path in changed_files(args.head, base)) else "false")


if __name__ == "__main__":
    main()
