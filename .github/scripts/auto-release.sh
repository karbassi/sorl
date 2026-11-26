#!/usr/bin/env bash
# Called by .github/workflows/auto-release.yml, from a checkout of main. Works out the next version from the PRs merged
# since the last stable tag, adds their CHANGELOG.md section, and pushes the changelog commit and the tag together.
#
# Env: REPO (owner/name), EVENT_PR, EVENT_SHA, GITHUB_OUTPUT. Needs `gh` (GH_TOKEN) and `jq`.
# Writes tag=<vX.Y.Z> to GITHUB_OUTPUT when it released, nothing when there was nothing to release.
#
# Why it's built this way (the v1.4.0 incident, 2026-11-26): the changelog commit and the tag used to be two pushes.
# The tag push failed after the commit had landed, so main got a v1.4.0 section with no v1.4.0 tag; the next run worked
# from tags, computed v1.4.0 again and added a second section. Now:
# - main and the tag go up in one `git push --atomic`, so both land or neither does;
# - a rejected or failed push starts over from the new main and recomputes the version and section, instead of
#   rebasing a commit whose version may be stale;
# - any section for a version that has no tag (left by some older failure) is dropped before the new one goes in. Its
#   PRs are still unreleased, so they are listed again in the new section.
set -euo pipefail

attempts=${AUTO_RELEASE_ATTEMPTS:-5}
retry_delay=${AUTO_RELEASE_RETRY_DELAY:-5}

release_once() {
  # Latest stable tag; prereleases like v0.2.0-rc.3 don't count.
  last=$(git tag -l 'v*' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n 1 || true)
  if [[ -n "$last" ]]; then
    range="$last..HEAD"
  else
    range="HEAD"
  fi
  echo "Last release: ${last:-none}"

  # PRs merged since the last tag, read from main's merge commits, plus this event's PR if it isn't already released
  # (covers a squash merge, which has no "Merge pull request" subject).
  mapfile -t prs < <(git log --first-parent --merges --format=%s "$range" \
    | sed -nE 's/^Merge pull request #([0-9]+) from .*/\1/p')
  if [[ -z "$last" ]] || ! git merge-base --is-ancestor "$EVENT_SHA" "$last" 2>/dev/null; then
    prs+=("$EVENT_PR")
  fi
  mapfile -t prs < <(printf '%s\n' "${prs[@]}" | sed '/^$/d' | sort -n -u)

  bump=0 # 1 patch, 2 minor, 3 major
  entries=""
  for pr in "${prs[@]}"; do
    json=$(gh pr view "$pr" --repo "$REPO" --json title,url,labels,mergedAt)
    if [[ $(jq -r '.mergedAt // ""' <<<"$json") == "" ]]; then
      continue
    fi
    labels=$(jq -r '.labels[].name' <<<"$json")
    if grep -qx 'skip-release' <<<"$labels"; then
      echo "#$pr: skip-release"
      continue
    fi
    if grep -qx 'major' <<<"$labels"; then
      level=3
    elif grep -qx 'patch' <<<"$labels"; then
      level=1
    else
      level=2
    fi
    if (( level > bump )); then bump=$level; fi
    title=$(jq -r '.title' <<<"$json")
    url=$(jq -r '.url' <<<"$json")
    echo "#$pr: level $level, $title"
    entries+="- ${title} ([#${pr}](${url}))"$'\n'
  done

  tag=""
  if (( bump == 0 )); then
    echo "Nothing to release."
    return 0
  fi

  IFS=. read -r major minor patch <<<"${last#v}"
  major=${major:-0} minor=${minor:-0} patch=${patch:-0}
  case $bump in
    3) major=$((major + 1)); minor=0; patch=0 ;;
    2) minor=$((minor + 1)); patch=0 ;;
    1) patch=$((patch + 1)) ;;
  esac
  tag="v$major.$minor.$patch"
  if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    echo "::error::$tag already exists"
    exit 1
  fi
  echo "Releasing $tag"

  if [[ ! -f CHANGELOG.md ]]; then
    printf '# Changelog\n\n' > CHANGELOG.md
  fi

  # Versions that have a section but no tag: leftovers of a release that never finished.
  untagged=""
  while read -r v; do
    if ! git rev-parse -q --verify "refs/tags/$v" >/dev/null; then
      echo "::warning::Dropping CHANGELOG section $v: it has no tag, so its PRs are released again in $tag"
      untagged+=" $v "
    fi
  done < <(sed -nE 's/^## \[(v[0-9]+\.[0-9]+\.[0-9]+)\].*/\1/p' CHANGELOG.md | sort -u)

  # New section above the newest one (the first "## " line); untagged sections are left out.
  section="## [$tag](https://github.com/$REPO/releases/tag/$tag) - $(date -u +%Y-%m-%d)"$'\n\n'"$entries"
  SECTION="$section" UNTAGGED="$untagged" awk '
    /^## / {
      v = $0; sub(/^## \[/, "", v); sub(/\].*/, "", v)
      skip = index(ENVIRON["UNTAGGED"], " " v " ") > 0
      if (!done) { printf "%s\n", ENVIRON["SECTION"]; done = 1 }
    }
    !skip { print }
    END { if (!done) printf "\n%s", ENVIRON["SECTION"] }
  ' CHANGELOG.md > CHANGELOG.md.new
  mv CHANGELOG.md.new CHANGELOG.md
  git --no-pager diff CHANGELOG.md

  git add CHANGELOG.md
  # A push with GITHUB_TOKEN starts no workflow, so this commit can't retrigger a release; [skip ci] keeps it that way
  # if the token ever changes.
  git commit -q -m "Release $tag [skip ci]"
  git tag -a "$tag" -m "$tag"
}

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

for (( attempt = 1; attempt <= attempts; attempt++ )); do
  # Start every attempt from the remote's main and tags, so the version is worked out from what's really there.
  git fetch -q --force origin main '+refs/tags/*:refs/tags/*'
  git reset -q --hard origin/main

  release_once
  if [[ -z "$tag" ]]; then
    exit 0
  fi

  if git push --atomic origin HEAD:main "refs/tags/$tag"; then
    echo "tag=$tag" >> "$GITHUB_OUTPUT"
    exit 0
  fi

  # The push may have landed even though the client saw an error. Our tag object on the remote means it did.
  ours=$(git rev-parse "refs/tags/$tag")
  if [[ $(git ls-remote origin "refs/tags/$tag" | cut -f1) == "$ours" ]]; then
    echo "Push of $tag landed despite the error"
    echo "tag=$tag" >> "$GITHUB_OUTPUT"
    exit 0
  fi

  echo "::warning::Push of $tag rejected (attempt $attempt of $attempts); starting over from the new main"
  git tag -d "$tag" >/dev/null
  sleep $(( retry_delay * attempt ))
done

echo "::error::Couldn't push a release after $attempts attempts"
exit 1
