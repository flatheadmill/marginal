function config {
    heredoc <<'    EOF'
        configVersion: v1
        kubernetes:
        - name: node
          apiVersion: traefik.io/v1alpha1
          kind: IngressRoute
          executeHookOnEvent: [ Added, Deleted ]
          labelSelector:
            matchExpressions:
            - key: node-restriction.kubernetes.io/marginal
              operator: Exists
    EOF
}
