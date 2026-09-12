function config {
    setopt localoptions pipefail
    typeset marginaljobs
    integer count
    marginaljobs=$(kubectl get marginaljobs.marginal.flatheadmill.com \
        --all-namespaces -o json) || return 1
    count=$(jq -er '.items | length' <<< "$marginaljobs") || return 1

    if (( count == 0 )); then
        cat <<'EOF'
configVersion: v1
kubernetes:
- name: marginaljobs
  apiVersion: marginal.flatheadmill.com/v1
  kind: MarginalJob
  executeHookOnEvent: [Added, Modified, Deleted]
  allowFailure: false
- name: marginal-managed-jobs
  apiVersion: batch/v1
  kind: Job
  executeHookOnEvent: [Added, Modified]
  labelSelector:
    matchLabels:
      marginal.flatheadmill.com/managed: "true"
  allowFailure: false
settings:
  executionMinInterval: 5s
  executionBurst: 1
EOF
        return
    fi

    jq -r '
        .items | map({
            name: .metadata.name,
            apiVersion: (.spec.apiVersion // "v1"),
            kind: (.spec.kind // "Node"),
            objectFilter: (.spec.objectFilter // {}),
            events: (
                [.spec.jobTemplates[]?.executeHookOnEvent[]?] | unique
            )
        }) as $bindings |
        {
            configVersion: "v1",
            kubernetes: (
                [$bindings[] | {
                    name: .name,
                    apiVersion: .apiVersion,
                    kind: .kind,
                    executeHookOnEvent: .events,
                    labelSelector: .objectFilter,
                    allowFailure: false
                }] + [{
                    name: "marginaljobs",
                    apiVersion: "marginal.flatheadmill.com/v1",
                    kind: "MarginalJob",
                    executeHookOnEvent: ["Added", "Modified", "Deleted"],
                    allowFailure: false
                }] + [{
                    name: "marginal-managed-jobs",
                    apiVersion: "batch/v1",
                    kind: "Job",
                    executeHookOnEvent: ["Added", "Modified"],
                    labelSelector: { matchLabels: { "marginal.flatheadmill.com/managed": "true" } },
                    allowFailure: false
                }]
            ),
            settings: {
                executionMinInterval: "5s",
                executionBurst: 1
            }
        }
    ' <<< "$marginaljobs" | gojq --yaml-output
}
