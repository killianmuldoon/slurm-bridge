# Debug Development

The debug workflow runs the slurm-bridge components with the delve debugger in a
Skaffold dev loop.

Run it with:

```sh
make debug
```

When the Kubernetes node architecture differs from the host architecture, pass
`DEBUG_GOARCH`. For example, from an arm64 Mac targeting amd64 kind nodes:

```sh
DEBUG_GOARCH=amd64 make debug
```

`DEBUG_GOARCH` is passed to the live-reload build hooks. If it is unset, the
hooks try to detect the architecture from the current Kubernetes context and
fall back to the host Go architecture.

The debug Skaffold profile builds the `scheduler-debug`, `controllers-debug`,
and `admission-debug` Docker targets. Those images run `/dlv-reload-wrapper` as
PID 1 instead of starting the component binary directly.

On Go or module file changes, Skaffold sync hooks run on the host:

1. `build-binary.sh` checks whether the changed files affect the component and
   builds `.skaffold-bin/<component>` when needed.
2. `copy-and-sighup.sh` copies the pending binary to
   `/workspace/next/<component>` in the running pod and sends `SIGHUP`.
3. `dlv-reload-wrapper.sh` promotes the pending binary, restarts Delve, and
   keeps the pod running.

Debug ports:

- Scheduler: `40000`
- Controllers: `40001`
- Admission: `40002`

Validate the debug wiring without deploying with:

```sh
make debug-validate
```
