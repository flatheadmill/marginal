# The Job-terminal watcher. `hook` routes events from the `marginal-managed-jobs`
# binding (Jobs labelled `marginal.flatheadmill.com/managed=true`) here. When a
# managed Job reaches a terminal Succeeded state we propagate its completion back
# onto the object that spawned it, using the correlation `schedule` stamped on the
# Job at creation. This is what makes the completion annotation RELIABLY written:
# `schedule` alone rarely observes a Job's success (it reconciles on the watched
# object's events, not the Job's), so without this the annotation is seldom set and
# the next Synchronization replay re-creates the Job. Idempotent by construction —
# annotating the origin does not change the Job, and re-running the annotate is a
# no-op.

function record_completion {
    eval "$(args ,object -- "$@")"
    typeset object=$o_object

    #! Act only on a terminal Succeeded Job. A failed Job leaves succeeded=0 and no
    #! Complete condition, so it is never marked done here. Kubernetes owns Pod
    #! backoff within the Job; terminal failure and TTL cleanup do not themselves
    #! schedule another Job.
    # Successful Pods are not sufficient for a multi-completion Job.
    jq -e 'any(.status.conditions[]?; .type == "Complete" and .status == "True")' <<< "$object" >/dev/null || return 0

    typeset job_name origin_kind origin_namespace origin_name completed_key completed_value
    job_name=$(jq -r '.metadata.name // ""' <<< $object)
    origin_kind=$(jq -r '.metadata.annotations["marginal.flatheadmill.com/origin-kind"] // ""' <<< $object)
    origin_namespace=$(jq -r '.metadata.annotations["marginal.flatheadmill.com/origin-namespace"] // ""' <<< $object)
    origin_name=$(jq -r '.metadata.annotations["marginal.flatheadmill.com/origin-name"] // ""' <<< $object)
    completed_key=$(jq -r '.metadata.annotations["marginal.flatheadmill.com/completed-key"] // ""' <<< $object)
    completed_value=$(jq -r '.metadata.annotations["marginal.flatheadmill.com/completed-value"] // ""' <<< $object)

    #! A managed Job with no correlation stamp predates this watcher; there is
    #! nothing to propagate, and `schedule`'s own on-success annotate still covers it.
    [[ -n $origin_kind && -n $origin_name && -n $completed_key && -n $completed_value ]] || return 0

    #! `--namespace` is required for a namespaced origin (e.g. the cert Secret) and
    #! harmlessly ignored for a cluster-scoped one (e.g. a Node), so always pass it
    #! when we have one. Kind is lowercased for the `kubectl annotate <kind> <name>`
    #! resource argument, matching `schedule`.
    typeset -a ns_arg=()
    [[ -n $origin_namespace ]] && ns_arg=( --namespace $origin_namespace )

    # Deleted origins cannot carry a marker. A failed lookup is different and
    # must remain retryable, including a transient authorization/API failure.
    typeset origin
    origin=$(kubectl get "$origin_kind" "$origin_name" "$ns_arg[@]" --ignore-not-found -o name) || return 1
    [[ -n $origin ]] || return 0

    if kubectl annotate --overwrite $ns_arg ${origin_kind:l} $origin_name \
        "${completed_key}=${completed_value}"; then
        printf '%s\n' "marginal: job $job_name succeeded, marked $origin_kind/$origin_name complete ($completed_value)"
    else
        printf '%s\n' "marginal: job $job_name succeeded but could not annotate $origin_kind/$origin_name" >&2
        return 1
    fi
}
