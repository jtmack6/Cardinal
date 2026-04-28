#!/usr/bin/env bash
# Move three patched submodules onto your own GitHub forks so the patches
# survive `git submodule update` and live in real commits instead of as
# undocumented working-tree edits.
#
# Auto-creates the forks via `gh repo fork` if they don't exist yet, then
# moves each submodule onto your fork with the patch committed on a
# `cardinal-local` branch.
#
# Default GH user is jtmack6; override with GITHUB_USER=...
#
# Idempotent: safe to re-run. Skips work that's already done.

set -euo pipefail

GITHUB_USER="${GITHUB_USER:-jtmack6}"
BRANCH="cardinal-local"

CARDINAL_ROOT="$(git rev-parse --show-toplevel)"
cd "$CARDINAL_ROOT"

if [[ ! -d plugins/MindMeldModular || ! -d plugins/4msCompany || ! -d plugins/surgext ]]; then
    echo "ERROR: not in Cardinal repo root, or submodules missing." >&2
    echo "Expected to find plugins/MindMeldModular, plugins/4msCompany, plugins/surgext" >&2
    exit 1
fi

# Pre-flight: gh CLI must be installed and authed (via gh auth login OR
# a GITHUB_PAT/GH_TOKEN/GITHUB_TOKEN env var).
if ! command -v gh &>/dev/null; then
    echo "ERROR: gh CLI not found. Install with 'brew install gh'." >&2
    exit 1
fi

# gh respects GH_TOKEN and GITHUB_TOKEN automatically. If the user has a
# GITHUB_PAT instead, copy it into GH_TOKEN so gh picks it up.
if [[ -n "${GITHUB_PAT:-}" && -z "${GH_TOKEN:-}" && -z "${GITHUB_TOKEN:-}" ]]; then
    export GH_TOKEN="$GITHUB_PAT"
    echo "Using GITHUB_PAT for gh auth (exported as GH_TOKEN)"
fi

if ! gh auth status &>/dev/null; then
    echo "ERROR: gh not authenticated." >&2
    echo "  Either run 'gh auth login', or export GITHUB_PAT/GH_TOKEN/GITHUB_TOKEN." >&2
    exit 1
fi

gh_user_actual=$(gh api user -q .login 2>/dev/null || echo "")
if [[ -n "$gh_user_actual" && "$gh_user_actual" != "$GITHUB_USER" ]]; then
    echo "WARNING: gh is authenticated as '$gh_user_actual' but GITHUB_USER='$GITHUB_USER'."
    echo "  Forks will be created under '$gh_user_actual'."
    echo "  If that's not what you want, ctrl-C and either:"
    echo "    GITHUB_USER=$gh_user_actual ./$(basename "$0")"
    echo "  or 'gh auth switch' to a different account."
    sleep 3
fi

echo "Cardinal root: $CARDINAL_ROOT"
echo "GitHub user:   $GITHUB_USER"
echo "Branch:        $BRANCH"
echo

# ---------------------------------------------------------------------------
# Per-submodule fork helper
# ---------------------------------------------------------------------------
# Args:
#   $1 = submodule path inside Cardinal (e.g. plugins/MindMeldModular)
#   $2 = upstream owner (e.g. MarcBoule)
#   $3 = upstream repo name (e.g. MindMeldModular — name of the upstream
#        repo, NOT the path inside Cardinal; the fork takes the same name)
#   $4 = patched file path inside the submodule
#   $5 = commit subject
#   $6 = commit body
fork_submodule() {
    local path="$1"
    local upstream_owner="$2"
    local fork_repo="$3"
    local file="$4"
    local subject="$5"
    local body="$6"
    local sm="$CARDINAL_ROOT/$path"
    local upstream_repo="${upstream_owner}/${fork_repo}"
    local fork_repo_full="${GITHUB_USER}/${fork_repo}"
    # SSH form is stored as the remote URL (no creds embedded).
    # If SSH doesn't work we'll switch to HTTPS via gh's credential helper.
    local fork_url="git@github.com:${fork_repo_full}.git"

    echo "================================================================"
    echo "Submodule: $path"
    echo "Upstream:  $upstream_repo"
    echo "Fork:      $fork_repo_full"
    echo "Patch:     $file"
    echo "================================================================"

    # ---- 1. Ensure fork exists on GitHub; create via `gh repo fork` if not ----
    if gh repo view "$fork_repo_full" &>/dev/null; then
        echo "  fork already exists on GitHub"
    else
        echo "  creating fork via gh repo fork…"
        # --clone and --remote omitted: don't clone (we already have the
        # submodule checkout) and don't add a remote (we manage that below).
        gh repo fork "$upstream_repo" --default-branch-only
        echo "  fork created"
    fi

    # ---- 2. Verify access to the fork. Try SSH first; if that fails and a
    #         PAT is available, configure gh as a git credential helper and
    #         switch to HTTPS (no creds embedded in URLs). ----
    if git ls-remote --exit-code "$fork_url" &>/dev/null; then
        echo "  fork reachable over SSH: OK"
    elif [[ -n "${GH_TOKEN:-${GITHUB_TOKEN:-${GITHUB_PAT:-}}}" ]]; then
        echo "  SSH unreachable; switching to HTTPS via gh credential helper"
        # gh auth setup-git configures git to call gh for github.com creds.
        # Idempotent: safe to run repeatedly.
        gh auth setup-git
        fork_url="https://github.com/${fork_repo_full}.git"
        if ! git ls-remote --exit-code "$fork_url" &>/dev/null; then
            echo "  ERROR: HTTPS also failed. Check the PAT has 'repo' scope."
            return 1
        fi
        echo "  fork reachable over HTTPS (creds via gh helper): OK"
    else
        echo "  ERROR: cannot reach $fork_url over SSH"
        echo "  Either add your SSH key at https://github.com/settings/keys"
        echo "  or export GITHUB_PAT (PAT with 'repo' scope) and re-run."
        return 1
    fi

    # ---- 2. Branch creation (or reuse) ----
    if git -C "$sm" show-ref --verify --quiet "refs/heads/$BRANCH"; then
        echo "  branch $BRANCH already exists; checking out"
        git -C "$sm" checkout "$BRANCH"
    else
        echo "  creating $BRANCH at current HEAD"
        git -C "$sm" checkout -b "$BRANCH"
    fi

    # ---- 3. Stage + commit the patch (only if there's a diff) ----
    if git -C "$sm" diff --quiet -- "$file"; then
        # No staged or unstaged diff for this file. Either it was already
        # committed in a prior run of this script, or the patch was lost.
        if git -C "$sm" log -1 --format='%s' -- "$file" 2>/dev/null | grep -qF "$subject"; then
            echo "  patch already committed in $BRANCH; skipping"
        else
            echo "  WARNING: no diff in $file and no matching commit found."
            echo "  The patch may have been lost (e.g. by 'git submodule update')."
            echo "  Re-apply the patch manually before re-running this script."
            echo "  See plugins/4msCompany_INTEGRATION.md or CLAUDE.md for recipes."
            return 1
        fi
    else
        git -C "$sm" add "$file"
        git -C "$sm" commit -m "$subject" -m "$body"
        echo "  committed: $subject"
    fi

    # ---- 4. Remote setup: origin = fork, upstream = original ----
    local current_origin
    current_origin=$(git -C "$sm" remote get-url origin 2>/dev/null || echo "")
    if [[ "$current_origin" != "$fork_url" ]]; then
        if ! git -C "$sm" remote get-url upstream &>/dev/null; then
            # No 'upstream' yet. Rename current origin → upstream, add fork as
            # origin. Convention: origin = where you push, upstream = original.
            if [[ -n "$current_origin" ]]; then
                git -C "$sm" remote rename origin upstream
                echo "  renamed origin → upstream ($current_origin)"
            fi
            git -C "$sm" remote add origin "$fork_url"
            echo "  added origin = $fork_url"
        else
            # 'upstream' already exists; just point origin at the fork.
            git -C "$sm" remote set-url origin "$fork_url"
            echo "  set origin = $fork_url"
        fi
    else
        echo "  origin already points at fork"
    fi

    # ---- 5. Push to fork ----
    git -C "$sm" push -u origin "$BRANCH"

    local sha
    sha=$(git -C "$sm" rev-parse HEAD)
    echo "  HEAD: $sha"
    echo
}

# ---------------------------------------------------------------------------
# Run for each patched submodule
# ---------------------------------------------------------------------------

fork_submodule \
    "plugins/MindMeldModular" \
    "MarcBoule" \
    "MindMeldModular" \
    "src/ShapeMaster/Shape.hpp" \
    "Cardinal: replace std::abs<T> with ternary (macOS 26 SDK fix)" \
    "macOS 26 SDK libc++ declares integer std::abs as non-template overloads
in <__math/abs.h>. The explicit-template form std::abs<T>(...) for
floating types becomes ambiguous against them. Replace with a
header-free ternary since Shape.hpp doesn't include <cmath> directly.

Without this patch, build fails in Shape::calcY<float>/<double>,
cascading into DisplayUtil.cpp, DisplayLight.cpp, Display.cpp, and
Channel.cpp."

fork_submodule \
    "plugins/4msCompany" \
    "4ms" \
    "4ms-vcv" \
    "src/network/network.cpp" \
    "Cardinal: drop unused openssl include and CURL_STATICLIB define" \
    "openssl/crypto.h is included upstream but no openssl symbols are
actually referenced in this file (curl's SSL verify option is configured
via CURLOPT_SSL_VERIFYPEER, which is part of libcurl proper). Cardinal
doesn't ship openssl as a build dep, and CURL_STATICLIB is a no-op when
linking against the system libcurl dylib that ships with macOS.
Commenting out both makes the file build inside Cardinal's tree without
forcing openssl into the build."

fork_submodule \
    "plugins/surgext" \
    "surge-synthesizer" \
    "surge-rack" \
    "src/VCO.cpp" \
    "Cardinal: remove .template qualifier on emplace_back (clang strictness)" \
    "Newer clang rejects the redundant .template prefix on dependent member
access where the template keyword isn't actually needed. The two
emplace_back calls in OSCPlotWidget compile fine without it."

# ---------------------------------------------------------------------------
# Update parent .gitmodules to point at the forks
# ---------------------------------------------------------------------------

echo "================================================================"
echo "Updating parent .gitmodules"
echo "================================================================"

git config -f .gitmodules submodule."plugins/MindMeldModular".url \
    "git@github.com:${GITHUB_USER}/MindMeldModular.git"
git config -f .gitmodules submodule."plugins/4msCompany".url \
    "git@github.com:${GITHUB_USER}/4ms-vcv.git"
git config -f .gitmodules submodule."plugins/surgext".url \
    "git@github.com:${GITHUB_USER}/surge-rack.git"

# Push the URL changes into .git/config so future submodule ops use the fork
git submodule sync plugins/MindMeldModular plugins/4msCompany plugins/surgext

echo
echo "Updated .gitmodules:"
git diff .gitmodules | sed 's/^/    /'

echo
echo "================================================================"
echo "DONE."
echo "================================================================"
echo
echo "Submodule pins (parent will record these):"
for sm in plugins/MindMeldModular plugins/4msCompany plugins/surgext; do
    sha=$(git -C "$sm" rev-parse HEAD)
    echo "  $sm  →  $sha"
done

echo
echo "Inspect, then commit the parent change:"
echo "    git status"
echo "    git diff --staged"
echo "    git add .gitmodules plugins/MindMeldModular plugins/4msCompany plugins/surgext"
echo "    git commit -m 'Pin patched submodules to local forks'"
echo "    git push"
