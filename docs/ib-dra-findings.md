# IB and DRA Findings

## Working IB Baseline

- The initial IPoIB failure was caused by the InfiniBand fabric, not pod networking.
- Failed state showed IB ports in `PORT_INIT`, `sm_lid=0`, `port_lid=65535`, and interfaces with `NO-CARRIER`.
- OpenSM must run on the host/fabric side. Running or changing it inside test pods is not the right fix.
- After the VM reset, the fabric recovered and hostNetwork IB tests could pass over `ib1`.

## Current Test Shape

- The supported IB path today is `hostNetwork: true`.
- HostNetwork pods can use the host IB interface directly.
- The hostNetwork test uses a `PodGroup`, `slurm-bridge-scheduler`, and two pods placed on separate SlurmBridge worker nodes.
- The hostNetwork test configures `ib1`, assigns test IPs, checks ping, and runs `ib_write_bw`.
- The DRA IB test path uses `hostNetwork: false` and requests an extended DRA resource.
- The DRA IB test cannot pass end-to-end today because SlurmBridge does not yet fully support DRANET-backed allocations.

## Installed DRA Drivers

- CPU DRA is installed as `DeviceClass/dra.cpu`.
- Fake GPU DRA is installed as `DeviceClass/gpu.example.com`.
- DRANET is installed as `DeviceClass/dranet-ib`.
- CPU and fake GPU driver pods are scoped to SlurmBridge worker nodes.
- The fake GPU driver needed `v0.3.0`; `v0.2.0` rendered `resource.k8s.io/v1beta1`, while the cluster serves `resource.k8s.io/v1`.

## Slurm State

- Slurm now sees both SlurmBridge workers.
- CPU capacity appears as normal Slurm CPU fields, not GRES:
  - `CPUTot=6`
  - `CPUEfctv=6`
  - `CfgTRES=cpu=6,mem=14984M,billing=6`
- Fake GPUs appear as GRES:
  - `Gres=gpu:gpu.example.com:4`
- DRANET can appear as a generic Slurm GRES when Slurm has `GresTypes=gpu,dranet`:
  - `Gres=dranet:dranet-ib:2`
  - combined with fake GPU: `Gres=gpu:gpu.example.com:4,dranet:dranet-ib:2`
- `sinfo` can show duplicate rows because nodes are in both `slurm-bridge` and `all` partitions.

## DRANET GRES Facts

- SlurmBridge should map DRANET to a specific DRA DeviceClass, initially `DeviceClass/dranet-ib`.
- The Kubernetes extended resource name for that class is `deviceclass.resource.kubernetes.io/dranet-ib`.
- SlurmBridge should translate that extended resource to `gres/dranet:dranet-ib=<count>`.
- `dranet` is the Slurm GRES name; `dranet-ib` is the Slurm GRES type and the Kubernetes DeviceClass name.
- Slurm itself does not require the type string to be `gpu.nvidia.com`; the type can match another DeviceClass, such as `gpu.example.com` or `dranet-ib`, as long as SlurmBridge knows how to translate the concrete allocation back to DRA.
- Current SlurmBridge GPU DRA support is driver-specific in code for `gpu.nvidia.com` and `gpu.example.com`; it is not a fully arbitrary DRA driver mapper yet.
- CPU DRA does not use GRES. Slurm allocates CPUs normally and SlurmBridge converts the Slurm core bitmap into a generated CPU DRA claim.

## Slurm GRES Parser Facts

- `Name=nic` is not a good DRANET target. It invokes Slurm's native `gres/nic` plugin semantics, including NIC-specific file handling that does not match DRANET interface names cleanly.
- A generic `dranet` GRES avoids Slurm's native NIC plugin behavior.
- Slurm config still needs to include the generic GRES name:
  - `GresTypes=gpu,dranet`
- If `dranet` is missing from global `GresTypes`, Slurm can reject the generated job request with:
  - `Invalid generic resource (gres) specification`
- The same error can also come from a malformed or unsupported GRES/TRES request string, so it is not proof by itself that `GresTypes` is the only missing piece.
- `hack/kind.sh` now installs/upgrades the Slurm chart with `GresTypes=gpu,dranet` in `controller.extraConf`.
- That `hack/kind.sh` change only matters after the Slurm chart is actually upgraded/reconciled in the target cluster. It does not prove an already-running remote `slurmctld` has the setting.
- `controller.extraConf` must not be passed through Helm `--set-string` with an unescaped comma. Helm split `GresTypes=gpu,dranet` into `controller.extraConf: GresTypes=gpu` plus a bogus top-level key. Use `--set-file controller.extraConf=<file>` or escape the comma.
- The dynamic node `GresConf` format is not the same as static `gres.conf` file syntax in all details.
- Dynamic `GresConf` records are separated with `+`, not `;`.
- Dynamic `GresConf` parses `flags` as a numeric bitmask. `CountOnly` must be sent as `flags=8`, not `flags=CountOnly`.
- The live Slurm REST probe accepted this combined payload:
  - `Gres="gpu:gpu.example.com:4,dranet:dranet-ib:2"`
  - `GresConf="count=4,name=gpu,type=gpu.example.com,file=gpu-0,file=gpu-1,file=gpu-2,file=gpu-3+count=2,name=dranet,type=dranet-ib,flags=8"`
- That count-only DRANET shape is not sufficient for deterministic pod device handoff because Slurm reports only `CNT`, not concrete `IDX`.
- The deterministic DRANET shape SlurmBridge should try next is file-backed generic DRANET:
  - `GresConf="count=2,name=dranet,type=dranet-ib,file=ib0,file=ib1"`
  - expected job layout should include `IDX`, not only `CNT`
- The old bridge payload was rejected in that form because it used `;` between records and modeled DRANET as file-backed interface names; it did not isolate whether file-backed generic DRANET is valid when records are joined with `+`:
  - `count=4,name=gpu,type=gpu.example.com,file=gpu-0,...;count=2,name=dranet,type=dranet-ib,file=ib0,file=ib1`
- Important distinction: that probe only proves the dynamic node `Gres`/`GresConf` registration shape can parse. It does not prove that Slurm will accept a job submit/update with:
  - `TresPerNode=gres/dranet:dranet-ib=1`
- The current live failure:
  - `Invalid generic resource (gres) specification`
  means the job-request side is still unproven or misconfigured.
- If `GresTypes=gpu,dranet` was already tried and this still failed, likely causes are:
  - the setting was not actually active in `slurmctld`
  - `slurmctld` was not reconfigured or restarted after the chart/config change
  - the job request syntax SlurmBridge sends through `TresPerNode` is not accepted for this custom typed GRES
  - the selected required nodes do not have matching `Gres=dranet:dranet-ib:<n>` at the time of job submit/update
- Before treating `GresTypes=gpu,dranet` as the fix, verify the live controller state directly:
  - `scontrol show config | grep GresTypes`
  - `scontrol show node <node> | grep -E 'Gres|CfgTRES|AllocTRES'`
  - a direct Slurm submit/update probe using the same TRES string SlurmBridge sends


## DRA Extended Resource Feature Gate

- Kubernetes `DRAExtendedResource` is still alpha and defaults to `false` in Kubernetes 1.35.
- `DRAExtendedResource` depends on `DynamicResourceAllocation`; enabling DRA alone is not enough for generated extended-resource claims.
- The generated claim flow relies on `pod.status.extendedResourceClaimStatus`.
- The apiserver drops `pod.status.extendedResourceClaimStatus` when `DRAExtendedResource` is disabled.
- The observed live symptom was: SlurmBridge patched pod `ExtendedResourceClaimStatus`, the patch returned success, and immediate read-back showed the field empty:
  - `ExtendedResourceClaimStatus patch returned success but read-back status is empty`
- Therefore `DRAExtendedResource=true` must be enabled installation-wide, including at least:
  - `kube-apiserver`, so the status field is persisted
  - kubelets, so the generated extended-resource claim mapping is consumed during admission/runtime setup
  - scheduler components, for consistency with upstream DRA extended-resource behavior
- The expected feature-gate shape is:
  - `--feature-gates=DynamicResourceAllocation=true,DRAExtendedResource=true`
- `hack/kubeadm-vm-cluster.sh` now enables the DRA gates by default for kubeadm-created clusters via `K8S_FEATURE_GATES`.

## Current DRANET Bridge State

- After reloading the controller with the fixed node-registration path, Slurm had both real worker nodes registered with:
  - `Gres=gpu:gpu.example.com:4,dranet:dranet-ib:2`
- One later failure moved from node registration to scheduler PreBind.
- The PreBind error was:
  - `DRANET claim config currently supports one dranet device per request, got count=2 index="0-1"`
- That one-device limit is self-imposed by the current bridge code, not by Slurm or Kubernetes DRA.
- The guard exists because the first generated DRANET opaque config shape was singular:
  - `{"interface":{"name":"ib0"}}`
- The current test pods each request one DRANET device:
  - `deviceclass.resource.kubernetes.io/dranet-ib: 1`
- The Slurm job requested one DRANET GRES per node:
  - `TresPerNode=gres/dranet:dranet-ib=1`
- Slurm's detailed job view can report the whole node's DRANET inventory for each allocated node instead of the pod-requested count.
- With count-only DRANET registration, the live job layout reported:
  - `GRES=dranet:dranet-ib(CNT:2)`
- Therefore the next bridge issue is probably not "DRANET needs count=2 per pod". It is that PreBind is consuming node-level GRES layout and must trim it to the pod's actual extended resource request before generating the ResourceClaim.
- A concrete regression test should cover: pod requests `dranet-ib: 1`, Slurm node layout reports `dranet-ib: 2` plus unrelated `gpu`, and the generated claim still contains only the pod-sized DRANET request.
- After trimming to the pod request, the next observed live failure returned to Slurm job scheduling:
  - `Invalid generic resource (gres) specification`
- That failure happens before the generated DRANET ResourceClaim path can complete. It should be debugged as a Slurm GRES/TRES submit problem, not as a ResourceClaim generation problem.
- With the count-only DRANET GRES shape, Slurm reports allocated DRANET as `CNT:<n>` and does not return per-device `IDX` values:
  - `GRES=dranet:dranet-ib(CNT:2)`
- Therefore SlurmBridge cannot rely on Slurm to return concrete DRANET indices when the node GRES is registered with `flags=8`.
- SlurmBridge should fail closed when a DRA-backed GRES allocation does not include concrete `IDX`, because synthesizing indices after the fact is not proof that Slurm selected a specific physical NIC.
- True Slurm-side device identity requires a non-count-only GRES model that Slurm accepts for DRANET.
- For the current two-pod IB test, each pod should get a generated ResourceClaim for one concrete DRANET interface on its assigned node.
- The generated DRA selector should stay concrete, based on DRANET `ifName`, so Slurm's selected GRES index maps to the exact DRA device.
- DRANET's example opaque config uses a pod interface name, addresses, and MTU:
  - `interface.name`
  - `interface.addresses`
  - `interface.mtu`
- SlurmBridge currently only fills `interface.name`; test IP assignment is still handled by the test pod command/env path.
- DRANET supports a single DRA request with `count: 2` when no opaque config is supplied; its driver applies default config per allocated device and keeps each selected host interface name inside the pod.
- A single opaque DRANET config is scoped to the request, not to an individual selected device. Therefore a multi-device request cannot safely use one scalar `interface.name`; SlurmBridge omits DRANET config for multi-device requests instead of failing PreBind.

## CPU DRA Behavior

- If `DeviceClass/dra.cpu` exists, SlurmBridge creates a generated `ResourceClaim` for Slurm-assigned CPUs.
- Slurm allocates CPUs first and returns a core bitmap.
- SlurmBridge maps Slurm abstract cores to machine CPU IDs from the CPU DRA `ResourceSlice`.
- The generated CPU DRA request selects exact CPU IDs with CEL, for example:
  - `device.attributes['dra.cpu'].cpuID in [0,1,2,3]`
- SlurmBridge status-binds the claim to concrete CPU devices such as `cpudev000`.
- This is useful for enforcement and handoff correctness.
- This does not provide CPU-to-GPU or CPU-to-NIC locality by itself.

## ResourceSlice Topology Data

- CPU DRA exposes useful CPU topology:
  - `dra.cpu/cpuID`
  - `dra.cpu/coreID`
  - `dra.cpu/socketID`
  - `dra.cpu/numaNodeID`
  - `dra.cpu/cacheL3ID`
  - `dra.cpu/smtEnabled`
  - `dra.cpu/coreType`
- In the current VM cluster, all CPU DRA devices report NUMA node `0`.
- DRANET exposes useful network device identity:
  - `dra.net/ifName`
  - `dra.net/rdma`
  - `dra.net/encapsulation`
  - `dra.net/pciAddress`
  - `resource.kubernetes.io/pcieRoot`
  - `dra.net/pciVendor`
  - `dra.net/pciDevice`
- DRANET exposes both `ib0` and `ib1` as RDMA InfiniBand devices.
- Fake GPU DRA exposes only fake GPU identity and capacity:
  - `index`
  - `uuid`
  - `model`
  - `memory`
- Fake GPU DRA does not expose PCI, NUMA, or CPU locality.

## Locality Limits

- SlurmBridge currently runs off-node.
- SlurmBridge can read Kubernetes objects, but it cannot read worker-node sysfs directly.
- The missing mapping is node-local:
  - PCI BDF or PCIe root -> NUMA node -> local CPU set -> Slurm logical cores
- `resource.kubernetes.io/pcieRoot` can correlate devices under the same PCIe root.
- `pcieRoot` alone is not enough to produce Slurm CPU affinity.
- On the current VM cluster, PCIe root is too coarse because relevant devices are under `pci0000:00`.

## Slurm Locality Model

- Slurm can model GRES locality if SlurmBridge emits `GresConf` with core affinity.
- The count-only generic DRANET path is fileless:
  - `count=2,name=dranet,type=dranet-ib,flags=8`
- That shape is useful for capacity but not for deterministic DRA handoff, because Slurm does not return `IDX`.
- The deterministic generic DRANET path needs per-device file entries:
  - `count=2,name=dranet,type=dranet-ib,file=ib0,file=ib1`
- Per-device DRANET locality would need a richer model than this count-only mapping.
- A future locality-aware shape is conceptually:
  - `Name=gpu Type=gpu.example.com File=gpu-0 Cores=0-5`
  - DRANET device identity tied to PCI/NUMA/core topology rather than relying on Slurm's native `nic` plugin semantics.
- Slurm `Cores=` affinity is constrained by Slurm's topology model.
- For NUMA-aware GRES binding, Slurm may need NUMA domains represented as sockets, for example with `SlurmdParameters=numa_node_as_socket`.

## Kubelet Topology Manager

- Kubelet Topology Manager is node-local and runs after a pod is assigned to a node.
- It can be a runtime admission/alignment safety net for Kubernetes workloads.
- It does not publish a Slurm-ready topology map.
- It runs too late for SlurmBridge to use when asking Slurm to allocate a job.
- It does not solve SlurmBridge locality without another publisher or feedback path.

## NVIDIA DRA

- NVIDIA DRA is more promising than fake GPU DRA for real GPU topology.
- NVIDIA DRA has work around publishing `resource.kubernetes.io/pcieRoot`.
- If NVIDIA GPU DRA and DRANET both expose `pcieRoot`, SlurmBridge can correlate GPU and NIC placement under the same PCIe root.
- That still does not directly map devices to CPU cores.
- SlurmBridge still needs PCI/NUMA/core topology to emit useful Slurm `GresConf` affinity.

## Current Conclusion

- Current SlurmBridge can provide count-level DRA-to-GRES for fake GPUs.
- With the generic `dranet` GRES shape, Slurm can register DRANET capacity.
- For deterministic DRANET handoff, SlurmBridge should register DRANET as file-backed generic GRES and require Slurm to return concrete `IDX` values.
- Current SlurmBridge can create exact CPU DRA claims for Slurm-assigned CPUs.
- The remaining DRANET scheduler work is to translate Slurm's node-level GRES layout into pod-sized DRA claims and configs.
- Current SlurmBridge cannot guarantee CPU/GPU/NIC locality from the existing Kubernetes objects alone.
- To guarantee locality, a node-side topology publisher is needed.
- That publisher should expose:
  - PCI address or PCIe root
  - NUMA node
  - local CPU IDs
  - Slurm logical core mapping, or enough information for SlurmBridge to derive it
