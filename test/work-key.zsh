#!/usr/bin/env zshctl

source ${0:A:h:h}/hooks/schedule.zsh
source ${0:A:h:h}/hooks/complete.zsh

function check {
    typeset description=$1
    shift
    "$@" || { printf 'not ok - %s\n' "$description" >&2; exit 1; }
    printf 'ok - %s\n' "$description"
}

function kubectl {
    if [[ "$*" = *marginaljobs.marginal.flatheadmill.com* ]]; then
        printf '%s\n' "$listeners"
    elif [[ "$*" = *'get job '* ]]; then
        (( ++lookups ))
        (( lookup_failure )) && return 1
        return 0
    elif [[ $1 = apply ]]; then
        created_manifest=$(cat)
        (( ++created ))
    elif [[ $1 = annotate ]]; then
        source_object=$(jq --arg key "${argv[-1]%%=*}" --arg value "${argv[-1]#*=}" '
            .metadata.annotations[$key]=$value |
            .metadata.resourceVersion |= (tonumber + 1 | tostring)
        ' <<< "$source_object")
    elif [[ "$*" = 'get Secret '* || "$*" = 'get secret '* ]]; then
        printf 'secret/cert\n'
    else
        printf 'unexpected kubectl call\n' >&2
        return 1
    fi
}

function run_event {
    schedule --event-type "$1" --object "$source_object" --listener reload
}

function skipped {
    typeset description=$1 event=${2:-modified}
    integer before=$created before_lookups=$lookups
    run_event "$event" > "$test_tmp/output" 2>&1
    check "$description is a successful skip" test $? -eq 0
    check "$description creates no Job" test "$created" -eq "$before"
    check "$description performs no Job lookup" test "$lookups" -eq "$before_lookups"
    check "$description reports the template identity" rg -q 'marginal/reload template tls' "$test_tmp/output"
    if rg -q "$canary" "$test_tmp/output"; then
        printf 'not ok - diagnostic leaked a source value\n' >&2
        exit 1
    fi
}

function :execute {
    typeset source_object='{"metadata":{"name":"cert","namespace":"certificates","resourceVersion":"17","uid":"original-uid","annotations":{"revision":"one"}}}'
    typeset listeners='{"items":[{"metadata":{"name":"reload","namespace":"marginal"},"spec":{"apiVersion":"v1","kind":"Secret","jobTemplates":[{"name":"tls","executeHookOnEvent":["Added","Modified"],"uniqueKey":".metadata.annotations.revision","spec":{"template":{"spec":{"containers":[{"name":"reload","image":"fixture","env":[]}]}}}}]}}]}'
    typeset test_tmp=$(mktemp -d) created_manifest first_job completed expression event expected
    typeset canary=MARGINAL_DUMMY_KEY_CANARY_20260912
    integer created=0 lookups=0 lookup_failure=0 before
    {
        check 'meaningful source revision creates work' run_event modified
        check 'one Job was created' test "$created" -eq 1
        first_job=$(gojq --yaml-input -r '.metadata.name' <<< "$created_manifest")
        check 'valid key keeps its existing deterministic name' test "$first_job" = reload-tls-9ddeedf6
        completed=$(gojq --yaml-input '.status={conditions:[{type:"Complete",status:"True"}]}' <<< "$created_manifest")
        check 'success writes the existing completion marker' record_completion --object "$completed"
        check 'completion changed resourceVersion' jq -e '.metadata.resourceVersion == "18"' <<< "$source_object"
        check 'completion Modified event creates no new work after cleanup' run_event modified
        check 'startup replay creates no new work after cleanup' run_event added
        check 'bookkeeping and replay did not duplicate work' test "$created" -eq 1

        source_object=$(jq '.metadata.annotations.revision="two" | .metadata.resourceVersion="19"' <<< "$source_object")
        check 'a new meaningful key permits new work' run_event modified
        check 'new revision created exactly one more Job' test "$created" -eq 2
        check 'new revision retains the old naming scheme' test "$(gojq --yaml-input -r '.metadata.name' <<< "$created_manifest")" = reload-tls-cb7a37a3

        lookup_failure=1
        for expression in '.missing' 'null' '""' '"\n"' 'empty' '[]' '{}' '"one","two"' "\"$canary"; do
            listeners=$(jq --arg expression "$expression" '.items[0].spec.jobTemplates[0].uniqueKey=$expression' <<< "$listeners")
            skipped 'invalid or unpublished key'
        done
        listeners=$(jq 'del(.items[0].spec.jobTemplates[0].uniqueKey)' <<< "$listeners")
        skipped 'Modified template without an explicit key' modified
        skipped 'invalid Modified template during startup' added

        lookup_failure=0
        listeners=$(jq '.items[0].spec.jobTemplates[0].uniqueKey=".metadata.annotations.ready"' <<< "$listeners")
        skipped 'producer key not yet published'
        source_object=$(jq '.metadata.annotations.ready="published"' <<< "$source_object")
        before=$created
        check 'later publication of the key creates work' run_event modified
        check 'published key created exactly one Job' test "$created" -eq "$(( before + 1 ))"

        for expression in false 0; do
            case $expression in
                false) expected=reload-tls-5c4f70fe ;;
                0) expected=reload-tls-cbcc4f7d ;;
            esac
            listeners=$(jq --arg expression "$expression" '.items[0].spec.jobTemplates[0].uniqueKey=$expression' <<< "$listeners")
            check 'false and zero are present key values' run_event modified
            check 'scalar key representation is unchanged' test "$(gojq --yaml-input -r '.metadata.name' <<< "$created_manifest")" = "$expected"
        done

        listeners=$(jq 'del(.items[0].spec.jobTemplates[0].uniqueKey) | .items[0].spec.jobTemplates[0].executeHookOnEvent=["Added","Deleted"]' <<< "$listeners")
        for event in added deleted; do
            check "$event keeps its UID default" run_event "$event"
            check "$event keeps its deterministic name" test "$(gojq --yaml-input -r '.metadata.name' <<< "$created_manifest")" = reload-tls-b12eed94
        done
    } always {
        rm -rf -- "$test_tmp"
    }
}
