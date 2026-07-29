function slugged {
    typeset material=${1:-}
    typeset -i16 hex=$(printf '%s' $material | cksum | cut -d' ' -f1)
    printf ${hex[4,-1]:l}
}

function schedule {
    eval "$(args ,event-type ,object -a ,listener -- "$@")"
    typeset tape=()
    tape=( "${(@QA)${(z)$(
        jq --raw-output '
            [
                (.metadata.annotations // {}) as $annotations |
                (.metadata.labels // {}) as $labels |
                (.metadata.namespace // "default"),
                .metadata.name,
                .metadata.resourceVersion,
                ($annotations | length),
                ($annotations | to_entries[] | (.key, .value)),
                ($labels | length),
                ($labels | to_entries[] | (.key, .value))
            ] | @sh
        ' <<< $o_object
    )}}" )
    set -- "${(@)tape}"
    typeset -A annotations labels
    integer annotation_count label_count
    typeset object_namespace=${1:-} object_name=${2:-} resource_version=${3:-} annotation_count=${4:-}
    shift 4
    while (( annotation_count-- )); do
        annotations+=( "${@[1,2]}" )
        shift 2
    done
    typeset label_count=${1:-}
    shift
    while (( label_count-- )); do
        labels+=( "${@[1,2]}" )
        shift 2
    done
    tape=( "${(@QA)${(z)$(
        setopt localoptions pipefail
        kubectl get \
            --all-namespaces --output json \
            marginaljobs.marginal.flatheadmill.com  |
        jq --raw-output '
            [
                .items[] |
                    (.spec.objectFilter?.matchExpressions // []) as $selectors |
                    (.spec.jobTemplateDefaults // {}) as $defaults |
                    (.spec.namespaceFilter // []) as $namespaces |
                    (.metadata.namespace // "default"),
                    (.metadata.name),
                    (.spec.apiVersion // ""),
                    (.spec.kind // ""),
                    ($selectors | length),
                    ($selectors[] |
                        (.values // []) as $values |
                        (.key, .operator, ($values | length), $values[]) ),
                    ($namespaces | length),
                    ($namespaces[]),
                    ((.spec.jobTemplates // []) | length),
                    (
                        (.spec.jobTemplates // [])[] |
                            (.name),
                            (.executeHookOnEvent // [] | length),
                            ((.executeHookOnEvent // [])[]),
                            (.modificationFilter // "1"),
                            (.env // "[]"),
                            (.uniqueKey // ""),
                            (.patch // "."),
                            (($defaults * .spec) | @json)
                    )
            ] | @sh
        '
    )}}" ) || abend 'cannot read CRD'
    set -- "${(@)tape}"
    typeset -A manifests
    typeset namespace name direction template key operator values=() namespaces=()
    integer selector_count values_count hit namespace_count
    typeset kind api_version slugged manifest
    integer template_count filtered on_count cm_exists
    typeset template_name template_namespace on=() jq cm_name cm_namespace
    while (( $# )); do
        namespace=${1:-} name=${2:-} kind=${3:-} api_version=${4:-} selector_count=${5:-}
        shift 5
        hit=1
        while (( selector_count-- )); do
            key=${1:-} operator=${2:-} values_count=${3:-}
            shift 3
            values=( "${@[1, $values_count]}" )
            shift $values_count
            case $operator in
            (In)
                (( $values[(Ie)$labels[$key]] )) || hit=0
                ;;
            (Exists)
                (( ${+labels[$key]} )) || hit=0
                ;;
            (NotIn)
                (( $values[(Ie)$labels[$key]] )) && hit=0
                ;;
            (DoesNotExist)
                (( ${+labels[$key]} )) && hit=0
                ;;
            esac
        done
        namespace_count=${1:-}
        shift
        namespaces=()
        if (( namespace_count )); then
            while (( namespace_count-- )); do
                case ${1:-} in
                (\*) namespaces+=( $namespace ) ;;
                (*) namespaces+=( $namespace ) ;;
                esac
                shift
            done
        else
            namespaces=( $namespace )
        fi
        (( $namespaces[(Ie)$namespace] )) || hit=0
        template_count=${1:-}
        shift
        while (( template_count-- )); do
            filtered=0
            template_name=${1:-} on_count=${2:-}
            shift 2
            on=( "${(@A)@[1,$on_count]:l}" )
            shift $on_count
            filter=${1:-} env=${2:-} unique_key=${3:-} patch=${4:-} template=${5:-}
            shift 5
            (( hit && $on[(Ie)$o_event_type] )) || continue
            if [[ $o_event_type = modified ]]; then
                print would run jq
            fi
            env=$(jq "$env" <<< $o_object) || abend 'cannot evaluate env'
            env=$(jq 'if type == "object" then [to_entries[] | {name: .key, value: (.value | tostring)}] else . end' <<< "$env")
            if [[ -z $unique_key ]]; then
                case $o_event_type in
                    modified) unique_key='.metadata.resourceVersion' ;;
                    *)        unique_key='.metadata.uid' ;;
                esac
            fi
            typeset unique_value
            unique_value=$(jq -r "$unique_key" <<< $o_object)
            slugged=$name-$template_name-$(slugged "$unique_value")
            # `marginal.flatheadmill.com/<name>-<template>` records the unique
            # value whose Job we last saw SUCCEED. It is written on completion,
            # not on creation, and outlives the Job's ttlSecondsAfterFinished GC,
            # so finished work is never repeated even once the Job is gone.
            typeset completed_key="marginal.flatheadmill.com/${name}-${template_name}"
            if [[ $(jq -r ".metadata.annotations[\"${completed_key}\"] // \"\"" <<< $o_object) == $slugged ]]; then
                printf '%s\n' "marginal: $object_name completed for $name/$template_name ($slugged), skipping"
                continue
            fi
            # The live Job (named deterministically by slug) is the record of what
            # is started for this unique value. We never delete it:
            #   succeeded -> record completion now, then skip.
            #   present   -> in progress OR finished-but-not-yet-GC'd; leave it.
            # A failed Job is retried only once its own ttlSecondsAfterFinished GC
            # removes it, at which point it is missing below and recreated. So all
            # retry policy lives in the MarginalJob (backoffLimit, activeDeadline,
            # ttlSecondsAfterFinished) — the operator never forces it.
            typeset job_json=$(kubectl -n $namespace get job $slugged -o json 2>/dev/null)
            if [[ -n $job_json ]]; then
                if (( $(jq '.status.succeeded // 0' <<< $job_json) )); then
                    kubectl annotate --overwrite ${api_version:l} $object_name \
                        "${completed_key}=${slugged}" 2>/dev/null || true
                    printf '%s\n' "marginal: $object_name job $slugged succeeded, marked complete"
                else
                    printf '%s\n' "marginal: $object_name job $slugged present, skipping"
                fi
                continue
            fi
            manifest=$(
                jq --argjson args "$(
                    jo -- name=$name slugged=$slugged namespace=$namespace \
                        when=$(date --iso=ns) \
                        node=$object_name  \
                        env=$env
                    )" \
                '
                    {
                        apiVersion: "batch/v1",
                        kind: "Job",
                        metadata: {
                            name: $args.slugged,
                            namespace: $args.namespace,
                            annotations: {
                                "marginal.flatheadmill.com/name": $args.name,
                            },
                            labels: {
                                "marginal.flatheadmill.com/managed": "true"
                            }
                        },
                        spec: (
                            . |
                                .template.spec.containers[].env += ([{
                                    name: "MARGINAL_RESTART_PREVENTION",
                                    value: $args.when
                                }] + $args.env)
                        )
                    }
                ' <<< $template
            )
            manifest=$(
                gojq --yaml-output --argjson object $o_object $patch <<< $manifest
            )
            #! Completion is recorded when the Job's success is observed above,
            #! never here on creation — a Job that later fails is retried, not
            #! mistaken for done.
            if (( MARGINAL_DRY_RUN )); then
                print $manifest
            else
                kubectl apply -f - <<< $manifest || abend 'unable to create job'
                printf '%s\n' "marginal: $object_name started job $slugged for $name/$template_name"
            fi
        done
    done
}
