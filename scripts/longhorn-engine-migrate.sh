#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="longhorn-system"
TARGET_IMAGE=""
MODE="report"
SET_DEFAULT="true"
WAIT_FOR_CONVERGENCE="false"
CLEANUP_UNUSED="false"
ASSUME_YES="false"
LIMIT="0"

usage() {
  cat <<'EOF'
Migrate Longhorn volumes to a single engine image.

Usage:
  scripts/longhorn-engine-migrate.sh --target IMAGE [options]

Required:
  --target IMAGE                 Example: docker.io/longhornio/longhorn-engine:v1.11.0

Options:
  --namespace NS                 Default: longhorn-system
  --mode MODE                    One of: report, detached, attached, all (default: report)
  --limit N                      Max volumes to patch per phase/run (0 = no limit, default: 0)
  --set-default true|false       Update Longhorn default-engine-image (default: true)
  --wait                         Wait until all volumes converge to target image
  --cleanup-unused               Delete old engineimages with refcount=0 (never deletes target image)
  --yes                          Skip confirmation prompts for attached upgrade and cleanup
  -h, --help                     Show this help

Recommended rollout:
  1) report
  2) detached
  3) attached (low-traffic window)
  4) report --wait
  5) cleanup-unused

Examples:
  scripts/longhorn-engine-migrate.sh --target docker.io/longhornio/longhorn-engine:v1.11.0 --mode report
  scripts/longhorn-engine-migrate.sh --target docker.io/longhornio/longhorn-engine:v1.11.0 --mode detached
  scripts/longhorn-engine-migrate.sh --target docker.io/longhornio/longhorn-engine:v1.11.0 --mode detached --limit 20
  scripts/longhorn-engine-migrate.sh --target docker.io/longhornio/longhorn-engine:v1.11.0 --mode attached --yes
  scripts/longhorn-engine-migrate.sh --target docker.io/longhornio/longhorn-engine:v1.11.0 --mode all --yes --wait --cleanup-unused
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
      --target)
        TARGET_IMAGE="$2"
        shift 2
        ;;
      --namespace)
        NAMESPACE="$2"
        shift 2
        ;;
      --mode)
        MODE="$2"
        shift 2
        ;;
      --set-default)
        SET_DEFAULT="$2"
        shift 2
        ;;
      --limit)
        LIMIT="$2"
        shift 2
        ;;
      --wait)
        WAIT_FOR_CONVERGENCE="true"
        shift
        ;;
      --cleanup-unused)
        CLEANUP_UNUSED="true"
        shift
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

  if [[ -z "$TARGET_IMAGE" ]]; then
    echo "--target is required" >&2
    usage
    exit 1
  fi

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
  if [[ "$SET_DEFAULT" != "true" ]]; then
    return 0
  fi

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
  if [[ "$WAIT_FOR_CONVERGENCE" != "true" ]]; then
    return 0
  fi

  log "Waiting for all volumes to converge to $TARGET_IMAGE"
  while true; do
    local remaining
    remaining="$(
      kubectl -n "$NAMESPACE" get volumes.longhorn.io \
        -o jsonpath='{range .items[*]}{.spec.image}{"\n"}{end}' \
      | awk -v t="$TARGET_IMAGE" '$0 != t && $0 != "" {count++} END {print count+0}'
    )"
    if [[ "$remaining" -eq 0 ]]; then
      break
    fi
    log "Volumes still on non-target image: $remaining"
    sleep 10
  done
  log "All volumes now target $TARGET_IMAGE"
}

cleanup_unused_engineimages() {
  if [[ "$CLEANUP_UNUSED" != "true" ]]; then
    return 0
  fi

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
  require_cmd sort
  require_cmd uniq
  require_cmd sed
  require_cmd date

  parse_args "$@"
  ensure_target_engine_deployed
  local ran_actions="false"

  # Pure report mode should print a single snapshot.
  if [[ "$MODE" == "report" && "$WAIT_FOR_CONVERGENCE" != "true" && "$CLEANUP_UNUSED" != "true" ]]; then
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
      ran_actions="true"
      ;;
    attached)
      set_default_engine_image
      upgrade_by_state attached
      ran_actions="true"
      ;;
    all)
      set_default_engine_image
      upgrade_by_state detached
      upgrade_by_state attached
      ran_actions="true"
      ;;
  esac

  wait_for_convergence
  cleanup_unused_engineimages

  if [[ "$ran_actions" == "true" || "$WAIT_FOR_CONVERGENCE" == "true" || "$CLEANUP_UNUSED" == "true" ]]; then
    log "Post-run snapshot"
  fi
  show_volume_counts
}

main "$@"
