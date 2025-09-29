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
                (.metadata | @json),
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
    typeset metadata=${1:-} object_namespace=${2:-} object_name=${3:-} resource_version=${4:-} annotation_count=${5:-}
    shift 5
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
                    ($defaults | length) * 2,
                    ($defaults | to_entries[] | (.key, .value)),
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
                            (.modificationFilter // ""),
                            (.patch // "."),
                            (.spec | @json)
                    )
            ] | @sh
        '
    )}}" ) || abend 'cannot read CRD'
    set -- "${(@)tape}"
    typeset -A manifests defaults
    typeset namespace name direction template key operator values=() namespaces=()
    integer defaults_count selector_count values_count hit namespace_count
    typeset kind api_version slugged manifest
    integer template_count filtered on_count cm_exists
    typeset template_name template_namespace on=() jq cm_name cm_namespace
    while (( $# )); do
        namespace=${1:-} name=${2:-} kind=${3:-} api_version=${4:-} defaults_count=${5:-}
        shift 5
        defaults=( "$@[1,$defaults_count]" )
        shift $defaults_count
        selector_count=${1:-}
        shift
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
            filter=${1:-} patch=${2:-} template=${3:-}
            shift 3
            (( hit && $on[(Ie)$o_event_type] )) || continue
            if [[ $o_event_type = modified && -n $filter ]]; then
                print would run jq
            fi
            values=()
            for key value in "${(@kv)defaults}"; do
                values+=( $key=$value )
            done
            print "${(@)values}"
            slugged=$name-$(slugged $object_namespace/$object_name)-$resource_version
            manifest=$(
                jq --argjson args "$(
                    jo -- name=$name slugged=$slugged namespace=$namespace \
                        when=$(date --iso=ns) \
                        node=$object_name  \
                        default="$(jo -- "${(@)values}" < /dev/null)" \
                        -s metadata=$metadata
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
                            ($args.default * .) |
                                .template.spec.containers[].env += [{
                                    name: "MARGINAL_RESTART_PREVENTION",
                                    value: $args.when
                                }, {
                                    name: "MARGINAL_OBJECT_METADATA",
                                    value: $args.metadata
                                }]
                        )
                    }
                ' <<< $template
            )
            manifests[$namespace/$name]=$(
                gojq --yaml-output --argjson metadata "$(jq '.metadata' <<< $o_object)" \
                    $patch <<< $manifest
            )
        done
    done
    for manifest in "${(@v)manifests}"; do
        if ! kubectl apply -f - <<< $manifest; then
            kubectl --namespace $namespace get job $slugged > /dev/null ||
                abend 'unable to create job'
        fi
    done
}
