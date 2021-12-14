#!/usr/bin/env bash
#
# Ensure that a PR does not introduce downstream breakages on this project's dependents by
# performing checks using this branch's code. If dependents are specified as companions, they are
# patched to use the code we have in this branch; otherwise, we run the the checks against their
# default branch.

# Companion dependents are extracted from the PR's description when lines conform to the following
# formats:
# [cC]ompanion: https://github.com/org/repo/pull/pr_number
# [cC]ompanion: org/repo#pr_number
# [cC]ompanion: repo#pr_number

echo "

check_dependent_project
========================

This check ensures that this project's dependents do not suffer downstream breakages from new code
changes.

"

set -eu -o pipefail
shopt -s inherit_errexit

die() {
  if [ "${1:-}" ]; then
    >&2 echo "$1"
  fi
  exit 1
}

org="$1"
this_repo="$2"
this_repo_diener_arg="$3"
dependent_repo="$4"
github_api_token="$5"
update_crates_on_default_branch="$6"

this_repo_dir="$PWD"
companions_dir="$this_repo_dir/companions"
github_api="https://api.github.com"

# valid for 69ab0f76fb851968af8e493061cca84a2f3b1c5b
# FIXME: extract this information from the diener CLI when that is supported
diener_patch_targets=(substrate polkadot cumulus)

our_crates=()
our_crates_source="git+https://github.com/$org/$this_repo"
discover_our_crates() {
  # workaround for early exits not being detected in command substitution
  # https://unix.stackexchange.com/questions/541969/nested-command-substitution-does-not-stop-a-script-on-a-failure-even-if-e-and-s
  local last_line

  local found
  while IFS= read -r crate; do
    last_line="$crate"
    # for avoiding duplicate entries
    for our_crate in "${our_crates[@]}"; do
      if [ "$crate" == "$our_crate" ]; then
        found=true
        break
      fi
    done
    if [ "${found:-}" ]; then
      unset found
    else
      our_crates+=("$crate")
    fi
  # dependents with {"source": null} are the ones we own, hence the getpath($p)==null in the jq
  # script below
  done < <(cargo metadata --quiet --format-version=1 | jq -r '
    . as $in |
    paths |
    select(.[-1]=="source" and . as $p | $in | getpath($p)==null) as $path |
    del($path[-1]) as $path |
    $in | getpath($path + ["name"])
  ')
  if [ -z "${last_line+_}" ]; then
    die "No lines were read for cargo metadata of $PWD (some error probably occurred)"
  fi
}

match_their_crates() {
  local target_name="$1"
  local crates_not_found=()
  local found

  # workaround for early exits not being detected in command substitution
  # https://unix.stackexchange.com/questions/541969/nested-command-substitution-does-not-stop-a-script-on-a-failure-even-if-e-and-s
  local last_line

  # output will be consumed in the format:
  #   crate
  #   source
  #   crate
  #   ...
  local next="crate"
  while IFS= read -r line; do
    last_line="$line"
    case "$next" in
      crate)
        next="source"
        crate="$line"
      ;;
      source)
        next="crate"
        if [ "$line" == "$our_crates_source" ] || [[ "$line" == "$our_crates_source?"* ]]; then
          for our_crate in "${our_crates[@]}"; do
            if [ "$our_crate" == "$crate" ]; then
              found=true
              break
            fi
          done
          if [ "${found:-}" ]; then
            unset found
          else
            # for avoiding duplicate entries
            for crate_not_found in "${crates_not_found[@]}"; do
              if [ "$crate_not_found" == "$crate" ]; then
                found=true
                break
              fi
            done
            if [ "${found:-}" ]; then
              unset found
            else
              crates_not_found+=("$crate")
            fi
          fi
        fi
      ;;
      *)
        die "ERROR: Unknown state $next"
      ;;
    esac
  done < <(cargo metadata --quiet --format-version=1 | jq -r '
    . as $in |
    paths(select(type=="string")) |
    select(.[-1]=="source") as $source_path |
    del($source_path[-1]) as $path |
    [$in | getpath($path + ["name"]), getpath($path + ["source"])] |
    .[]
  ')
  if [ -z "${last_line+_}" ]; then
    die "No lines were read for cargo metadata of $PWD (some error probably occurred)"
  fi

  if [ "${crates_not_found[@]}" ]; then
    echo -e "Errors during crate matching\n"
    printf "Failed to detect our crate \"%s\" referenced in $target_name\n" "${crates_not_found[@]}"
    echo -e "\nNote: this error generally happens if you have deleted or renamed a crate and did not update it in $target_name. Consider opening a companion pull request on $target_name and referencing it in this pull request's description like:\n$target_name companion: [your companion PR here]"
    die "Check failed"
  fi
}

companions=()
process_pr_description_line() {
  local companion_expr="$1"

  # e.g. https://github.com/paritytech/polkadot/pull/123
  # or   polkadot#123
  if
    [[ "$companion_expr" =~ ^https://github\.com/$org/([^/]+)/pull/([[:digit:]]+) ]] ||
    [[ "$companion_expr" =~ ^$org/([^#]+)#([[:digit:]]+) ]] ||
    [[ "$companion_expr" =~ ^([^#]+)#([[:digit:]]+) ]]
  then
    local repo="${BASH_REMATCH[1]}"
    local pr_number="${BASH_REMATCH[2]}"

    echo "Parsed companion repo=$repo and pr_number=$pr_number from $companion_expr"

    if [ "$this_repo" == "$repo" ]; then
      echo "Skipping $companion_expr it refers to the repository where this script is currently running"
      return
    fi

    # keep track of duplicated companion references not only to avoid useless
    # work but also to avoid infinite mutual recursion when 2+ PRs reference
    # each other
    for comp in "${companions[@]}"; do
      if [ "$comp" == "$repo" ]; then
        echo "Skipping $companion_expr as the repository $repo has already been registered before"
        return
      fi
    done
    companions+=("$repo")

    git clone --depth=1 "https://github.com/$org/$repo.git" "$companions_dir/$repo"
    pushd "$repo" >/dev/null
    local ref="$(curl \
        -sSL \
        -H "Authorization: token $github_api_token" \
        "$github_api/repos/$org/$repo/pulls/$pr_number" | \
      jq -e -r ".head.ref // error(\"$repo#$pr_number is missing head.ref\"))"
    )"
    git fetch --depth=1 origin "pull/$pr_number/head:$ref"
    git checkout "$ref"
    popd >/dev/null

    # collect also the companions of companions
    process_pr_description "$repo" "$pr_number"
  else
    die "Companion PR description had invalid format or did not belong to organization $org: $companion_expr"
  fi
}

process_pr_description() {
  local repo="$1"
  local pr_number="$2"

  if ! [[ "$pr_number" =~ ^[[:digit:]]+$ ]]; then
    return
  fi

  echo "processing pull request $repo#$pr_number"

  local lines=()
  while IFS= read -r line; do
    lines+=("$line")
  done < <(curl \
      -sSL \
      -H "Authorization: token $github_api_token" \
      "$github_api/repos/$org/$this_repo/pulls/$CI_COMMIT_REF_NAME" | \
    jq -e -r ".body"
  )
  if [ ! "${lines[@]:-}" ]; then
    die "No lines were read for the description of PR $pr_number (some error probably occurred)"
  fi

  # first check if the companion is disabled *somewhere* in the PR description
  # before doing any work
  for line in "${lines[@]}"; do
    if
      [[ "$line" =~ skip[^[:alnum:]]+([^[:space:]]+) ]] &&
      [[ "$repo" == "$dependent_repo" ]] &&
      [[
        "${BASH_REMATCH[1]}" = "$CI_JOB_NAME" ||
        "${BASH_REMATCH[1]}" = "continuous-integration/gitlab-$CI_JOB_NAME"
      ]]
    then
      # FIXME: This escape hatch should be removed at some point when the
      # companion build system is able to deal with all edge cases, such as
      # the one described in
      # https://github.com/paritytech/pipeline-scripts/issues/3#issuecomment-947539791
      echo "Skipping $CI_JOB_NAME as specified in the PR description"
      exit
    fi
  done

  for line in "${lines[@]}"; do
    if [[ "$line" =~ [cC]ompanion:[[:space:]]*([^[:space:]]+) ]]; then
      echo "Detected companion in the PR description of $repo#$pr_number: ${BASH_REMATCH[1]}"
      process_pr_description_line "${BASH_REMATCH[1]}"
    fi
  done
}

patch_and_check_dependent() {
  local dependent="$1"

  pushd "$dependent" >/dev/null

  match_their_crates "$dependent"

  # Update the crates to the latest version.
  #
  # This is for example needed if there was a pr to Substrate that only required a Polkadot companion
  # and Cumulus wasn't yet updated to use the latest commit of Polkadot.
  for update in $update_crates_on_default_branch; do
    cargo update -p "$update"
  done

  for comp in "${companions[@]}"; do
    local found
    for diener_target in "${diener_patch_targets[@]}"; do
      if [ "$diener_target" = "$comp" ]; then
        echo "Patching $comp into $dependent"
        diener patch --crates-to-patch "--$diener_target" "$companions_dir/$comp" --path "Cargo.toml"
        found=true
        break
      fi
    done
    if [ "${found:-}" ]; then
      unset found
    else
      echo "NOTE: Companion $comp was specified but not patched through diener. Perhaps diener does not support it."
    fi
  done

  diener patch --crates-to-patch "$this_repo_dir" "$this_repo_diener_arg" --path "Cargo.toml"
  eval "${COMPANION_CHECK_COMMAND:-cargo check --all-targets --workspace}"

  popd >/dev/null
}

main() {
  # Set the user name and email to make merging work
  git config --global user.name 'CI system'
  git config --global user.email '<>'
  git config --global pull.rebase false

  echo
  echo "merging master into the pr..."
  # Merge master into our branch so that the compilation takes into account how the code is going to
  # perform when the code for this pull request lands on the target branch (à la pre-merge pipelines).
  # Note that the target branch might not actually be master, but we default to it in the assumption
  # of the common case. This could be refined in the future.
  git fetch origin +master:master
  git fetch origin "+$CI_COMMIT_REF_NAME:$CI_COMMIT_REF_NAME"
  git checkout "$CI_COMMIT_REF_NAME"
  git merge master --verbose --no-edit -m "master was merged into the pr by check_dependent_project.sh main()"
  echo "merging master into the pr: done"
  echo

  discover_our_crates

  process_pr_description "$this_repo" "$CI_COMMIT_REF_NAME"

  patch_and_check_dependent "$dependent_repo"
}
main
