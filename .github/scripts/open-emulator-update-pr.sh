#!/usr/bin/env bash
# Commit the rewritten version file to a new branch and open a PR for it.
# Run after `check-emulator-updates.sh --write` reported outdated=true.
#
# Usage: open-emulator-update-pr.sh path/to/emulator-versions.json
#
# Required environment:
#   GH_TOKEN     fine-grained PAT (Contents + Pull requests: read and write)
#   REPO         owner/repo
#   BASE_BRANCH  branch to open the PR against (the default branch)
#   BASE_SHA     commit the working tree was checked out at
#   VERSIONS     space-separated new emulator versions, newest first
#   RUN_URL      link to this workflow run (for the PR body)
#
# The commit is made with GraphQL createCommitOnBranch rather than `git push`,
# so no credentials are written to disk and GitHub signs the commit. (The REST
# Contents API does not sign commits made with a user token.) PRs opened with
# a PAT (unlike GITHUB_TOKEN) trigger the ci workflow, which GPG-verifies the
# new packages during the build.

set -euo pipefail

FILE="${1:?usage: open-emulator-update-pr.sh path/to/emulator-versions.json}"
: "${GH_TOKEN:?GH_TOKEN is empty: is the EMULATOR_UPDATE_TOKEN environment secret set?}"
: "${REPO:?}" "${BASE_BRANCH:?}" "${BASE_SHA:?}" "${VERSIONS:?}" "${RUN_URL:?}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/stdout}"

prefix="emulator-update/"
branch="${prefix}${VERSIONS// /_}"
title="Update emulator versions to ${VERSIONS// /, }"

if gh api "repos/${REPO}/branches/${branch}" --silent 2>/dev/null; then
  echo "Branch ${branch} already exists; the PR for these versions is already open."
  echo "Update PR for \`${VERSIONS}\` already open (branch \`${branch}\`)." >> "${SUMMARY}"
  exit 0
fi

# Create the branch at the commit this run checked out.
gh api -X POST "repos/${REPO}/git/refs" \
  -f ref="refs/heads/${branch}" -f sha="${BASE_SHA}" --silent

# Commit the new file on that branch as a GitHub-signed commit.
# expectedHeadOid makes the API refuse the commit if the branch has moved.
jq -n \
  --arg repo "${REPO}" --arg branch "${branch}" --arg head "${BASE_SHA}" \
  --arg title "${title}" --arg path "${FILE}" --arg contents "$(base64 -w0 "${FILE}")" \
  '{
    query: "mutation($input: CreateCommitOnBranchInput!) { createCommitOnBranch(input: $input) { commit { oid } } }",
    variables: {input: {
      branch: {repositoryNameWithOwner: $repo, branchName: $branch},
      expectedHeadOid: $head,
      message: {headline: $title},
      fileChanges: {additions: [{path: $path, contents: $contents}]}
    }}
  }' \
  | gh api graphql --input - --jq '"Committed \(.data.createCommitOnBranch.commit.oid)"'

body="$(cat <<EOF
The emulator version list no longer tracks the newest releases. This PR moves
it to \`${VERSIONS}\` (newest gets \`:latest\`).

The SHA-256 pins were computed from the packages as downloaded by the update
check. The CI build on this PR GPG-verifies every package against the pinned
AWS signing key, so only merge once CI passes.

Opened by [emulator updates](${RUN_URL}).
EOF
)"

url="$(gh pr create --repo "${REPO}" --base "${BASE_BRANCH}" --head "${branch}" \
  --title "${title}" --body "${body}")"
echo "Opened ${url}"

# Close earlier update PRs this one supersedes (no comment is posted).
gh pr list --repo "${REPO}" --state open --limit 100 --json number,headRefName \
  --jq ".[] | select(.headRefName | startswith(\"${prefix}\")) | select(.headRefName != \"${branch}\") | .number" \
  | while read -r n; do
      echo "Closing superseded PR #${n}"
      gh pr close "${n}" --repo "${REPO}" --delete-branch
    done

echo "Opened update PR: ${url}" >> "${SUMMARY}"
