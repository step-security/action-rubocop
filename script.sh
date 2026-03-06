#!/usr/bin/env bash

set -e
set -o pipefail

# validate subscription status
UPSTREAM="reviewdog/action-rubocop"
ACTION_REPO="${GITHUB_ACTION_REPOSITORY:-}"
DOCS_URL="https://docs.stepsecurity.io/actions/stepsecurity-maintained-actions"

echo ""
echo -e "\033[1;36mStepSecurity Maintained Action\033[0m"
echo "Secure drop-in replacement for $UPSTREAM"
if [ "$REPO_PRIVATE" = "false" ]; then
  echo -e "\033[32m✓ Free for public repositories\033[0m"
fi
echo -e "\033[36mLearn more:\033[0m $DOCS_URL"
echo ""

if [ "$REPO_PRIVATE" != "false" ]; then
  SERVER_URL="${GITHUB_SERVER_URL:-https://github.com}"

  if [ "$SERVER_URL" != "https://github.com" ]; then
    BODY=$(printf '{"action":"%s","ghes_server":"%s"}' "$ACTION_REPO" "$SERVER_URL")
  else
    BODY=$(printf '{"action":"%s"}' "$ACTION_REPO")
  fi

  API_URL="https://agent.api.stepsecurity.io/v1/github/$GITHUB_REPOSITORY/actions/maintained-actions-subscription"

  RESPONSE=$(curl --max-time 3 -s -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$BODY" \
    "$API_URL" -o /dev/null) && CURL_EXIT_CODE=0 || CURL_EXIT_CODE=$?

  if [ $CURL_EXIT_CODE -ne 0 ]; then
    echo "Timeout or API not reachable. Continuing to next step."
  elif [ "$RESPONSE" = "403" ]; then
    echo -e "::error::\033[1;31mThis action requires a StepSecurity subscription for private repositories.\033[0m"
    echo -e "::error::\033[31mLearn how to enable a subscription: $DOCS_URL\033[0m"
    exit 1
  fi
fi

cd "${GITHUB_WORKSPACE}/${INPUT_WORKDIR}" || exit
export REVIEWDOG_GITHUB_API_TOKEN="${INPUT_GITHUB_TOKEN}"

TEMP_PATH="$(mktemp -d)"
PATH="${TEMP_PATH}:$PATH"

echo '::group::🐶 Installing reviewdog ... https://github.com/reviewdog/reviewdog'
curl -sfL https://raw.githubusercontent.com/reviewdog/reviewdog/fd59714416d6d9a1c0692d872e38e7f8448df4fc/install.sh | sh -s -- -b "${TEMP_PATH}" "${REVIEWDOG_VERSION}" 2>&1
echo '::endgroup::'

if [ "${INPUT_SKIP_INSTALL}" = "false" ]; then
  echo '::group:: Installing rubocop with extensions ... https://github.com/rubocop/rubocop'
  # if 'gemfile' rubocop version selected
  if [ "${INPUT_RUBOCOP_VERSION}" = "gemfile" ]; then
    # if Gemfile.lock is here
    if [ -f 'Gemfile.lock' ]; then
      # grep for rubocop version
      RUBOCOP_GEMFILE_VERSION=$(ruby -ne 'print $& if /^\s{4}rubocop\s\(\K.*(?=\))/' Gemfile.lock)

      # if rubocop version found, then pass it to the gem install
      # left it empty otherwise, so no version will be passed
      if [ -n "$RUBOCOP_GEMFILE_VERSION" ]; then
        RUBOCOP_VERSION=$RUBOCOP_GEMFILE_VERSION
      else
        printf "Cannot get the rubocop's version from Gemfile.lock. The latest version will be installed."
      fi
    else
      printf 'Gemfile.lock not found. The latest version will be installed.'
    fi
  else
    # set desired rubocop version
    RUBOCOP_VERSION=$INPUT_RUBOCOP_VERSION
  fi

  gem install -N rubocop --version "${RUBOCOP_VERSION}"

  # Traverse over list of rubocop extensions
  IFS=' ' read -ra RUBOCOP_EXTENSIONS <<< "${INPUT_RUBOCOP_EXTENSIONS}"
  for extension in "${RUBOCOP_EXTENSIONS[@]}"; do
    # grep for name and version
    INPUT_RUBOCOP_EXTENSION_NAME=$(echo "$extension" |awk 'BEGIN { FS = ":" } ; { print $1 }')
    INPUT_RUBOCOP_EXTENSION_VERSION=$(echo "$extension" |awk 'BEGIN { FS = ":" } ; { print $2 }')

    # if version is 'gemfile'
    if [ "${INPUT_RUBOCOP_EXTENSION_VERSION}" = "gemfile" ]; then
      # if Gemfile.lock is here
      if [ -f 'Gemfile.lock' ]; then
        # grep for rubocop extension version
        RUBOCOP_EXTENSION_GEMFILE_VERSION=$(EXT_NAME="$INPUT_RUBOCOP_EXTENSION_NAME" ruby -ne 'print $& if /^\s{4}#{Regexp.escape(ENV["EXT_NAME"])}\s\(\K.*(?=\))/' Gemfile.lock)

        # if rubocop extension version found, then pass it to the gem install
        # left it empty otherwise, so no version will be passed
        if [ -n "$RUBOCOP_EXTENSION_GEMFILE_VERSION" ]; then
          RUBOCOP_EXTENSION_VERSION=$RUBOCOP_EXTENSION_GEMFILE_VERSION
        else
          printf "Cannot get the rubocop extension version from Gemfile.lock. The latest version will be installed."
        fi
      else
        printf 'Gemfile.lock not found. The latest version will be installed.'
      fi
    else
      # set desired rubocop extension version
      RUBOCOP_EXTENSION_VERSION=$INPUT_RUBOCOP_EXTENSION_VERSION
    fi

    # Handle extensions with no version qualifier
    if [ -z "${RUBOCOP_EXTENSION_VERSION}" ]; then
      gem install -N "${INPUT_RUBOCOP_EXTENSION_NAME}"
    else
      gem install -N "${INPUT_RUBOCOP_EXTENSION_NAME}" --version "${RUBOCOP_EXTENSION_VERSION}"
    fi
  done
  echo '::endgroup::'
fi

export REVIEWDOG_GITHUB_API_TOKEN="${INPUT_GITHUB_TOKEN}"

if [ "${INPUT_USE_BUNDLER}" = "false" ]; then
  BUNDLE_EXEC=""
else
  BUNDLE_EXEC="bundle exec "
fi

# Parse flags into arrays for safe expansion (prevents glob expansion)
IFS=' ' read -ra RUBOCOP_FLAGS <<< "${INPUT_RUBOCOP_FLAGS}"
IFS=' ' read -ra REVIEWDOG_FLAGS <<< "${INPUT_REVIEWDOG_FLAGS}"

if [ "${INPUT_ONLY_CHANGED}" = "true" ]; then
  echo '::group:: Getting changed files list'

  # check if commit is present in repository, otherwise fetch it
  if ! git cat-file -e "${BASE_REF}"; then
    git fetch --depth 1 origin "${BASE_REF}"
  fi

  # get intersection of changed files (excluding deleted) with target files for
  # rubocop as an array
  # shellcheck disable=SC2086
  readarray -t CHANGED_FILES < <(
    comm -12 \
      <(git diff --relative --diff-filter=d --name-only "${BASE_REF}..${HEAD_REF}" | sort || kill $$) \
      <(${BUNDLE_EXEC}rubocop --list-target-files | sort || kill $$)
  )

  if (( ${#CHANGED_FILES[@]} == 0 )); then
    echo "No relevant files for rubocop, skipping"
    exit 0
  fi

  printf '%s\n' "${CHANGED_FILES[@]}"

  if (( ${#CHANGED_FILES[@]} > 100 )); then
    echo "More than 100 changed files (${#CHANGED_FILES[@]}), running rubocop on all files"
    unset CHANGED_FILES
  fi

  echo '::endgroup::'
fi

echo '::group:: Running rubocop with reviewdog 🐶 ...'
# shellcheck disable=SC2086
${BUNDLE_EXEC}rubocop \
  --require "${GITHUB_ACTION_PATH}/rdjson_formatter/rdjson_formatter.rb" \
  --format RdjsonFormatter \
  --fail-level error \
  "${RUBOCOP_FLAGS[@]}" \
  "${CHANGED_FILES[@]}" \
  | reviewdog -f=rdjson \
      -name="${INPUT_TOOL_NAME}" \
      -reporter="${INPUT_REPORTER}" \
      -filter-mode="${INPUT_FILTER_MODE}" \
      -fail-level="${INPUT_FAIL_LEVEL}" \
      -fail-on-error="${INPUT_FAIL_ON_ERROR}" \
      -level="${INPUT_LEVEL}" \
      "${REVIEWDOG_FLAGS[@]}"

reviewdog_rc=$?
echo '::endgroup::'
exit $reviewdog_rc
