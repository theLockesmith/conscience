#!/bin/bash
# ~/.claude/hooks/lib/prod-target-match.sh
#
# V17 Phase 2 manifest loader + matcher. Sourced by:
#   - verify-infra-target.sh    (Phase 3)
#   - block-destructive.sh      (Phase 4 shared-service-yank category)
#   - require-rag-pretooluse.sh (Phase 6 semantic upgrade)
#
# Public functions:
#   pt_load_manifest
#       Loads ~/.claude/security/prod-targets.yml into globals. Idempotent.
#       Sets PT_LOADED=1 on success; the caller can early-out otherwise.
#
#   pt_is_prod_target <TYPE:VALUE>
#       0 if the target matches anything in prod-targets.yml.
#       1 otherwise. TYPE values match what target-extract.sh emits:
#         helm_release | k8s_namespace | k8s_resource | k8s_context |
#         docker_compose | systemd_unit | ssh_host | atlas_role |
#         atlas_play | ansible_play | file_path
#
#   pt_is_yank_verb <tool> <verb>
#       0 if `verb` is in yank_verbs[tool] from the manifest. Used by
#       block-destructive shared-service-yank to gate categorization.
#       <tool> is one of: helm kubectl oc docker_compose systemctl atlas file
#
#   pt_glob_match <pattern> <value>
#       0 if value matches pattern. '*' = trailing wildcard (foo* matches
#       foobar). '*' alone matches anything. Otherwise exact match.
#
#   pt_audit_log <event-tag> <message...>
#       Append a single line to ~/.claude/security/audit.log with a
#       timestamp + tag + the rest of the args. Used for bypass logging
#       and block-event recording. Created fresh-perm 0600 on first write.

set -uo pipefail

PT_MANIFEST="${PT_MANIFEST:-$HOME/.claude/security/prod-targets.yml}"
PT_AUDIT_LOG="${PT_AUDIT_LOG:-$HOME/.claude/security/audit.log}"
PT_LOADED="${PT_LOADED:-0}"

# Caches populated by pt_load_manifest.
PT_HELM_RELEASES=""
PT_NAMESPACES_BY_CTX_DELIM=$'\x1f' # unit separator joins ctx and ns lines
PT_NAMESPACES_BY_CTX=""
PT_K8S_CONTEXTS=""
PT_SYSTEMD_UNITS=""
PT_DOCKER_LOCAL_DEV=""
PT_SSH_HOSTS=""
PT_ATLAS_ROLES_PROD=""
PT_ATLAS_ROLES_DEV=""
PT_ATLAS_PLAYS=""
PT_ANSIBLE_PROD_GLOBS=""
PT_FILE_PATHS=""
# yank_verbs: stored as multi-line per-tool, queried via grep.
PT_YANK_VERBS_HELM=""
PT_YANK_VERBS_KUBECTL=""
PT_YANK_VERBS_OC=""
PT_YANK_VERBS_DOCKER_COMPOSE=""
PT_YANK_VERBS_SYSTEMCTL=""
PT_YANK_VERBS_ATLAS=""
PT_YANK_VERBS_FILE=""

pt_load_manifest() {
    [[ "$PT_LOADED" == "1" ]] && return 0
    if ! command -v yq >/dev/null 2>&1; then
        return 1
    fi
    [[ -f "$PT_MANIFEST" ]] || return 1

    # mikefarah yq's string-concat does not expand control escapes, so
    # we store one release name per line. The namespace/cluster columns
    # aren't needed for the simple match (Phase 3 matches by release
    # name); callers who need them can re-yq the manifest.
    PT_HELM_RELEASES="$(yq -r '.prod_helm_releases[].release' "$PT_MANIFEST" 2>/dev/null)"
    PT_K8S_CONTEXTS="$(yq -r '.prod_k8s_contexts[]' "$PT_MANIFEST" 2>/dev/null)"
    PT_SYSTEMD_UNITS="$(yq -r '.prod_systemd_units[]' "$PT_MANIFEST" 2>/dev/null)"
    PT_DOCKER_LOCAL_DEV="$(yq -r '.prod_docker_compose.local_dev_only[]' "$PT_MANIFEST" 2>/dev/null)"
    PT_SSH_HOSTS="$(yq -r '.prod_ssh_hosts[]' "$PT_MANIFEST" 2>/dev/null)"
    PT_ATLAS_ROLES_PROD="$(yq -r '.prod_atlas_roles.prod[]' "$PT_MANIFEST" 2>/dev/null)"
    PT_ATLAS_ROLES_DEV="$(yq -r '.prod_atlas_roles.dev_only[]' "$PT_MANIFEST" 2>/dev/null)"
    PT_ATLAS_PLAYS="$(yq -r '.prod_atlas_plays[]' "$PT_MANIFEST" 2>/dev/null)"
    PT_ANSIBLE_PROD_GLOBS="$(yq -r '.prod_ansible_plays.prod_path_globs[]' "$PT_MANIFEST" 2>/dev/null)"
    PT_FILE_PATHS="$(yq -r '.prod_file_paths[]' "$PT_MANIFEST" 2>/dev/null)"

    # Namespaces stored as "<ctx>|<ns>" lines. Pipe is the delim (not
    # an ASCII control char — mikefarah yq's "+" concat doesn't expand
    # control-char escapes).
    PT_NAMESPACES_BY_CTX_DELIM='|'
    PT_NAMESPACES_BY_CTX="$(yq -r '.prod_k8s_namespaces | to_entries | .[] as $entry | $entry.value[] | $entry.key + "|" + .' "$PT_MANIFEST" 2>/dev/null)"

    PT_YANK_VERBS_HELM="$(yq -r '.yank_verbs.helm[]' "$PT_MANIFEST" 2>/dev/null)"
    PT_YANK_VERBS_KUBECTL="$(yq -r '.yank_verbs.kubectl[]' "$PT_MANIFEST" 2>/dev/null)"
    PT_YANK_VERBS_OC="$(yq -r '.yank_verbs.oc[]' "$PT_MANIFEST" 2>/dev/null)"
    PT_YANK_VERBS_DOCKER_COMPOSE="$(yq -r '.yank_verbs.docker_compose[]' "$PT_MANIFEST" 2>/dev/null)"
    PT_YANK_VERBS_SYSTEMCTL="$(yq -r '.yank_verbs.systemctl[]' "$PT_MANIFEST" 2>/dev/null)"
    PT_YANK_VERBS_ATLAS="$(yq -r '.yank_verbs.atlas[]' "$PT_MANIFEST" 2>/dev/null)"
    PT_YANK_VERBS_FILE="$(yq -r '.yank_verbs.file[]' "$PT_MANIFEST" 2>/dev/null)"

    PT_LOADED=1
    return 0
}

# pt_glob_match <pattern> <value>
# Supports '*' as a trailing wildcard, and '*' alone as match-anything.
# All other characters are literal.
pt_glob_match() {
    local pat="$1" val="$2"
    if [[ "$pat" == "*" ]]; then return 0; fi
    if [[ "$pat" == *"*" ]]; then
        local prefix="${pat%\*}"
        [[ "$val" == "$prefix"* ]] && return 0
        return 1
    fi
    [[ "$pat" == "$val" ]]
}

# pt_any_glob_match <value> <newline-separated patterns>
pt_any_glob_match() {
    local val="$1" patterns="$2" pat=""
    while IFS= read -r pat; do
        [[ -z "$pat" ]] && continue
        if pt_glob_match "$pat" "$val"; then return 0; fi
    done <<< "$patterns"
    return 1
}

pt_is_prod_target() {
    pt_load_manifest || return 1
    local entry="$1"
    local type="${entry%%:*}"
    local val="${entry#*:}"
    [[ -z "$type" || -z "$val" || "$type" == "$val" ]] && return 1

    case "$type" in
        helm_release)
            pt_any_glob_match "$val" "$PT_HELM_RELEASES"
            return $?
            ;;
        k8s_namespace)
            # Match ns within ANY prod context. The verifier upstream
            # cross-references k8s_context separately so we don't gate
            # here.
            local line ctx ns
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                ctx="${line%%${PT_NAMESPACES_BY_CTX_DELIM}*}"
                ns="${line#*${PT_NAMESPACES_BY_CTX_DELIM}}"
                if pt_glob_match "$ns" "$val"; then return 0; fi
            done <<< "$PT_NAMESPACES_BY_CTX"
            return 1
            ;;
        k8s_context)
            pt_any_glob_match "$val" "$PT_K8S_CONTEXTS"
            return $?
            ;;
        k8s_resource)
            # Treat any kind/name under a prod ns as prod. We don't have
            # the namespace context inside the entry itself; conservative
            # answer is YES (this verb-against-this-resource should be
            # verified). Phase 3 also gets the namespace separately.
            return 0
            ;;
        systemd_unit)
            pt_any_glob_match "$val" "$PT_SYSTEMD_UNITS"
            return $?
            ;;
        docker_compose)
            # Local-dev allowlist semantics: if the path is in
            # local_dev_only it's NOT prod; everything else IS.
            local expanded="${val/#\~/$HOME}"
            local line pat
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                pat="${line/#\~/$HOME}"
                if pt_glob_match "$pat" "$expanded"; then return 1; fi
            done <<< "$PT_DOCKER_LOCAL_DEV"
            return 0
            ;;
        ssh_host)
            pt_any_glob_match "$val" "$PT_SSH_HOSTS"
            return $?
            ;;
        atlas_role)
            # dev_only short-circuits to NOT prod even if a glob in prod
            # would otherwise match.
            if pt_any_glob_match "$val" "$PT_ATLAS_ROLES_DEV"; then
                return 1
            fi
            pt_any_glob_match "$val" "$PT_ATLAS_ROLES_PROD"
            return $?
            ;;
        atlas_play)
            # Match by basename: the extractor sees the user's literal arg
            # (`atlas playbook harbor-deploy.yml`), while the manifest may
            # be qualified (`playbooks/harbor-deploy.yml`). Equal basenames
            # = same play.
            local val_bn="${val##*/}"
            local line line_bn
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                line_bn="${line##*/}"
                if pt_glob_match "$line_bn" "$val_bn"; then return 0; fi
                if pt_glob_match "$line" "$val"; then return 0; fi
            done <<< "$PT_ATLAS_PLAYS"
            return 1
            ;;
        ansible_play)
            pt_any_glob_match "$val" "$PT_ANSIBLE_PROD_GLOBS"
            return $?
            ;;
        file_path)
            local expanded="${val/#\~/$HOME}"
            local line pat
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                pat="${line/#\~/$HOME}"
                if pt_glob_match "$pat" "$expanded"; then return 0; fi
            done <<< "$PT_FILE_PATHS"
            return 1
            ;;
        *)
            return 1
            ;;
    esac
}

pt_is_yank_verb() {
    pt_load_manifest || return 1
    local tool="$1" verb="$2"
    local list=""
    case "$tool" in
        helm)           list="$PT_YANK_VERBS_HELM" ;;
        kubectl)        list="$PT_YANK_VERBS_KUBECTL" ;;
        oc)             list="$PT_YANK_VERBS_OC" ;;
        docker_compose) list="$PT_YANK_VERBS_DOCKER_COMPOSE" ;;
        systemctl)      list="$PT_YANK_VERBS_SYSTEMCTL" ;;
        atlas)          list="$PT_YANK_VERBS_ATLAS" ;;
        file)           list="$PT_YANK_VERBS_FILE" ;;
        *) return 1 ;;
    esac
    while IFS= read -r v; do
        [[ -z "$v" ]] && continue
        [[ "$v" == "$verb" ]] && return 0
    done <<< "$list"
    return 1
}

pt_audit_log() {
    local tag="$1"; shift
    local msg="$*"
    local dir
    dir="$(dirname -- "$PT_AUDIT_LOG")"
    [[ -d "$dir" ]] || mkdir -p "$dir"
    if [[ ! -f "$PT_AUDIT_LOG" ]]; then
        ( umask 077; touch "$PT_AUDIT_LOG" )
    fi
    printf '[%s] %s %s\n' "$(date -Iseconds)" "$tag" "$msg" >> "$PT_AUDIT_LOG"
}
