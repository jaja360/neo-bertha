#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="longhorn-system"
TARGET_IMAGE=""
MODE="report"
ASSUME_YES="false"
LIMIT="0"

usage() {
  cat <<'EOF'
Migrate Longhorn volumes to a single engine image.

Usage:
  scripts/longhorn-engine-migrate.sh [options]

Options:
  --namespace NS                 Default: longhorn-system
  --mode MODE                    One of: report, detached, attached, all (default: report)
  --limit N                      Max volumes to patch per phase/run (0 = no limit, default: 0)
  --yes                          Skip confirmation prompts for attached upgrade and cleanup
  -h, --help                     Show this help

Recommended rollout:
  1) report
  2) detached
  3) attached (low-traffic window)

Examples:
  scripts/longhorn-engine-migrate.sh --mode report
  scripts/longhorn-engine-migrate.sh --mode detached
  scripts/longhorn-engine-migrate.sh --mode detached --limit 20
  scripts/longhorn-engine-migrate.sh --mode attached --yes
  scripts/longhorn-engine-migrate.sh --mode all --yes
EOF
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

log() {
  printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"
}

confirm_or_exit() {
  local prompt="$1"
  if [[ "$ASSUME_YES" == "true" ]]; then
    return 0
  fi
  read -r -p "$prompt [y/N]: " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || exit 1
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --namespace)
        NAMESPACE="$2"
        shift 2
        ;;
      --mode)
        MODE="$2"
        shift 2
        ;;
      --limit)
        LIMIT="$2"
        shift 2
        ;;
      --yes)
        ASSUME_YES="true"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown argument: $1" >&2
        usage
        exit 1
        ;;
    esac
  done

  case "$MODE" in
    report|detached|attached|all) ;;
    *)
      echo "Invalid --mode: $MODE" >&2
      exit 1
      ;;
  esac

  if ! [[ "$LIMIT" =~ ^[0-9]+$ ]]; then
    echo "--limit must be a non-negative integer" >&2
    exit 1
  fi
}

select_latest_image() {
  awk '
    NF {
      image=$0
      sub(/@.*/, "", image)
      tag=image
      sub(/.*:/, "", tag)
      print tag "\t" $0
    }
  ' | sort -k1,1V | tail -n 1 | cut -f2-
}

resolve_target_image() {
  TARGET_IMAGE="$(
    kubectl -n "$NAMESPACE" get volumes.longhorn.io \
      -o jsonpath='{range .items[*]}{.status.currentImage}{"\n"}{end}' \
    | sed '/^$/d' \
    | sort -u \
    | select_latest_image
  )"

  if [[ -n "$TARGET_IMAGE" ]]; then
    log "Resolved target engine image from running volumes: $TARGET_IMAGE"
    return 0
  fi

  TARGET_IMAGE="$(
    kubectl -n "$NAMESPACE" get volumes.longhorn.io \
      -o jsonpath='{range .items[*]}{.spec.image}{"\n"}{end}' \
    | sed '/^$/d' \
    | sort -u \
    | select_latest_image
  )"

  if [[ -n "$TARGET_IMAGE" ]]; then
    log "Resolved target engine image from volume spec.image: $TARGET_IMAGE"
    return 0
  fi

  TARGET_IMAGE="$(
    kubectl -n "$NAMESPACE" get engineimages.longhorn.io \
      -o jsonpath='{range .items[*]}{.spec.image}{"\t"}{.status.state}{"\n"}{end}' \
    | awk '$2=="deployed" {print $1}' \
    | sort -u \
    | select_latest_image
  )"

  if [[ -n "$TARGET_IMAGE" ]]; then
    log "Resolved target engine image from deployed engine images: $TARGET_IMAGE"
    return 0
  fi

  echo "Unable to determine target engine image automatically" >&2
  exit 1
}

show_engineimages() {
  log "Engine images:"
  kubectl -n "$NAMESPACE" get engineimages.longhorn.io
}

show_volume_counts() {
  log "Volume counts by desired image (spec.image):"
  kubectl -n "$NAMESPACE" get volumes.longhorn.io \
    -o jsonpath='{range .items[*]}{.spec.image}{"\n"}{end}' \
  | sed '/^$/d' | sort | uniq -c

  log "Volume counts by current image (status.currentImage):"
  kubectl -n "$NAMESPACE" get volumes.longhorn.io \
    -o jsonpath='{range .items[*]}{.status.currentImage}{"\n"}{end}' \
  | sed '/^$/d' | sort | uniq -c

  local pending
  pending="$(
    kubectl -n "$NAMESPACE" get volumes.longhorn.io \
      -o jsonpath='{range .items[*]}{.spec.image}{"\t"}{.status.currentImage}{"\n"}{end}' \
    | awk '$1 != "" && $1 != $2 {count++} END {print count+0}'
  )"
  log "Volumes pending engine switch (spec != current): $pending"
}

ensure_target_engine_deployed() {
  local found
  found="$(
    kubectl -n "$NAMESPACE" get engineimages.longhorn.io \
      -o jsonpath='{range .items[*]}{.spec.image}{"\t"}{.status.state}{"\n"}{end}' \
    | awk -v t="$TARGET_IMAGE" '$1==t && $2=="deployed" {print $0}'
  )"
  if [[ -z "$found" ]]; then
    echo "Target engine image is not deployed in $NAMESPACE: $TARGET_IMAGE" >&2
    echo "Current engine images:" >&2
    kubectl -n "$NAMESPACE" get engineimages.longhorn.io >&2
    exit 1
  fi
}

set_default_engine_image() {
  local current
  current="$(
    kubectl -n "$NAMESPACE" get settings.longhorn.io default-engine-image \
      -o jsonpath='{.value}' 2>/dev/null || true
  )"

  if [[ "$current" == "$TARGET_IMAGE" ]]; then
    log "default-engine-image is already $TARGET_IMAGE"
    return 0
  fi

  log "Setting default-engine-image to $TARGET_IMAGE"
  if kubectl -n "$NAMESPACE" patch settings.longhorn.io default-engine-image \
      --type='json' \
      -p="[{\"op\":\"replace\",\"path\":\"/value\",\"value\":\"$TARGET_IMAGE\"}]" >/dev/null 2>&1; then
    return 0
  fi

  log "Warning: failed to patch default-engine-image; continuing volume migration"
}

upgrade_by_state() {
  local state="$1"
  local vols
  vols="$(
    kubectl -n "$NAMESPACE" get volumes.longhorn.io \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.state}{"\t"}{.spec.image}{"\n"}{end}' \
    | awk -v s="$state" -v t="$TARGET_IMAGE" '$2==s && $3!=t {print $1}'
  )"

  if [[ -z "$vols" ]]; then
    log "No $state volumes require upgrade"
    return 0
  fi

  if [[ "$state" == "attached" ]]; then
    confirm_or_exit "About to patch attached volumes to $TARGET_IMAGE"
  fi

  local count=0
  while IFS= read -r vol; do
    [[ -z "$vol" ]] && continue
    if [[ "$LIMIT" -gt 0 && "$count" -ge "$LIMIT" ]]; then
      break
    fi
    kubectl -n "$NAMESPACE" patch "volumes.longhorn.io/$vol" \
      --type=merge -p "{\"spec\":{\"image\":\"$TARGET_IMAGE\"}}" >/dev/null
    count=$((count + 1))
  done <<< "$vols"
  if [[ "$LIMIT" -gt 0 ]]; then
    log "Patched $count $state volumes (limit=$LIMIT)"
  else
    log "Patched $count $state volumes"
  fi
}

wait_for_convergence() {
  log "Waiting for all volumes to converge to $TARGET_IMAGE"
  while true; do
    local remaining
    remaining="$(
      kubectl -n "$NAMESPACE" get volumes.longhorn.io \
        -o jsonpath='{range .items[*]}{.spec.image}{"\t"}{.status.currentImage}{"\n"}{end}' \
      | awk -v t="$TARGET_IMAGE" '$1 != t || $2 != t {count++} END {print count+0}'
    )"
    if [[ "$remaining" -eq 0 ]]; then
      break
    fi
    log "Volumes not yet converged to target image: $remaining"
    sleep 10
  done
  log "All volumes now target $TARGET_IMAGE"
}

cleanup_unused_engineimages() {
  local candidates
  candidates="$(
    kubectl -n "$NAMESPACE" get engineimages.longhorn.io \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.image}{"\t"}{.status.refCount}{"\n"}{end}' \
    | awk -v t="$TARGET_IMAGE" '$2!=t && $3=="0" {print $1}'
  )"

  if [[ -z "$candidates" ]]; then
    log "No unused non-target engine images to delete"
    return 0
  fi

  confirm_or_exit "Delete unused non-target engine images with refcount=0?"
  while IFS= read -r ei; do
    [[ -z "$ei" ]] && continue
    kubectl -n "$NAMESPACE" delete "engineimages.longhorn.io/$ei" >/dev/null
    log "Deleted $ei"
  done <<< "$candidates"
}

main() {
  require_cmd kubectl
  require_cmd awk
  require_cmd cut
  require_cmd sort
  require_cmd uniq
  require_cmd sed
  require_cmd tail
  require_cmd date

  parse_args "$@"
  resolve_target_image
  ensure_target_engine_deployed

  # Pure report mode should print a single snapshot.
  if [[ "$MODE" == "report" ]]; then
    show_engineimages
    show_volume_counts
    return 0
  fi

  log "Pre-run snapshot"
  show_engineimages
  show_volume_counts

  case "$MODE" in
    report)
      ;;
    detached)
      set_default_engine_image
      upgrade_by_state detached
      ;;
    attached)
      set_default_engine_image
      upgrade_by_state attached
      ;;
    all)
      set_default_engine_image
      upgrade_by_state detached
      upgrade_by_state attached
      ;;
  esac

  wait_for_convergence
  cleanup_unused_engineimages

  log "Post-run snapshot"
  show_volume_counts
}

main "$@"
