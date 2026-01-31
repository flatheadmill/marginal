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
            filter=${1:-} env=${2:-} patch=${3:-} template=${4:-}
            shift 4
            (( hit && $on[(Ie)$o_event_type] )) || continue
            if [[ $o_event_type = modified ]]; then
                print would run jq
            fi
            env=$(jq $env <<< $o_object) || abend 'cannot evaluate env'
            slugged=$name-$(slugged $object_namespace/$object_name)-$resource_version
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
            manifests[$namespace/$name]=$(
                gojq --yaml-output --argjson object $o_object $patch <<< $manifest
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
