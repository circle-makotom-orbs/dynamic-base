#!/bin/bash

set -euo pipefail

base_branch=""
continue_parameters="{}"

get_pr_base_branch() {
    if [[ ! -v GITHUB_API_TOKEN ]]; then
        echo Environment variable '`'GITHUB_API_TOKEN'`' is not set.
        return
    fi

    pr_url="${1}"
    gh_repo_slug="$(awk -F/ '{ print $4 "/" $5; }' <<<"${pr_url}")"
    gh_pr_num="$(cut -d/ -f7 <<<"${pr_url}")"
    gh_api_endpoint="https://api.github.com/repos/${gh_repo_slug}/pulls/${gh_pr_num}"

    echo Fetching "${gh_api_endpoint}":
    api_resp="$(curl -fsSL -H "Authorization: Bearer ${GITHUB_API_TOKEN}" -H "Accept: application/vnd.github+json" "${gh_api_endpoint}" | tee /dev/stderr)"
    base_branch="$(jq -r .base.ref <<<"${api_resp}")"

    echo Detected a pull request with the base branch "${base_branch}".
}

get_nearest_branch() {
    if ! git status; then
        echo Cannot run on an invalid Git reposotory. Maybe worth to run '`'pwd'`'?
        return
    fi
    echo

    nearest_branch=""
    nearest_branch_fork_generation=500

    hashes_in_history="$(git log --format=tformat:%H | head -n "${nearest_branch_fork_generation}")"

    while read -r branch; do
        echo Examining "${branch}":

        branch_head="$(git merge-base HEAD "${branch}")"
        echo The common ancestor shared among the current HEAD and the branch "${branch}" is at "${branch_head}",

        generations=$(("$(awk "/${branch_head}/{ print NR; exit }" <<<"${hashes_in_history}")" - 1))
        echo that is "${generations}" 'generation(s)' above the current HEAD.
        if [[ "${generations}" -eq 0 ]]; then
            echo Actually that means "${branch}" is pointing the current HEAD. Ignoring...
        elif [[ "${generations}" -lt "${nearest_branch_fork_generation}" ]]; then
            echo Remembering as it looks like the nearest branch so far.
            nearest_branch="${branch}"
            nearest_branch_fork_generation="${generations}"
        fi

        echo
    done < <(git branch -r | grep -v 'origin/HEAD')

    if [[ "${nearest_branch}" != "" ]]; then
        base_branch="${nearest_branch/#origin\//}"

        echo Detected the nearest branch "${base_branch}".
        echo Fork is at "${nearest_branch_fork_generation}" 'generation(s)' above.
    else
        echo Nearest branch was not found.
    fi
}

if [[ ! -v CIRCLE_CONTINUATION_KEY ]]; then
    echo No continuation key is set, there is nothing we can do.
    exit
fi

if [[ -v CIRCLE_PULL_REQUEST ]]; then
    get_pr_base_branch "${CIRCLE_PULL_REQUEST}"
    echo
fi

if [[ -z "${base_branch}" ]] && [[ "${CIRCLE_BRANCH}" == "${DEFAULT_BRANCH}" ]]; then
    echo We are on the default branch "${CIRCLE_BRANCH}".
    base_branch="${CIRCLE_BRANCH}"
    echo
fi

if [[ -z "${base_branch}" ]]; then
    get_nearest_branch
    echo
fi

if [[ -z "${base_branch}" ]]; then
    echo Defaulting to the default branch.
    base_branch="${DEFAULT_BRANCH}"
    echo
fi

echo Base branch was set to "${base_branch}".
echo Fetching the branch from remote:
git fetch origin "${base_branch}"
echo

diffs=$(
    cat <<EOD
$(git diff --name-only "origin/${base_branch}")
$(git diff --name-only HEAD~1 || git ls-tree -r --name-only HEAD)
EOD
)

while read -r cond; do
    pattern=$(cut -d$'\t' -f1 <<<"${cond}")
    param_name=$(cut -d$'\t' -f2 <<<"${cond}")

    # Truthy if:
    #   1)  `force-all` is set to `true`,
    #   2)  there is any difference against `${base_branch}` or `HEAD~1` (the previous commit), or
    #   3)  there is no `HEAD~1` (i.e., this is the very first commit for the repo).
    if [[ "${FORCE_ALL}" == 'true' ]] || grep -qs "^${pattern}\$" <<<"${diffs}"; then
        export param_name
        continue_parameters="$(jq '.[$ENV.param_name] = true' <<<"${continue_parameters}")"
        unset param_name
    fi
done <<<"${PARAMETER_CONDITIONS}"

continue_body="$(jq \
    --rawfile config "${CONTINUE_CONFIG_PATH}" \
    -s '{
        "continuation-key": $ENV.CIRCLE_CONTINUATION_KEY,
        configuration: $config,
        parameters: .[0]
    }' <<<"${continue_parameters}" | tee /dev/stderr)"
echo

echo Continuing...!
curl \
    -X POST \
    -H "Content-Type: application/json" \
    --data-binary "${continue_body}" \
    -w '\n%{http_code}\n' \
    "https://circleci.com/api/v2/pipeline/continue"
