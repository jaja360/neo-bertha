#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="longhorn-system"
TARGET_IMAGE=""
MODE="report"
ASSUME_YES="false"
LIMIT="1"
WAIT_TIMEOUT="1800"
PATCH_COUNT=0
WATCHED_VOLUMES=()
WATCHED_ATTACHED=()

usage() {
  cat <<'EOF'
Migrate Longhorn V1 volumes to a single engine image.

Usage:
  scripts/longhorn-engine-migrate.sh [options]

Options:
  --namespace NS                 Default: longhorn-system
  --mode MODE                    One of: report, detached, attached, all (default: report)
  --target-image IMAGE           Explicit target image (otherwise default-engine-image is used)
  --wait-timeout SECONDS         Wait timeout (0 = indefinitely, default: 1800)
  --limit N                      Safe batch size/max patches in ONE invocation (default: 1)
                                 --limit 0 starts all eligible selected volumes concurrently.
  --yes                          Skip the attached upgrade confirmation
  -h, --help                     Show this help
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }
}

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

confirm_or_exit() {
  local prompt="$1" ans
  [[ "$ASSUME_YES" == "true" ]] && return 0
  read -r -p "$prompt [y/N]: " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || { log "Confirmation refused; no volumes were changed"; exit 1; }
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --namespace|--mode|--limit|--target-image|--wait-timeout)
        if [[ $# -lt 2 || "$2" == --* ]]; then
          echo "$1 requires a value" >&2
          exit 1
        fi
        case "$1" in
          --namespace) NAMESPACE="$2" ;;
          --mode) MODE="$2" ;;
          --limit) LIMIT="$2" ;;
          --target-image) TARGET_IMAGE="$2" ;;
          --wait-timeout) WAIT_TIMEOUT="$2" ;;
        esac
        shift 2
        ;;
      --yes) ASSUME_YES="true"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
  done
  case "$MODE" in report|detached|attached|all) ;; *) echo "Invalid --mode: $MODE" >&2; exit 1 ;; esac
  [[ "$LIMIT" =~ ^[0-9]+$ ]] || { echo "--limit must be a non-negative integer" >&2; exit 1; }
  [[ "$WAIT_TIMEOUT" =~ ^[0-9]+$ ]] || { echo "--wait-timeout must be a non-negative integer" >&2; exit 1; }
}

resolve_target_image() {
  if [[ -n "$TARGET_IMAGE" ]]; then
    log "Using explicitly requested target engine image: $TARGET_IMAGE"
    return 0
  fi
  local default_image
  if ! default_image="$(kubectl -n "$NAMESPACE" get settings.longhorn.io default-engine-image -o jsonpath='{.value}' 2>/dev/null)"; then
    echo "Unable to read default-engine-image; deploy/set the target image or pass --target-image" >&2
    exit 1
  fi
  if [[ -z "$default_image" ]]; then
    echo "default-engine-image is empty; deploy/set the target image or pass --target-image" >&2
    exit 1
  fi
  if ! kubectl -n "$NAMESPACE" get engineimages.longhorn.io -o jsonpath='{range .items[*]}{.spec.image}|{.status.state}{"\n"}{end}' \
      | awk -F'|' -v t="$default_image" '$1==t && $2=="deployed" {found=1} END {exit !found}'; then
    echo "default-engine-image is not deployed: $default_image; deploy/set the target image or pass --target-image" >&2
    exit 1
  fi
  TARGET_IMAGE="$default_image"
  log "Resolved target engine image from deployed default-engine-image: $TARGET_IMAGE"
}

ensure_target_engine_deployed() {
  if ! kubectl -n "$NAMESPACE" get engineimages.longhorn.io -o jsonpath='{range .items[*]}{.spec.image}|{.status.state}{"\n"}{end}' \
      | awk -F'|' -v t="$TARGET_IMAGE" '$1==t && $2=="deployed" {found=1} END {exit !found}'; then
    echo "Target engine image is not deployed in $NAMESPACE: $TARGET_IMAGE" >&2
    echo "Deploy the target EngineImage or pass a deployed image with --target-image" >&2
    exit 1
  fi
}

ensure_manual_upgrade_is_safe() {
  local value
  if ! value="$(kubectl -n "$NAMESPACE" get settings.longhorn.io concurrent-automatic-engine-upgrade-per-node-limit -o jsonpath='{.value}' 2>/dev/null)"; then
    echo "Cannot read concurrent-automatic-engine-upgrade-per-node-limit; manual migration requires this setting to be exactly 0" >&2
    exit 1
  fi
  if [[ "$value" != "0" ]]; then
    echo "Refusing manual migration: concurrent-automatic-engine-upgrade-per-node-limit is '$value', not 0" >&2
    echo "Set it to exactly 0 before proceeding with manual migration" >&2
    exit 1
  fi
}

show_engineimages() { log "Engine images:"; kubectl -n "$NAMESPACE" get engineimages.longhorn.io; }

show_volume_counts() {
  local data
  data="$(kubectl -n "$NAMESPACE" get volumes.longhorn.io -o jsonpath='{range .items[*]}{.metadata.name}|{.status.state}|{.status.robustness}|{.spec.dataEngine}|{.status.currentMigrationNodeID}|{.spec.migrationNodeID}|{.spec.Standby}|{.status.isStandby}|{.status.restoreRequired}|{.status.expansionRequired}|{.spec.frontend}|{.spec.dataLocality}|{.spec.image}|{.status.currentImage}{"\n"}{end}')"
  printf '%s\n' "$data" | awk -F'|' '
    NF { if ($4=="v2") v2++; else v1++; if ($2=="attached" && $4!="v2" && ($3=="faulted" || $5!="" || $6!="" || $7=="true" || $8=="true" || $9=="true" || $10=="true" || tolower($11) ~ /iscsi/ || $12=="strict-local" || $3!="healthy") ) { bad++; if (list!="") list=list ", "; list=list $1 } }
    END { print "Volume engine versions: V1=" v1+0 " V2=" v2+0; print "Attached V1 volumes unsuitable for live migration: " bad+0; if (bad) print "Unsuitable attached V1 volumes: " list }
  '
  log "Volume counts by engine image:"
  printf '%s\n' "$data" | awk -F'|' '
    $13 != "" { if (!seen[$13]++) image[++count] = $13; desired[$13]++ }
    $14 != "" { if (!seen[$14]++) image[++count] = $14; current[$14]++ }
    END {
      printf "  %-55s %8s %8s\n", "IMAGE", "DESIRED", "CURRENT"
      for (i = 1; i <= count; i++) {
        name = image[i]
        printf "  %-55s %8d %8d\n", name, desired[name] + 0, current[name] + 0
      }
    }
  '
  printf '%s\n' "$data" | awk -F'|' '$13!="" && $13!=$14 {n++} END {print "Volumes pending engine switch (spec != current): " n+0}'
}

reset_watch() { WATCHED_VOLUMES=(); WATCHED_ATTACHED=(); }
watch_volume() {
  local volume="$1" attached="$2" watched
  for watched in "${WATCHED_VOLUMES[@]}"; do
    [[ "$watched" == "$volume" ]] && return 0
  done
  WATCHED_VOLUMES+=("$volume"); WATCHED_ATTACHED+=("$attached")
}

# Sets FRESH_* and returns 0 for eligible, 1 for an informative skip.
fresh_precheck() {
  local name="$1" requested="$2" record
  if ! record="$(kubectl -n "$NAMESPACE" get "volumes.longhorn.io/$name" -o jsonpath='{.metadata.name}|{.metadata.resourceVersion}|{.status.state}|{.spec.image}|{.spec.dataEngine}|{.status.robustness}|{.status.currentMigrationNodeID}|{.spec.migrationNodeID}|{.spec.Standby}|{.status.isStandby}|{.status.restoreRequired}|{.status.expansionRequired}|{.spec.frontend}|{.spec.dataLocality}|{.status.currentImage}')"; then
    echo "Failed to freshly read Volume $name before patch" >&2; return 2
  fi
  IFS='|' read -r FRESH_NAME FRESH_RESOURCE_VERSION FRESH_STATE FRESH_IMAGE FRESH_ENGINE FRESH_ROBUST FRESH_STATUS_MIG FRESH_SPEC_MIG FRESH_SPEC_STANDBY FRESH_STATUS_STANDBY FRESH_RESTORE FRESH_EXPANDING FRESH_FRONTEND FRESH_LOCALITY FRESH_CURRENT <<< "$record"
  [[ "$FRESH_STATE" == "$requested" ]] || return 1
  [[ "$FRESH_ENGINE" == "v2" ]] && { log "Skipping $name: V2 data engine" >&2; return 1; }
  [[ "$FRESH_ROBUST" == "faulted" ]] && { log "Skipping $name: robustness is faulted" >&2; return 1; }
  [[ -n "$FRESH_STATUS_MIG$FRESH_SPEC_MIG" ]] && { log "Skipping $name: migration-node field is nonempty" >&2; return 1; }
  [[ "$FRESH_SPEC_STANDBY" == "true" || "$FRESH_STATUS_STANDBY" == "true" ]] && { log "Skipping $name: Standby/standby status is true" >&2; return 1; }
  [[ "$FRESH_RESTORE" == "true" ]] && { log "Skipping $name: status.restoreRequired is true" >&2; return 1; }
  [[ "$FRESH_EXPANDING" == "true" ]] && { log "Skipping $name: status.expansionRequired is true" >&2; return 1; }
  if [[ "$requested" == attached ]]; then
    [[ "$FRESH_ROBUST" == healthy ]] || { log "Skipping $name: attached robustness is $FRESH_ROBUST, not healthy" >&2; return 1; }
    [[ "${FRESH_FRONTEND,,}" != *iscsi* ]] || { log "Skipping $name: iSCSI frontend ($FRESH_FRONTEND)" >&2; return 1; }
    [[ "$FRESH_LOCALITY" != strict-local ]] || { log "Skipping $name: dataLocality is strict-local" >&2; return 1; }
  fi
  return 0
}

recheck_patch_outcome() {
  local name="$1" attached="$2" record spec current
  if ! record="$(kubectl -n "$NAMESPACE" get "volumes.longhorn.io/$name" -o jsonpath='{.spec.image}|{.status.currentImage}')"; then
    echo "Failed to re-read Volume $name after a patch error; patch outcome is unknown" >&2
    return 2
  fi
  IFS='|' read -r spec current <<< "$record"
  if [[ "$spec" == "$TARGET_IMAGE" && "$current" == "$TARGET_IMAGE" ]]; then
    log "Volume $name converged despite the patch error"
    return 0
  fi
  if [[ "$spec" == "$TARGET_IMAGE" && "$current" != "$TARGET_IMAGE" ]]; then
    log "Volume $name has the target desired image after a patch race; watching convergence"
    watch_volume "$name" "$attached"
    return 1
  fi
  echo "Patch outcome for Volume $name is not safely recoverable (desired image is '$spec', current image is '$current')" >&2
  return 2
}

upgrade_by_state() {
  local requested="$1" name count=0 names patch_payload attached outcome
  reset_watch
  if ! names="$(kubectl -n "$NAMESPACE" get volumes.longhorn.io -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')"; then
    echo "Failed to list Longhorn volumes for the $requested phase" >&2
    return 1
  fi
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    fresh_precheck "$name" "$requested" || { [[ $? -eq 2 ]] && return 1; continue; }
    if [[ "$FRESH_IMAGE" == "$TARGET_IMAGE" ]]; then
      [[ "$FRESH_CURRENT" != "$TARGET_IMAGE" ]] && watch_volume "$name" "$([[ "$requested" == attached ]] && echo true || echo false)"
      continue
    fi
    if [[ "$LIMIT" -gt 0 && "$PATCH_COUNT" -ge "$LIMIT" ]]; then continue; fi
    attached="$([[ "$requested" == attached ]] && echo true || echo false)"
    printf -v patch_payload '[{"op":"test","path":"/metadata/resourceVersion","value":"%s"},{"op":"test","path":"/status/state","value":"%s"},{"op":"test","path":"/spec/image","value":"%s"},{"op":"replace","path":"/spec/image","value":"%s"}]' "$FRESH_RESOURCE_VERSION" "$requested" "$FRESH_IMAGE" "$TARGET_IMAGE"
    if ! kubectl -n "$NAMESPACE" patch "volumes.longhorn.io/$name" --type=json -p "$patch_payload" >/dev/null; then
      if recheck_patch_outcome "$name" "$attached"; then outcome=0; else outcome=$?; fi
      if [[ "$outcome" -eq 0 || "$outcome" -eq 1 ]]; then
        PATCH_COUNT=$((PATCH_COUNT + 1))
        continue
      fi
      return 1
    fi
    PATCH_COUNT=$((PATCH_COUNT + 1)); count=$((count + 1)); watch_volume "$name" "$([[ "$requested" == attached ]] && echo true || echo false)"
  done <<< "$names"
  log "${requested^} phase: patched $count volume(s); watching ${#WATCHED_VOLUMES[@]} volume(s) (invocation patches=$PATCH_COUNT)"
}

wait_for_convergence() {
  [[ "${#WATCHED_VOLUMES[@]}" -eq 0 ]] && { log "No patched or target-pending volumes in this phase; nothing to wait for"; return 0; }
  local started elapsed vol record remaining
  started=$(date +%s)
  while true; do
    remaining=0
    for ((i=0; i<${#WATCHED_VOLUMES[@]}; i++)); do
      vol="${WATCHED_VOLUMES[$i]}"
      if ! record="$(kubectl -n "$NAMESPACE" get "volumes.longhorn.io/$vol" -o jsonpath='{.spec.image}|{.status.currentImage}|{.status.state}|{.status.robustness}')"; then
        echo "Failed to read watched Volume $vol while waiting for convergence" >&2; return 1
      fi
      IFS='|' read -r spec current state robustness <<< "$record"
      [[ "$robustness" == faulted ]] && { echo "Volume $vol became faulted; inspect Longhorn events/UI" >&2; return 1; }
      if [[ "${WATCHED_ATTACHED[$i]}" == true ]]; then
        [[ "$state" == attached && "$robustness" == healthy ]] || {
          echo "Attached-origin Volume $vol did not remain attached and healthy (state=$state, robustness=$robustness)" >&2
          return 1
        }
      else
        case "$state" in
          attached|attaching|detaching|deleting)
            echo "Detached-origin Volume $vol became $state before convergence" >&2
            return 1
            ;;
          detached) ;;
          *)
            echo "Detached-origin Volume $vol has unexpected state $state before convergence" >&2
            return 1
            ;;
        esac
      fi
      if [[ "$spec" != "$TARGET_IMAGE" || "$current" != "$TARGET_IMAGE" ]]; then remaining=$((remaining + 1)); fi
    done
    [[ "$remaining" -eq 0 ]] && { log "Watched volumes converged successfully to $TARGET_IMAGE"; return 0; }
    if [[ "$WAIT_TIMEOUT" -gt 0 ]]; then
      elapsed=$(( $(date +%s) - started ))
      if [[ "$elapsed" -ge "$WAIT_TIMEOUT" ]]; then
        echo "Timed out after ${WAIT_TIMEOUT}s waiting for watched volumes to converge" >&2
        return 1
      fi
    fi
    log "Watched volumes not yet converged: $remaining"; sleep 10
  done
}

main() {
  require_cmd kubectl; require_cmd awk; require_cmd date
  parse_args "$@"; resolve_target_image; ensure_target_engine_deployed
  [[ "$MODE" == report ]] && { show_engineimages; show_volume_counts; return 0; }
  ensure_manual_upgrade_is_safe
  show_engineimages; show_volume_counts
  if [[ "$MODE" == attached || "$MODE" == all ]]; then
    confirm_or_exit "Eligible attached V1 volumes may be patched to $TARGET_IMAGE. Continue?"
  fi
  case "$MODE" in
    detached) upgrade_by_state detached; wait_for_convergence ;;
    attached) upgrade_by_state attached; wait_for_convergence ;;
    all) upgrade_by_state detached; wait_for_convergence; upgrade_by_state attached; wait_for_convergence ;;
  esac
  log "Migration completed; old EngineImages were deliberately left for Longhorn/native delayed cleanup and must not be deleted until separately verified full-cluster convergence."
  show_volume_counts
}

main "$@"
