#!/usr/bin/env bash

## A script for publishing workspace crates to a target crates.io instance.
## This script requires:
## - A working PostgreSQL v13 database
## - Some environment variables to be set up in advance (see how the check-publish-crates job is set
##   up on CI for reference)
## TODO: This script will be moved later to releng-scripts

echo "

publish-crates
========================

This script publishes all workspace crates to the target crates.io instance of choice. It can either
publish them to a local crates.io instance (which is set up by this script) or the official
crates.io registry.
"

set -Eeu -o pipefail
shopt -s inherit_errexit

root="$PWD"
tmp="$root/.tmp"
cratesio_dir="$tmp/crates.io"
cargo_home="$tmp/cargo-home"
cargo_target_dir="$tmp/cargo"
yj="$tmp/yj"

on_exit() {
  local exit_code=$?
  pkill -P "$$" || :
  exit $exit_code
}
trap on_exit EXIT

die() {
  local exit_code=$?

  local kill_group
  if [ "${2:-}" ]; then
    case "$1" in
      all)
        kill_group="$(ps -o pgid= $$ | tr -d " ")"
      ;;
      "") ;;
      *)
        log "Invalid operation $1; ignoring"
      ;;
    esac
    shift
  fi

  if [ "${1:-}" ]; then
    >&2 log "$1"
  fi

  if [ "${kill_group:-}" ]; then
    kill -- "-$kill_group"
  else
    pkill -P "$$" || :
  fi

  if [ "$exit_code" -ne 0 ]; then
    exit "$exit_code"
  else
    exit 1
  fi
}

set -xv

setup_local_cratesio() {
  load_workspace_crates

  git clone --branch releng https://github.com/paritytech/crates.io "$cratesio_dir"

  >/dev/null pushd "$cratesio_dir"

  mkdir local_uploads tmp

  local cratesio_token_prefix="--$$--"

  diesel migration run --locked-schema

  script/init-local-index.sh

  local pipe="$tmp/pipe"
  mkfifo "$pipe"

  export GIT_REPO_URL="file://$PWD/tmp/index-bare"
  export GH_CLIENT_ID=
  export GH_CLIENT_SECRET=
  export WEB_ALLOWED_ORIGINS=http://localhost:8888,http://localhost:4200
  export SESSION_KEY=badkeyabcdefghijklmnopqrstuvwxyzabcdef
  export CRATESIO_TOKEN_PREFIX="$cratesio_token_prefix"
  export WEB_NEW_PKG_RATE_LIMIT_BURST=10248
  export CRATESIO_LOCAL_CRATES="${workspace_crates[*]}"
  cargo run --quiet --bin server | while IFS= read -r line; do
    case "$line" in
      "$cratesio_token_prefix="*)
        echo "${line:$(( ${#cratesio_token_prefix} + 1 ))}" > "$pipe"
      ;;
      *)
        log "$line"
      ;;
    esac
  done || die all "Crates.io server failed" &

  log "Waiting for token from crates.io server..."
  local token
  token="$(cat "$pipe")"
  log "Got token from crates.io server: $token"

  local crate_committed_msg_prefix="Commit and push finished for \"Updating crate \`"
  export SPUB_CRATES_COMMITTED_FILE="$tmp/crates-committed"
  touch "$SPUB_CRATES_COMMITTED_FILE"

  # need set TMPDIR to disk because crates.io index is too big for tmpfs on RAM
  local old_tmpdir="${TMPDIR:-}"
  mkdir -p tmp/worker-tmp
  export TMPDIR="$PWD/tmp/worker-tmp"
  cargo run --quiet --bin background-worker | while IFS= read -r line; do
    log "$line"
    case "$line" in
      "Runner booted, running jobs")
        echo "$line" > "$pipe"
      ;;
      # example line: Commit and push finished for "Updating crate `foo#0.1.0`"
      "$crate_committed_msg_prefix"*)
        line_remainder="${line:${#crate_committed_msg_prefix}}"
        if [[ "$line_remainder" =~ ^([^#]+)# ]]; then
          echo "${BASH_REMATCH[1]}" >> "$SPUB_CRATES_COMMITTED_FILE"
        else
          die all "background-worker line had unexpected format: $line"
        fi
      ;;
    esac
  done || die all "Crates.io background-worker failed" &
  if [ "$old_tmpdir" ]; then
    export TMPDIR="$old_tmpdir"
  else
    unset TMPDIR
    export -n TMPDIR
  fi
  unset old_tmpdir

  log "Waiting for the workers to be ready..."
  read -r < "$pipe"
  log "Workers are ready"

  >/dev/null popd

  export SPUB_REGISTRY=local
  export SPUB_CRATES_API=http://localhost:8888/api/v1
  export CARGO_REGISTRIES_LOCAL_INDEX=file://"$cratesio_dir"/tmp/index-bare
  export SPUB_REGISTRY_TOKEN="$token"
}

setup_subpub() {
  local old_cargo_target_dir="${CARGO_TARGET_DIR:-}"
  export CARGO_TARGET_DIR="$cargo_target_dir"

  cargo install --quiet --git https://github.com/paritytech/subpub --branch releng
  subpub --version

  if [ "$old_cargo_target_dir" ]; then
    export CARGO_TARGET_DIR="$old_cargo_target_dir"
  else
    unset CARGO_TARGET_DIR
    export -n CARGO_TARGET_DIR
  fi
}

setup_diesel() {
  local old_cargo_target_dir="${CARGO_TARGET_DIR:-}"
  export CARGO_TARGET_DIR="$cargo_target_dir"

  cargo install --quiet diesel_cli \
    --version 1.4.1 \
    --no-default-features \
    --features postgres
  diesel --version

  if [ "$old_cargo_target_dir" ]; then
    export CARGO_TARGET_DIR="$old_cargo_target_dir"
  else
    unset CARGO_TARGET_DIR
    export -n CARGO_TARGET_DIR
  fi
}

setup_postgres() {
  apt install -qq --assume-yes --no-install-recommends postgresql-11 libpq-dev sudo
  pg_ctlcluster 11 main start

  local db_user=pg
  local db_password=pg
  local db_name=crates_io
  export DATABASE_URL="postgres://$db_user:$db_password@localhost:5432/$db_name"

  log "Attempting to connect to the database @ $DATABASE_URL"
  local is_db_ready
  for ((i=0; i < 8; i++)); do
    if pg_isready -d "$DATABASE_URL"; then
      is_db_ready=true
      break
    else
      sleep 8
    fi
  done
  if [ ! "${is_db_ready:-}" ]; then
    die "Timed out on database connection"
  fi

  sudo -u postgres createuser -s -i -d -r -l -w "$db_user"
  sudo -u postgres createdb --owner "$db_user" "$db_name"
  sudo -u postgres psql -c "ALTER USER $db_user WITH ENCRYPTED PASSWORD '$db_password';"
}

load_workspace_crates() {
  if [ "${workspace_crates:-}" ]; then
    return
  fi
  readarray -t workspace_crates < <(
    cargo tree --quiet --workspace --depth 0 --manifest-path "$root/Cargo.toml" |
    awk '{ if (length($1) == 0 || substr($1, 1, 1) == "[") { skip } else { print $1 } }' |
    sort |
    uniq
  )
  log "workspace crates: ${workspace_crates[*]}"
  if [ ${#workspace_crates[*]} -lt 1 ]; then
    die "No workspace crates detected for $root"
  fi
}

setup_yj() {
  if [ -e "$yj" ]; then
    return
  fi

  curl -sSLf -o "$yj" https://github.com/sclevine/yj/releases/download/v5.1.0/yj-linux-amd64

  local expected_checksum="8ce43e40fda9a28221dabc0d7228e2325d1e959cd770487240deb47e02660986  $yj"

  local actual_checksum
  actual_checksum="$(sha256sum "$yj")"

  if [ "$expected_checksum" != "$actual_checksum" ]; then
    die "File had invalid checksum: $yj
Expected: $expected_checksum
Actual: $actual_checksum"
  fi

  chmod +x "$yj"
}

check_cratesio_crate() {
  local crate="$1"
  local cratesio_api="$2"
  local crate_manifest="$3"
  local expected_owner="$4"

  log "Checking if the crate $crate is compliant with crates.io"

  local owners_url="$cratesio_api/v1/crates/$crate/owners"

  local owners_response exit_code
  owners_response="$(curl -sSLf "$owners_url")" || exit_code=$?
  case "$exit_code" in
    22) # 404, crates doesn't exist on crates.io
      >&2 echo "Crate $crate does not yet exist on crates.io. Please contact release-engineering to reserve the name in advance."
      return 1
    ;;
    0) ;;
    *)
      >&2 echo "Request to $owners_url failed with exit code $exit_code"
      return 1
    ;;
  esac

  local owners_logins
  owners_logins="$(echo -n "$owners_response" | jq -r '.users[] | .login')"

  local found_owner
  while IFS= read -r owner_login; do
    if [ "$owner_login" == "$expected_owner" ]; then
      found_owner=true
      break
    fi
  done < <(echo "$owners_logins")

  if [ ! "${found_owner:-}" ]; then
    >&2 echo "Crate $crate was detected from $crate_manifest.

Upon querying $owners_url, we found the following owners on https://crates.io/api:
$owners_logins

Failed to find owner $expected_owner among the above owners.

Those owners were extracted from the following response:
$owners_response
"
    return 1
  fi
}

check_cratesio() {
  local cratesio_api="$1"
  local cratesio_crates_owner="$2"
  local gh_api="$3"
  local this_branch="$4"

  local selected_crates=()

  if [[ "$this_branch" =~ ^[[:digit:]]+$ ]]; then
    local pr_number="$this_branch"

    while IFS= read -r changed_file; do
      case "$changed_file" in
        */Cargo.toml)
          setup_yj
          local crate_name
          crate_name="$("$yj" -tj < "$changed_file" | jq -r '.package.name')"
          if [ "$crate_name" == null ]; then
            die "Failed to parse .package.name of $changed_file"
          fi
          selected_crates+=("$crate_name" "$changed_file")
        ;;
      esac
    done < <(
      (
        curl -sSLf \
          -H "Authorization: token $GITHUB_PR_TOKEN" \
          "$gh_api/repos/$REPO_OWNER/$REPO/pulls/$pr_number/files" |
        jq -r '.[] | .filename'
      ) || die all "Failed to get changed files for PR $pr_number"
    ) || :
  else
    load_workspace_crates
    selected_crates=("${workspace_crates[@]}")
  fi

  local exit_code
  for ((i=0; i < ${#selected_crates[*]}; i+=2)); do
    local crate="${selected_crates[$i]}"
    local crate_manifest="${selected_crates[$((i+1))]}"
    if ! check_cratesio_crate \
      "$crate" \
      "$cratesio_api" \
      "$crate_manifest" \
      "$cratesio_crates_owner"
    then
      exit_code=1
    fi
  done

  if [ "${exit_code:-}" ]; then
    exit "$exit_code"
  fi
}

setup_cargo() {
  mkdir -p "$cargo_target_dir"
  export PATH="$cargo_target_dir/release:$PATH"
  # use custom $CARGO_TARGET_DIR because rusty-cachier's setup is not working
  # e.g. https://gitlab.parity.io/parity/mirrors/substrate/-/jobs/2092904#L7397
  export CARGO_TARGET_DIR="$cargo_target_dir"
  # TODO: don't set CARGO_HOME, use rusty-cachier
  mkdir -p "$cargo_home"
  export PATH="$cargo_home/bin:$PATH"
  export CARGO_HOME="$cargo_home"
}

main() {
  # shellcheck disable=SC2153 # lowercase name
  local cratesio_target_instance="$CRATESIO_TARGET_INSTANCE"
  # shellcheck disable=SC2153 # lowercase name
  local cratesio_crates_owner="$CRATESIO_CRATES_OWNER"
  # shellcheck disable=SC2153 # lowercase name
  local gh_api="$GH_API"
  # shellcheck disable=SC2153 # lowercase name
  local cratesio_api="$CRATESIO_API"
  # shellcheck disable=SC2153 # lowercase name
  local spub_start_from="${SPUB_START_FROM:-}"
  # shellcheck disable=SC2153 # lowercase name
  local spub_publish="${SPUB_PUBLISH:-}"
  # shellcheck disable=SC2153 # lowercase name
  local spub_verify_from="${SPUB_VERIFY_FROM:-}"
  # shellcheck disable=SC2153 # lowercase name
  local spub_after_publish_delay="${SPUB_AFTER_PUBLISH_DELAY:-}"
  # shellcheck disable=SC2153 # lowercase name
  local spub_exclude="${SPUB_EXCLUDE:-}"
  local this_branch="$CI_COMMIT_REF_NAME"

  mkdir -p "$tmp"
  export PATH="$tmp:$PATH"
  echo "/.tmp" > "$tmp/.gitignore"
  git config core.excludesFile "$tmp/.gitignore"

  setup_cargo

  setup_subpub

  if [[ $- =~ x ]]; then
    # when -x is set up the logged messages will be printed during execution, so there's no need to
    # also echo them; create a no-op executable for this purpose
    touch "$tmp/log"
    chmod +x "$tmp/log"
  else
    ln -s "$(which echo)" "$tmp/log"
  fi

  # TODO: enable when squatted crates are dealt with (paritytech/release-engineering#132)
  # check_cratesio \
  #   "$cratesio_api" \
  #   "$cratesio_crates_owner" \
  #   "$gh_api" \
  #   "$this_branch"

  case "$cratesio_target_instance" in
    local)
      git config --global user.name "CI"
      git config --global user.email "<>"

      apt update -qq
      setup_postgres
      setup_diesel
      setup_local_cratesio
    ;;
    default)
      export SPUB_CRATES_API=http://crates.io/api/v1
    ;;
    *)
      die "Invalid target: $cratesio_target_instance"
    ;;
  esac

  local args=(publish --post-check --root "$PWD")

  if [ "$spub_start_from" ]; then
    args+=(--start-from "$spub_start_from")
  fi

  while IFS= read -r crate; do
    if [[ "$crate" =~ [^[:space:]]+ ]]; then
      args+=(-c "${BASH_REMATCH[0]}")
    else
      die "Crate name had unexpected format: $crate"
    fi
  done < <(echo "$spub_publish")

  while IFS= read -r crate; do
    if [[ "$crate" =~ [^[:space:]]+ ]]; then
      args+=(-e "${BASH_REMATCH[0]}")
    else
      die "Crate name had unexpected format: $crate"
    fi
  done < <(echo "$spub_exclude")

  if [ "$spub_verify_from" ]; then
    args+=(-v "$spub_verify_from")
  fi

  if [ "$spub_after_publish_delay" ]; then
    args+=(--after-publish-delay "$spub_after_publish_delay")
  fi

  subpub "${args[@]}"
}

main "$@"
