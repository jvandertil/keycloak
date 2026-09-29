#!/usr/bin/env python3
"""Propose an exact upstream Quay tag, changing both Dockerfile stages."""
import json
import re
import subprocess
import urllib.request
from pathlib import Path

dockerfile = Path("Dockerfile")
content = dockerfile.read_text()
pattern = re.compile(r"^(FROM quay\.io/keycloak/keycloak:)([^\s]+)(.*)$", re.M)
matches = pattern.findall(content)
if len(matches) != 2 or matches[0][1] != matches[1][1]:
    raise SystemExit("expected two matching literal Keycloak FROM references")
current = matches[0][1]

request = urllib.request.Request(
    "https://api.github.com/repos/keycloak/keycloak/releases?per_page=30",
    headers={"Accept": "application/vnd.github+json", "User-Agent": "keycloak-upstream-check"},
)
with urllib.request.urlopen(request, timeout=30) as response:
    releases = json.load(response)

versions = []
for release in releases:
    tag = release["tag_name"]
    if not release["draft"] and not release["prerelease"] and re.fullmatch(r"\d+\.\d+\.\d+", tag):
        versions.append((tuple(map(int, tag.split("."))), tag))

if not versions:
    raise SystemExit("no stable Keycloak releases found")

for _, version in sorted(versions, reverse=True):
    for candidate in (version + "-0", version):
        result = subprocess.run(
            ["docker", "manifest", "inspect", f"quay.io/keycloak/keycloak:{candidate}"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
        )
        if result.returncode == 0:
            latest = candidate
            break
    else:
        continue
    break
else:
    raise SystemExit("no matching Quay tag for recent stable releases")

if tuple(map(int, latest.split("-")[0].split("."))) <= tuple(map(int, current.split("-")[0].split("."))):
    print(f"No newer release than {current}")
    raise SystemExit(0)

dockerfile.write_text(pattern.sub(lambda m: m.group(1) + latest + m.group(3), content))
print(f"Updated both stages: {current} -> {latest}")
