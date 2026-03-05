function config {
    typeset marginaljobs
    marginaljobs=$(kubectl get marginaljobs.marginal.flatheadmill.com \
        --all-namespaces -o json 2>/dev/null)

    if [[ $? -ne 0 ]] || [[ $(jq '.items | length' <<< "$marginaljobs") -eq 0 ]]; then
        cat <<'EOF'
configVersion: v1
kubernetes:
- name: marginaljobs
  apiVersion: marginal.flatheadmill.com/v1
  kind: MarginalJob
  executeHookOnEvent: [Added, Modified, Deleted]
  allowFailure: true
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
                    allowFailure: true
                }] + [{
                    name: "marginaljobs",
                    apiVersion: "marginal.flatheadmill.com/v1",
                    kind: "MarginalJob",
                    executeHookOnEvent: ["Added", "Modified", "Deleted"],
                    allowFailure: true
                }]
            ),
            settings: {
                executionMinInterval: "5s",
                executionBurst: 1
            }
        }
    ' <<< "$marginaljobs" | gojq --yaml-output
}
