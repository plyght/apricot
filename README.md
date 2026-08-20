# Apricot

Apricot is an embeddable bridge between version control systems and code forges.

A VCS integrates Apricot once through its adapter contract. Apricot publishes a browsable forge projection while preserving the complete native repository in a content-addressed carrier. The carrier is authoritative. Git is used only at the hosting boundary when a forge exposes Git transport. The VCS and its users do not need a Git repository, Git object model, or Git client.

## Model

Each publication contains two related views:

- A native carrier containing the VCS objects, references, metadata, and declared preservation guarantees.
- A forge projection that makes the source tree available to the host for browsing and collaboration.

Carrier integrity is verified before restoration. Branch carriers are stored under `refs/apricot/carriers/<branch>`, with read compatibility for the earlier `refs/apricot/native` location.

## Integration

VCS implementations provide an adapter that can:

- Describe a native snapshot and its preservation tier.
- Enumerate every authoritative native object.
- Restore the repository from those objects.
- Produce a browsable forge projection.
- Explicitly import, require resolution for, or refuse changes made to the projection.

The Zig API exposes the adapter, carrier, transport, collaboration, conformance, and publication primitives. A versioned C ABI is available in [`include/apricot.h`](include/apricot.h) for host callbacks, operations, carrier verification, and collaboration requests. The `apct` executable is a fallback and diagnostic client. A VCS with native integration does not require users to invoke it.

Superdetermine and Pijul provide the first real adapters. Both restore their authoritative repository state byte for byte while excluding documented host-local, transient, ignored, and untracked data that does not affect repository semantics.

## Forge support

Apricot currently provides:

- Git Smart HTTP discovery, fetch, and publication for existing Git forges.
- Content-addressed, integrity-checked native carriers and chunk storage.
- Atomic publication and recovery primitives for provider-independent forge edges.
- A universal collaboration model for issues, change requests, reviews, comments, forks, checks, releases, labels, and milestones.
- Forge request drivers for GitHub, GitLab, Forgejo, Cursor Origin, and Tangled.
- A provider-neutral conformance probe for transport and collaboration discovery.

Actual collaboration operations depend on the capabilities exposed by each forge. Unsupported fields and operations are reported explicitly.

VCS authors normally embed Apricot. The fallback client can exercise an adapter directly:

```sh
apct publish --vcs pijul https://github.com/owner/repository path/to/repository
apct fetch --vcs pijul https://github.com/owner/repository restored-repository
```

## Current limitations

- A new VCS needs one Apricot adapter. It does not need a separate adapter for every forge.
- Existing forges still require their supported transport at the network boundary. On Git forges, that boundary uses Git Smart HTTP and Git-shaped projection objects.
- Direct edits to a projection are not assumed to preserve native semantics. The current Superdetermine adapter refuses them until an explicit import policy exists.
- Collaboration APIs are not standardized across forges. Apricot provides one internal model and provider drivers, but feature coverage remains limited by each host.
- The project is pre-release and its public contracts may still change.

## Build

Apricot requires Zig 0.16 development tooling.

```sh
zig build
zig build test
zig build check
```

The build installs the `apct` executable, the static and shared Apricot libraries, and the C header.
