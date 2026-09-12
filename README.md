# Marginal

Marginal creates Kubernetes Jobs in response to resource lifecycle events. When a node joins your cluster, Marginal can stripe its local SSDs into a RAID array. When a certificate renews, Marginal can reload your database. When a Secret appears, Marginal can run whatever administrative automation you need. Think of it as CronJob's event-driven cousin - instead of time triggers, you get resource triggers.

The Storage SIG publishes DaemonSets that run forever as root to configure nodes. They call this best practice. Your security scanner calls it a critical finding. Marginal offers a better way: Jobs that run once with privilege, finish, and disappear. The same root operations, but with proper lifecycle management. Your nodes get configured, your auditor sees completed Jobs with TTLs, everyone moves on.

Marginal is built on Flant's Shell Operator, which handles the Kubernetes event machinery. You define MarginalJobs (Custom Resources) that specify what to watch and what Jobs to create. When events match, Marginal creates Jobs from your templates. It's deliberately simple - no reconciliation loops, no distributed state, no complex operators. Just events triggering Jobs.

This is for administrative automation, not high-frequency event processing. Jobs are heavy - they create pods, consume resources, generate logs. If you're triggering more than a few dozen Jobs per hour, you're using the wrong tool. Marginal is for the important but infrequent tasks: hardware configuration, certificate rotation, database migrations, cleanup operations. The jobs that need to happen reliably but not constantly.

We call it Marginal because it operates at the margins - the edge cases where standard Kubernetes patterns don't quite fit. That node needs local disks configured before work can schedule. That legacy application needs a specific reload sequence when certificates change. That stateful service needs careful cleanup when migrating. These marginal cases deserve first-class automation, not kubectl exec sessions at 2 AM.

## Outline

### Installation
- CRD definition deployment
- Shell Operator deployment with RBAC
- Configuration via mounted ConfigMaps
- Example MarginalJob for testing

### Core Concepts
- MarginalJob CRD structure
- Event matching (Added, Modified, Deleted)
- Label selectors and namespace filtering
- Job template expansion
- Modification filters with jq

### Quick Start
- Deploy a hello-world MarginalJob
- Trigger events with kubectl
- Observe created Jobs
- Check Job annotations and status

### Examples
- Node initialization (RAID striping)
- Certificate rotation triggers
- Database migration orchestration
- Cleanup on resource deletion
- Cross-namespace event propagation

### Configuration Reference
- MarginalJob spec fields
- Environment variables for operator
- RBAC requirements per use case
- ServiceAccount configuration for Jobs

### Security Considerations
- Privilege requirements and dispositions
- Namespace isolation patterns
- Secret handling in event payloads
- Audit logging of Job creation

### Comparison to Alternatives
- vs DaemonSets for node configuration
- vs Operators for simple automation
- vs CronJobs for event-driven tasks
- vs Tekton for single-shot operations

### Troubleshooting
- Viewing binding contexts
- Debugging selector matching
- Job failure investigation
- Performance considerations

### Contributing
- Building custom containers
- Testing with fixture data
- Shell Operator binding examples
- Extending with new event sources

## Retry policy

Marginal reacts to resource events and replays current objects at startup.
Transient scheduling and completion API errors fail the hook and are retried by
Shell Operator with exponential backoff. A later successful event in the same
batch does not erase an earlier failure. Debug binding output includes object
identities only, never Secret data or annotations.
Kubernetes Jobs own exponential Pod backoff through `backoffLimit` and
`activeDeadlineSeconds`; Marginal does not poll to recreate failed Jobs.
Completion is recorded only after observed success. A terminal failed Job is
left failed; TTL cleanup alone does not trigger another run. Use a content-based
`uniqueKey` so later events and startup skip work that already succeeded.
For parallel Jobs, only the terminal `Complete=True` condition means success;
a positive successful-Pod count does not.

## Work keys

Templates subscribing to `Modified` must provide an explicit `uniqueKey`. Use
a producer's revision field or a digest of meaningful content that does not
change when Marginal writes its completion annotation. For certificate renewal,
the existing expiry annotation supplies that revision; Marginal maintains no
separate counter. Templates subscribing only to `Added` or `Deleted` retain the
object-UID default.

An invalid expression, a null/empty result, or multiple results skips that
template with an identity-only diagnostic. If the producer has not published
its key, a later source event can schedule it; the missing key does not cause
endless controller retries. Valid keys keep the existing deterministic Job names.
