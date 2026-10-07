#!/bin/sh
set -eu

source_dir="${BACKUP_SOURCE:-/vault}"
repository="${BACKUP_REPOSITORY:-/backup}"
interval="${BACKUP_INTERVAL_SECONDS:-3600}"
branch="${BACKUP_GIT_BRANCH:-main}"
author_name="${BACKUP_AUTHOR_NAME:-LiveSync Git Backup}"
author_email="${BACKUP_AUTHOR_EMAIL:-backup@example.invalid}"
remote="${BACKUP_REMOTE:-}"
mode="${1:---loop}"

case "$mode" in
    --once|--loop)
        ;;
    *)
        echo "usage: git-cold-backup [--once|--loop]" >&2
        exit 2
        ;;
esac

case "$interval" in
    ''|*[!0-9]*|0)
        echo "BACKUP_INTERVAL_SECONDS must be a positive integer" >&2
        exit 2
        ;;
esac

if [ ! -d "$source_dir" ]; then
    echo "backup source does not exist: $source_dir" >&2
    exit 1
fi

mkdir -p "$repository"

if [ ! -f "$repository/HEAD" ]; then
    git init --bare --initial-branch="$branch" "$repository" >/dev/null
fi

if [ "$(git --git-dir="$repository" rev-parse --is-bare-repository)" != "true" ]; then
    echo "backup repository is not a bare Git repository: $repository" >&2
    exit 1
fi

git --git-dir="$repository" config user.name "$author_name"
git --git-dir="$repository" config user.email "$author_email"

if [ -n "$remote" ]; then
    case "$remote" in
        http://*@*|https://*@*)
            echo "BACKUP_REMOTE must not contain embedded credentials" >&2
            exit 2
            ;;
        git@*|ssh://*|*@*:*)
            if [ -z "${BACKUP_SSH_KEY:-}" ] || [ -z "${BACKUP_SSH_KNOWN_HOSTS:-}" ]; then
                echo "SSH BACKUP_REMOTE requires BACKUP_SSH_KEY and BACKUP_SSH_KNOWN_HOSTS" >&2
                exit 2
            fi
            ;;
    esac

    if git --git-dir="$repository" remote get-url origin >/dev/null 2>&1; then
        git --git-dir="$repository" remote set-url origin "$remote"
    else
        git --git-dir="$repository" remote add origin "$remote"
    fi
fi

if [ -n "${BACKUP_SSH_KEY:-}" ]; then
    if [ ! -r "$BACKUP_SSH_KEY" ]; then
        echo "BACKUP_SSH_KEY is not readable" >&2
        exit 1
    fi

    shell_quote() {
        quoted=$(printf '%s' "$1" | sed "s/'/'\\\\''/g")
        printf "'%s'" "$quoted"
    }

    ssh_options="-i $(shell_quote "$BACKUP_SSH_KEY") -o IdentitiesOnly=yes"
    if [ -n "${BACKUP_SSH_KNOWN_HOSTS:-}" ]; then
        if [ ! -r "$BACKUP_SSH_KNOWN_HOSTS" ]; then
            echo "BACKUP_SSH_KNOWN_HOSTS is not readable" >&2
            exit 1
        fi
        ssh_options="$ssh_options -o UserKnownHostsFile=$(shell_quote "$BACKUP_SSH_KNOWN_HOSTS") -o StrictHostKeyChecking=yes"
    fi
    export GIT_SSH_COMMAND="ssh $ssh_options"
fi

prepare_branch() {
    remote_refs=
    if ! remote_refs=$(git --git-dir="$repository" ls-remote --heads origin "$branch"); then
        echo "failed to inspect remote branch: $branch" >&2
        return 1
    fi

    if [ -z "$remote_refs" ]; then
        return 0
    fi

    git --git-dir="$repository" fetch origin "$branch" >/dev/null
    remote_head=$(git --git-dir="$repository" rev-parse "refs/remotes/origin/$branch")
    local_ref="refs/heads/$branch"

    if ! git --git-dir="$repository" show-ref --verify --quiet "$local_ref"; then
        git --git-dir="$repository" update-ref "$local_ref" "$remote_head"
        return 0
    fi

    local_head=$(git --git-dir="$repository" rev-parse "$local_ref")
    if [ "$local_head" = "$remote_head" ]; then
        return 0
    fi

    if git --git-dir="$repository" merge-base --is-ancestor "$local_head" "$remote_head"; then
        git --git-dir="$repository" update-ref "$local_ref" "$remote_head"
    elif ! git --git-dir="$repository" merge-base --is-ancestor "$remote_head" "$local_head"; then
        echo "backup history diverged from remote branch: $branch" >&2
        return 1
    fi
}

if [ -n "$remote" ]; then
    git --git-dir="$repository" symbolic-ref HEAD "refs/heads/$branch"
fi

make_snapshot() {
    if [ -n "$remote" ]; then
        prepare_branch
    fi

    snapshot=$(mktemp -d)
    trap 'rm -rf "$snapshot"' EXIT INT TERM

    cp -a "$source_dir"/. "$snapshot"/
    rm -rf "$snapshot/.git"

    git --git-dir="$repository" --work-tree="$snapshot" add -A
    if ! git --git-dir="$repository" diff --cached --quiet; then
        git --git-dir="$repository" --work-tree="$snapshot" commit \
            -m "backup: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null
    fi

    if [ -n "$remote" ] && git --git-dir="$repository" rev-parse --verify HEAD >/dev/null 2>&1; then
        if ! git --git-dir="$repository" push origin "HEAD:$branch"; then
            echo "backup push was rejected; refusing to merge or force-push remote history" >&2
            return 1
        fi
    fi

    rm -rf "$snapshot"
    trap - EXIT INT TERM
}

while :; do
    make_snapshot

    if [ "$mode" = "--once" ]; then
        exit 0
    fi

    sleep "$interval"
done
