#!/usr/bin/env zshctl

source ${0:A:h:h}/hooks/config.zsh
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
        [[ $job_state = api-error ]] && return 1
        [[ $job_state = missing ]] && return 0
        printf '%s\n' "$job_state"
    elif [[ $1 = apply ]]; then
        created_manifest=$(cat)
        (( ++created ))
    elif [[ $1 = annotate ]]; then
        (( ++annotated ))
    elif [[ "$*" = 'get Secret '* || "$*" = 'get secret '* ]]; then
        printf 'secret/cert\n'
    else
        printf 'unexpected kubectl: %s\n' "$*" >&2
        return 1
    fi
}

function reconcile {
    schedule --event-type added --object "$object" --listener reload
}

function :execute {
    typeset object='{"metadata":{"name":"cert","namespace":"certificates","resourceVersion":"17","uid":"test","annotations":{"revision":"one"},"labels":{"reload":"yes"}}}'
    typeset listeners='{"items":[{"metadata":{"name":"reload","namespace":"marginal"},"spec":{"apiVersion":"v1","kind":"Secret","resyncSchedule":"* * * * *","objectFilter":{"matchExpressions":[{"key":"reload","operator":"In","values":["yes"]}]},"jobTemplates":[{"name":"tls","executeHookOnEvent":["Added","Modified"],"uniqueKey":".metadata.annotations.revision","spec":{"template":{"spec":{"containers":[{"name":"reload","image":"test","env":[]}]}}}}]}}]}'
    typeset job_state=missing created_manifest configuration completed expression event
    integer created=0 annotated=0 before

    configuration=$(config | gojq --yaml-input '.')
    check 'Marginal is event-driven even for a legacy resync field' jq -e \
        'has("schedule") | not' <<< "$configuration"
    check 'missing Job is created' reconcile
    check 'exactly one Job was created' test $created -eq 1
    job_state='{"status":{"active":1}}'
    check 'an active Job suppresses another run' reconcile
    check 'active Job did not create a duplicate' test $created -eq 1
    job_state='{"status":{"failed":3,"conditions":[{"type":"Failed","status":"True"}]}}'
    check 'a terminal failed Job waits for its own TTL' reconcile
    check 'failed Job was not replaced early' test $created -eq 1
    job_state=missing
    check 'a later source event can retry a collected failed Job' reconcile
    check 'retry created a second Job' test $created -eq 2
    completed=$(gojq --yaml-input -r '.metadata.name' <<< "$created_manifest")
    object=$(jq --arg completed "$completed" '.metadata.annotations["marginal.flatheadmill.com/reload-tls"]=$completed | .metadata.resourceVersion="18"' <<< "$object")
    check 'completion bookkeeping does not create work after Job cleanup' schedule --event-type modified --object "$object" --listener reload
    check 'completion survives Job garbage collection' reconcile
    check 'successful work was not repeated' test $created -eq 2
    object=$(jq 'del(.metadata.annotations["marginal.flatheadmill.com/reload-tls"])' <<< "$object")
    job_state=api-error
    reconcile >/dev/null 2>&1
    check 'an API error is not mistaken for a missing Job' test $? -ne 0
    check 'API error did not create a Job' test $created -eq 2
    job_state=missing
    check 'an unrelated listener does not receive the event' schedule --event-type added --object "$object" --listener unrelated
    check 'unrelated listener created nothing' test $created -eq 2

    check 'active Job completion events are successful no-ops' record_completion --object '{"status":{"active":1}}'
    check 'failed Jobs are not marked complete' record_completion --object '{"status":{"failed":1,"conditions":[{"type":"Failed","status":"True"}]}}'
    check 'non-success events wrote no completion marker' test $annotated -eq 0
    job_state=$(gojq --yaml-input '.status={succeeded:1,conditions:[{type:"Complete",status:"True"}]}' <<< "$created_manifest")
    check 'observed success records completion on the origin' record_completion --object "$job_state"
    check 'success wrote one completion marker' test $annotated -eq 1

    job_state=missing
    before=$created
    object=$(jq '.metadata.annotations.revision="two" | .metadata.resourceVersion="19"' <<< "$object")
    check 'a new producer revision creates work' schedule --event-type modified --object "$object" --listener reload
    check 'one new Job was created' test $created -eq $(( before + 1 ))

    before=$created
    listeners=$(jq 'del(.items[0].spec.jobTemplates[0].uniqueKey)' <<< "$listeners")
    for event in added modified; do
        check 'a Modified template needs an explicit key, including on replay' schedule --event-type $event --object "$object" --listener reload
    done
    for expression in '.missing' 'null' 'empty' '""' 'bad('; do
        listeners=$(jq --arg expression "$expression" '.items[0].spec.jobTemplates[0].uniqueKey=$expression' <<< "$listeners")
        check 'invalid or unpublished keys skip without retries' schedule --event-type modified --object "$object" --listener reload
    done
    check 'skipped keys created no Jobs' test $created -eq $before

    listeners=$(jq '.items[0].spec.jobTemplates[0].uniqueKey=".metadata.annotations.ready"' <<< "$listeners")
    check 'an unpublished producer key is skipped' reconcile
    object=$(jq '.metadata.annotations.ready="published"' <<< "$object")
    check 'a later published key creates work' reconcile
    check 'publication created one Job' test $created -eq $(( before + 1 ))

    listeners=$(jq 'del(.items[0].spec.jobTemplates[0].uniqueKey) | .items[0].spec.jobTemplates[0].executeHookOnEvent=["Added","Deleted"]' <<< "$listeners")
    object=$(jq '.metadata.uid="original-uid"' <<< "$object")
    for event in added deleted; do
        check 'Added/Deleted keep the UID default' schedule --event-type $event --object "$object" --listener reload
        check 'UID Job name is unchanged' test "$(gojq --yaml-input -r '.metadata.name' <<< "$created_manifest")" = reload-tls-b12eed94
    done
}
