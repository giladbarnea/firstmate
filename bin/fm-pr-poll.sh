#!/usr/bin/env bash
# Static watcher program for a validated PR/MR poll sidecar.
# It emits one exact state for every validated poll: green, unresolved, a PR
# lifecycle event, or a credential/lookup error. The provider-tagged identity is
# data in the sidecar and is never interpolated into this source: these bytes are
# identical for every task.
# GitHub is read through gh. GitLab uses glab plus jq to classify its API JSON.
set -u
LC_ALL=C
export LC_ALL

if [ "$#" -eq 6 ] && [ "$1" = --validated ]; then
  provider=$2
  url=$3
  host=$4
  path=$5
  number=$6
elif [ "$#" -eq 0 ]; then
  case "$0" in
    *.check.sh) data=${0%.check.sh}.pr-poll ;;
    *) exit 0 ;;
  esac

  [ -f "$data" ] && [ ! -L "$data" ] || exit 0
  { exec 3< "$data"; } 2>/dev/null || exit 0
  IFS= read -r provider <&3 || exit 0
  IFS= read -r url <&3 || exit 0
  IFS= read -r host <&3 || exit 0
  IFS= read -r path <&3 || exit 0
  IFS= read -r number <&3 || exit 0
  if IFS= read -r _extra <&3; then
    exit 0
  fi
  exec 3<&-
else
  exit 0
fi

case "$number" in
  [1-9]*) ;;
  *) exit 0 ;;
esac
case "$number" in
  *[!0-9]*) exit 0 ;;
esac

# Every component is revalidated here rather than trusted from the sidecar, and
# the stored URL must then be exactly reconstructible from those components, so
# a doctored sidecar cannot redirect this poll at another host or project.
case "$provider" in
  github)
    [ "$host" = github.com ] || exit 0
    owner=${path%%/*}
    repo=${path#*/}
    [ "${#owner}" -ge 1 ] && [ "${#owner}" -le 39 ] || exit 0
    case "$owner" in
      *[!A-Za-z0-9-]*|-*|*-|*--*) exit 0 ;;
    esac
    [ "${#repo}" -ge 1 ] && [ "${#repo}" -le 100 ] || exit 0
    case "$repo" in
      .|..|*[!A-Za-z0-9._-]*) exit 0 ;;
    esac
    [ "$url" = "https://github.com/$owner/$repo/pull/$number" ] || exit 0
    command -v gh >/dev/null 2>&1 || { printf '%s\n' lookup-error; exit 0; }
    gh api user --hostname "$host" >/dev/null 2>&1 \
      || { printf '%s\n' credentials-needed; exit 0; }
    # shellcheck disable=SC2016  # The jq program expands its own $value variable.
    result=$(gh pr view "$url" --json state,mergeable,mergeStateStatus,statusCheckRollup --jq '
      def check_failed:
        if .__typename == "CheckRun" then
          .conclusion as $value
          | ["ACTION_REQUIRED", "CANCELLED", "FAILURE", "STARTUP_FAILURE", "TIMED_OUT"]
          | index($value) != null
        elif .__typename == "StatusContext" then
          .state as $value | ["ERROR", "FAILURE"] | index($value) != null
        else false
        end;
      def check_green:
        if .__typename == "CheckRun" then
          .conclusion as $value | ["NEUTRAL", "SKIPPED", "SUCCESS"] | index($value) != null
        elif .__typename == "StatusContext" then
          .state == "SUCCESS"
        else false
        end;
      if .state == "MERGED" then "merged"
      elif .state == "CLOSED" then "closed"
      elif .state != "OPEN" then "lookup-error"
      elif .mergeable == "CONFLICTING" or .mergeStateStatus == "DIRTY" then "conflict"
      elif any(.statusCheckRollup[]?; check_failed) then "checks-failed"
      elif .mergeable != "MERGEABLE" or .mergeStateStatus != "CLEAN" then "unresolved"
      elif all(.statusCheckRollup[]?; check_green) then "green"
      else "unresolved"
      end
    ' 2>/dev/null) || { printf '%s\n' lookup-error; exit 0; }
    case "$result" in
      green|unresolved|merged|closed|conflict|checks-failed|credentials-needed|lookup-error)
        printf '%s\n' "$result"
        ;;
      *) printf '%s\n' lookup-error ;;
    esac
    ;;
  gitlab)
    [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || exit 0
    [ "$host" != github.com ] || exit 0
    case "$host" in
      .*|*.|*..*|*[!a-z0-9.-]*) exit 0 ;;
    esac
    [ "${#path}" -ge 3 ] && [ "${#path}" -le 1024 ] || exit 0
    case "$path" in
      /*|*/|*//*) exit 0 ;;
    esac
    # A GitLab project sits under at least one group at no fixed depth, and
    # GitLab reserves the "-" segment as its route separator.
    rest=$path
    segments=0
    while [ -n "$rest" ]; do
      case "$rest" in
        */*) segment=${rest%%/*}; rest=${rest#*/} ;;
        *) segment=$rest; rest= ;;
      esac
      segments=$((segments + 1))
      [ "$segments" -le 20 ] || exit 0
      [ "${#segment}" -ge 1 ] && [ "${#segment}" -le 255 ] || exit 0
      case "$segment" in
        .|..|-*|*.git|*.atom|*[!A-Za-z0-9._-]*) exit 0 ;;
      esac
    done
    [ "$segments" -ge 2 ] || exit 0
    [ "$url" = "https://$host/$path/-/merge_requests/$number" ] || exit 0
    command -v glab >/dev/null 2>&1 || { printf '%s\n' lookup-error; exit 0; }
    command -v jq >/dev/null 2>&1 || { printf '%s\n' lookup-error; exit 0; }
    glab auth status --hostname "$host" >/dev/null 2>&1 \
      || { printf '%s\n' credentials-needed; exit 0; }
    encoded_path=${path//\//%2F}
    raw=$(glab api "projects/$encoded_path/merge_requests/$number?with_merge_status_recheck=true" \
      --hostname "$host" 2>/dev/null) || { printf '%s\n' lookup-error; exit 0; }
    result=$(printf '%s\n' "$raw" | jq -er '
      if .state == "merged" then "merged"
      elif .state == "closed" then "closed"
      elif .state != "opened" then "lookup-error"
      elif .has_conflicts == true or .detailed_merge_status == "conflict" then "conflict"
      elif ((.head_pipeline.status? // .pipeline.status? // "") as $value
        | ["failed", "canceled", "cancelled"] | index($value) != null) then "checks-failed"
      elif .detailed_merge_status != "mergeable" then "unresolved"
      elif ((.head_pipeline.status? // .pipeline.status? // "") as $value
        | $value == "" or $value == "success" or $value == "skipped") then "green"
      else "unresolved"
      end
    ' 2>/dev/null) || { printf '%s\n' lookup-error; exit 0; }
    case "$result" in
      green|unresolved|merged|closed|conflict|checks-failed|credentials-needed|lookup-error)
        printf '%s\n' "$result"
        ;;
      *) printf '%s\n' lookup-error ;;
    esac
    ;;
  *) exit 0 ;;
esac
exit 0
