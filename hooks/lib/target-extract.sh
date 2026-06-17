#!/bin/bash
# V17 Phase 1 — Target Extraction Library
#
# Shared parser used by every infra-aware PreToolUse hook so "what target
# does this command touch" is computed identically in:
#   - verify-infra-target.sh (Phase 3, target-aware gate)
#   - block-destructive.sh   (Phase 4, shared-service-yank category)
#   - require-rag-pretooluse.sh (Phase 6, semantic RAG check)
#
# Single source of truth: a regex bug or new pattern is fixed once here.
#
# Usage:
#     source "$(dirname "$0")/lib/target-extract.sh"
#     extract_targets "$cmd" | sort -u
#
# Emits TYPE:VALUE lines on stdout. One per discovered target. Caller is
# expected to `sort -u` if dedup matters. Empty stdin / unrecognized
# shapes emit nothing (and exit 0); the caller's policy decides what
# "nothing extracted" means.
#
# Types emitted:
#   helm_release    helm install/upgrade/rollback/uninstall release name
#   k8s_namespace   -n / --namespace argument
#   k8s_resource    kind/name pair for k8s verbs (kubectl/oc)
#   k8s_context     --context arg, or implied by oc-atlantis / oc-pantheon
#   docker_compose  -f path for docker compose / docker-compose
#   systemd_unit    unit name for systemctl
#   ssh_host        host or user@host for ssh
#   atlas_role      role name when atlas is run with a single role arg
#   atlas_play      playbook path when atlas-play is invoked
#   ansible_play    playbook path for ansible-playbook
#
# Implementation note: parses by splitting the command on whitespace
# (after collapsing runs of whitespace). Quoted-string handling is
# intentionally minimal -- if you pass `helm upgrade "my release"` the
# release will be extracted with the quotes; callers should pre-clean
# if that matters. Multi-command pipelines (`a && b`, `a; b`, `a | b`)
# are split and each segment processed independently.

# Strip a leading sudo (with optional flags) from $1 in place.
_te_strip_sudo() {
    local s="$1"
    s="${s##sudo +([A-Z]=+([!\ ]) )}"
    s="${s##sudo -+([!\ ]) }"
    s="${s##sudo }"
    printf '%s' "$s"
}

# Resolve any leading alias to a canonical command + implied context.
# Sets _TE_CMD and _TE_CONTEXT as out-parameters; do NOT call via $() since
# command substitution opens a subshell and the side-effect on _TE_CONTEXT
# would be lost in the parent.
_te_resolve_alias() {
    local first="$1"
    _TE_CONTEXT=""
    case "$first" in
        oc-atlantis|kubectl-atlantis)   _TE_CMD="oc"; _TE_CONTEXT="atlantis" ;;
        oc-pantheon|kubectl-pantheon)   _TE_CMD="oc"; _TE_CONTEXT="pantheon" ;;
        *)                              _TE_CMD="$first" ;;
    esac
}

# Match a -n / --namespace argument anywhere in $@; echo the value or nothing.
_te_grab_namespace() {
    local prev=""
    for tok in "$@"; do
        if [[ "$prev" == "-n" || "$prev" == "--namespace" ]]; then
            printf '%s' "$tok"; return 0
        fi
        if [[ "$tok" == --namespace=* ]]; then
            printf '%s' "${tok#--namespace=}"; return 0
        fi
        prev="$tok"
    done
}

# Match a --context argument; echo the value or nothing.
_te_grab_context() {
    local prev=""
    for tok in "$@"; do
        if [[ "$prev" == "--context" ]]; then
            printf '%s' "$tok"; return 0
        fi
        if [[ "$tok" == --context=* ]]; then
            printf '%s' "${tok#--context=}"; return 0
        fi
        prev="$tok"
    done
}

# Match -f / --file (docker compose, ansible) anywhere; echo value or nothing.
_te_grab_file() {
    local prev=""
    for tok in "$@"; do
        if [[ "$prev" == "-f" || "$prev" == "--file" ]]; then
            printf '%s' "$tok"; return 0
        fi
        if [[ "$tok" == --file=* ]]; then
            printf '%s' "${tok#--file=}"; return 0
        fi
        prev="$tok"
    done
}

# Process a single command segment (no &&/;/| splits).
_te_process_segment() {
    local raw="$1"
    raw="${raw## }"; raw="${raw%% }"
    [[ -z "$raw" ]] && return 0

    # Strip leading sudo
    raw="$(_te_strip_sudo "$raw")"

    # Split into argv. Word-splitting on whitespace; no quote handling.
    # shellcheck disable=SC2206
    local -a argv=( $raw )
    [[ ${#argv[@]} -eq 0 ]] && return 0

    _te_resolve_alias "${argv[0]}"
    local cmd="$_TE_CMD"
    local ctx="$_TE_CONTEXT"

    case "$cmd" in
        helm)
            # helm <verb> <release> [chart] [-n <ns>] ...
            local verb="${argv[1]:-}" release="${argv[2]:-}"
            case "$verb" in
                install|upgrade|uninstall|delete|rollback)
                    [[ -n "$release" && "$release" != -* ]] && \
                        printf 'helm_release:%s\n' "$release"
                    local ns
                    ns="$(_te_grab_namespace "${argv[@]:2}")"
                    [[ -n "$ns" ]] && printf 'k8s_namespace:%s\n' "$ns"
                    local kctx
                    kctx="$(_te_grab_context "${argv[@]:2}")"
                    [[ -n "$kctx" ]] && printf 'k8s_context:%s\n' "$kctx"
                    [[ -z "$kctx" && -n "$ctx" ]] && printf 'k8s_context:%s\n' "$ctx"
                    ;;
            esac
            ;;
        kubectl|oc)
            # <cmd> <verb> [<sub>] [<kind> <name> | <kind>/<name>] [-n <ns>] [--context <ctx>] ...
            local verb="${argv[1]:-}"
            local arg2="${argv[2]:-}"
            local arg3="${argv[3]:-}"
            # rollout has a subcommand at arg2 and the resource at arg3:
            #   oc rollout restart sts/dragonfly
            # Shift one position so the resource detection below sees the
            # right tokens.
            if [[ "$verb" == "rollout" ]]; then
                arg2="${argv[3]:-}"
                arg3="${argv[4]:-}"
            fi

            # k8s_resource extraction
            if [[ "$arg2" == */* && "$arg2" != -* ]]; then
                printf 'k8s_resource:%s\n' "$arg2"
            elif [[ -n "$arg2" && "$arg2" != -* && -n "$arg3" && "$arg3" != -* ]]; then
                # kubectl <verb> <kind> <name>
                case "$verb" in
                    get|describe|delete|edit|patch|scale|annotate|label|exec|logs|port-forward|cp|rollout|drain|cordon|uncordon|apply|create|replace)
                        printf 'k8s_resource:%s/%s\n' "$arg2" "$arg3"
                        ;;
                esac
            fi

            local ns
            ns="$(_te_grab_namespace "${argv[@]:1}")"
            [[ -n "$ns" ]] && printf 'k8s_namespace:%s\n' "$ns"

            local kctx
            kctx="$(_te_grab_context "${argv[@]:1}")"
            [[ -n "$kctx" ]] && printf 'k8s_context:%s\n' "$kctx"
            [[ -z "$kctx" && -n "$ctx" ]] && printf 'k8s_context:%s\n' "$ctx"
            ;;
        docker)
            # docker compose -f <file> <verb>
            if [[ "${argv[1]:-}" == "compose" ]]; then
                local f
                f="$(_te_grab_file "${argv[@]:2}")"
                [[ -n "$f" ]] && printf 'docker_compose:%s\n' "$f"
            fi
            ;;
        docker-compose)
            local f
            f="$(_te_grab_file "${argv[@]:1}")"
            [[ -n "$f" ]] && printf 'docker_compose:%s\n' "$f"
            ;;
        systemctl)
            # systemctl [--user|--system] <verb> <unit> [<unit>...]
            local i=1 verb="" unit=""
            for ((i=1; i<${#argv[@]}; i++)); do
                tok="${argv[i]}"
                case "$tok" in
                    --user|--system|--no-block|--no-pager|--quiet|-q) continue ;;
                    -*) continue ;;
                    *)
                        if [[ -z "$verb" ]]; then verb="$tok"
                        else
                            printf 'systemd_unit:%s\n' "$tok"
                        fi
                        ;;
                esac
            done
            ;;
        ssh)
            # ssh [opts] <host>  or  ssh [opts] <user>@<host>
            # Skip -o KEY=VAL pairs and other flag args.
            local i=1 host="" prev=""
            for ((i=1; i<${#argv[@]}; i++)); do
                tok="${argv[i]}"
                if [[ "$prev" == -o || "$prev" == -i || "$prev" == -F || "$prev" == -p || "$prev" == -l ]]; then
                    prev=""; continue
                fi
                case "$tok" in
                    -o|-i|-F|-p|-l) prev="$tok"; continue ;;
                    -*) prev=""; continue ;;
                    *) host="$tok"; break ;;
                esac
            done
            [[ -n "$host" ]] && printf 'ssh_host:%s\n' "$host"
            ;;
        atlas)
            # atlas <role-or-play>  -- conservatively emit as atlas_role
            local arg="${argv[1]:-}"
            [[ -n "$arg" && "$arg" != -* ]] && printf 'atlas_role:%s\n' "$arg"
            ;;
        atlas-play|atlas_play)
            local arg="${argv[1]:-}"
            [[ -n "$arg" && "$arg" != -* ]] && printf 'atlas_play:%s\n' "$arg"
            ;;
        ansible-playbook)
            # ansible-playbook [opts] <path>  -- skip flags AND their values
            # for -i / --inventory / -e / --extra-vars / -t / --tags etc.
            local i=1 prev=""
            for ((i=1; i<${#argv[@]}; i++)); do
                tok="${argv[i]}"
                # If the previous token is a value-taking flag, skip this one.
                case "$prev" in
                    -i|--inventory|-e|--extra-vars|-t|--tags|--skip-tags|-l|--limit|--vault-password-file|--vault-id|-u|--user|-c|--connection|-T|--timeout|-K|--ask-become-pass)
                        prev=""; continue ;;
                esac
                case "$tok" in
                    *=*) prev=""; continue ;;
                    -*)  prev="$tok"; continue ;;
                    *)   printf 'ansible_play:%s\n' "$tok"; break ;;
                esac
            done
            ;;
        rm|touch|truncate)
            # Mutating commands that take a list of paths. Skip all flags
            # (including the value-taking -t / --target-directory of touch).
            local i=1 prev=""
            for ((i=1; i<${#argv[@]}; i++)); do
                tok="${argv[i]}"
                case "$prev" in
                    -t|--target-directory|-d|--date|-r|--reference|-s|--size)
                        prev=""; continue ;;
                esac
                case "$tok" in
                    -*) prev="$tok"; continue ;;
                    *)  printf 'file_path:%s\n' "$tok" ;;
                esac
                prev=""
            done
            ;;
        mv|cp|ln)
            # `mv [opts] SRC... DST` and `cp [opts] SRC... DST` — emit
            # every non-flag arg as a file_path. We don't try to separate
            # source vs destination; for V17's "what does this touch" the
            # union is what matters.
            local i=1 prev=""
            for ((i=1; i<${#argv[@]}; i++)); do
                tok="${argv[i]}"
                case "$prev" in
                    -t|--target-directory|-S|--suffix|-Z|--context|--backup)
                        prev=""; continue ;;
                esac
                case "$tok" in
                    -*) prev="$tok"; continue ;;
                    *)  printf 'file_path:%s\n' "$tok" ;;
                esac
                prev=""
            done
            ;;
        chmod|chown|chgrp)
            # First non-flag is the mode/owner/group; remaining non-flag
            # args are file paths.
            local i=1 saw_spec="" prev=""
            for ((i=1; i<${#argv[@]}; i++)); do
                tok="${argv[i]}"
                case "$prev" in
                    --reference) prev=""; continue ;;
                esac
                case "$tok" in
                    -*) prev="$tok"; continue ;;
                    *)
                        if [[ -z "$saw_spec" ]]; then
                            saw_spec=1
                        else
                            printf 'file_path:%s\n' "$tok"
                        fi
                        ;;
                esac
                prev=""
            done
            ;;
        tee)
            # tee [-a] file...
            local i=1
            for ((i=1; i<${#argv[@]}; i++)); do
                tok="${argv[i]}"
                case "$tok" in
                    -*) continue ;;
                    *)  printf 'file_path:%s\n' "$tok" ;;
                esac
            done
            ;;
        sed)
            # Only `sed -i` mutates files; otherwise sed is read-only.
            # Look for -i or -i<EXT> (in-place edit). When present,
            # subsequent non-flag args after the script are file paths.
            local has_inplace="" i=1 prev="" saw_script=""
            for tok in "${argv[@]:1}"; do
                case "$tok" in
                    -i|-i*) has_inplace=1 ;;
                esac
            done
            [[ -z "$has_inplace" ]] && return 0
            for ((i=1; i<${#argv[@]}; i++)); do
                tok="${argv[i]}"
                case "$prev" in
                    -e|--expression|-f|--file)
                        # The value of -e/-f IS the script; counts as the
                        # one bareword sed expects before file args.
                        saw_script=1
                        prev=""; continue ;;
                esac
                case "$tok" in
                    -*) prev="$tok"; continue ;;
                    *)
                        if [[ -z "$saw_script" ]]; then
                            saw_script=1
                        else
                            printf 'file_path:%s\n' "$tok"
                        fi
                        ;;
                esac
                prev=""
            done
            ;;
    esac
}

# Public entry point: split on shell connectors and process each segment.
extract_targets() {
    local cmd="$1"
    [[ -z "$cmd" ]] && return 0

    # Collapse whitespace, then split on shell connectors.
    cmd="${cmd//$'\n'/ }"
    cmd="${cmd//$'\t'/ }"
    # Replace each connector with a real newline so we can iterate
    # without changing IFS (changing IFS in this function would leak
    # into _te_process_segment via bash's dynamic-scope `local`).
    cmd="${cmd//&&/$'\n'}"
    cmd="${cmd//;/$'\n'}"
    cmd="${cmd//|/$'\n'}"

    local segment
    while IFS= read -r segment; do
        _te_process_segment "$segment"
    done <<<"$cmd"
}
