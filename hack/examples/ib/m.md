  • Yes. The current pattern is a good fit, but DRANET needs a slightly more general mapper because dra.net is a generic network driver and the useful resource identity is usually the DeviceClass or attributes,
    not only the driver name.
    
    Current Flow

  1. Node discovery: internal/nodeinfo/nodeinfo.go:169 lists ResourceSlices for a node and only understands dra.cpu, gpu.example.com, and gpu.nvidia.com.
  2. Node registration into Slurm: internal/nodeinfo/nodeinfo.go:195 turns GPU DRA slices into Slurm node config:

                                     Gres="gpu:gpu.example.com:4"
                                     GresConf="count=4,name=gpu,type=gpu.example.com,file=gpu-0,..."
                                     
                                     CPU DRA is not represented as GRES.

  3. Pod request to Slurm job: internal/utils/slurmjobir/slurmjobir.go:150 treats deviceclass.resource.kubernetes.io/gpu.nvidia.com as:

                                 gres/gpu:gpu.nvidia.com=1
                                 
                                 and internal/scheduler/plugins/slurmbridge/slurmcontrol/slurmcontrol.go:158 sends that as TresPerNode.

  4. Slurm allocation back to DRA: In PreBind, slurm-bridge reads Slurm’s allocated GRES layout internal/scheduler/plugins/slurmbridge/slurmcontrol/slurmcontrol.go:264, then internal/scheduler/plugins/
    slurmbridge/dra.go:33 creates and status-binds a generated ResourceClaim.
  5. Cleanup: generated claims are linked through pod.status.extendedResourceClaimStatus and deleted by the pod controller when the pod terminates: internal/controller/pod/pod_sync.go:189.
    
    DRANET Shape
  I would add a DRANET mapper that makes network devices look like Slurm GRES:

  Slurm GRES name: nic
  Slurm GRES type: <network DeviceClass or configured class>
  Examples:
    nic:dranet-ib:8
    nic:efa.networking.k8s.aws:4

  A pod would request:

  resources:
    requests:
      deviceclass.resource.kubernetes.io/dranet-ib: "1"
    limits:
      deviceclass.resource.kubernetes.io/dranet-ib: "1"

  slurm-bridge would submit:

    TresPerNode=gres/nic:dranet-ib=1

  Then after Slurm allocates a concrete NIC index, slurm-bridge generates:

  apiVersion: resource.k8s.io/v1
  kind: ResourceClaim
  spec:
    devices:
      requests:
        - name: nic
          exactly:
            deviceClassName: dranet-ib
            allocationMode: ExactCount
            count: 1
            selectors:
              - cel:
                  expression: device.attributes["dra.net"].ifName in ["ib0"]
      config:
        - requests: ["nic"]
          opaque:
            driver: dra.net
            parameters:
              interface:
                name: ib0
                mtu: 4092

Implementation Details
  I’d add internal/nodeinfo/netinfo.go with something like:

    type NetInfo struct {
    Index         int
    DeviceName    string
    PoolName      string
    IfName        string
    RDMADevice    string
    RDMA          bool
    Encapsulation string
    NumaNode      *int
    PCIAddress    string
    PCIRoot       string
    DeviceClass   string
  }

    The important part is storing both DeviceName and PoolName; DRA allocation status must identify driver/pool/device, not just the node name.

  I would not try to evaluate arbitrary DeviceClass CEL selectors in slurm-bridge at first. Add explicit admin config instead:

  draDeviceMappings:
    - deviceClassName: dranet-ib
      driver: dra.net
      slurmName: nic
      slurmType: dranet-ib
      selectors:
        rdma: true
        encapsulation: infiniband
      defaultInterface:
        name: ib0
        mtu: 4092

    That avoids silently mapping the wrong dra.net devices, since DRANET may expose Ethernet, IPoIB, EFA, IB-only RDMA devices, etc. DRANET docs show attributes like ifName, rdma, encapsulation, numaNode, and PCI
    address fields in ResourceSlices.
    
    PCI Root Alignment
    Plain nic GRES is not enough for PCI-root alignment unless Slurm allocates aligned GPU/NIC pairs. DRA constraints can validate alignment, but they cannot repair a bad Slurm allocation after Slurm has already
    chosen devices.

  For alignment, I’d support two modes:

  1. Pinned exact devices, sanity-checked by DRA: Slurm allocates gpu and nic; slurm-bridge pins both in one generated ResourceClaim. Add DeviceClaim.Constraints with matchAttribute when both drivers expose a
    common topology attribute. This fails loudly if Slurm picked a bad pair.
  2. Aligned bundle GRES: represent a GPU+NIC locality group as a separate Slurm GRES, for example:

                            fabric:pcieroot-0008:1
                            
                            Then one Slurm GRES allocation maps to a known GPU index plus NIC index set. This is the stronger design if alignment is a hard requirement.
    
    I’d implement normal nic:<class> first, but structure NetInfo and the mapping table so bundle mapping can be added without rewriting the generated-claim path.
    
    Key Changes Needed

  - Refactor GetGresAndGresConf to support multiple GRES names, not just one GPU map.
  - Generalize parseGPUDevicePlugin into a DRA extended-resource parser with a mapper registry.
  - Add DRANET ResourceSlice parsing and tests.
  - Generate DRANET ResourceClaim.spec.devices.config with opaque.driver: dra.net.
  - Use actual DRA pool/device names in claim allocation status.
  - Keep rejecting user-supplied spec.resourceClaims; slurm-bridge should remain the allocator bridge.

  Sources: local repo files linked above, DRANET ResourceSlice/config examples in DRANET Quick Start (https://dranet.dev/docs/quick-start/), DRANET topology/RDMA examples in GKE and GPUDirect RDMA with DRA
    (https://dranet.dev/docs/user/gke-rdma/), and Slurm GRES behavior in SchedMD GRES design (https://slurm.schedmd.com/gres_design.html).
