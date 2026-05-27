// SPDX-FileCopyrightText: Copyright (C) SchedMD LLC.
// SPDX-License-Identifier: Apache-2.0

package wellknown

const (
	// DraDriverNet is the DRA driver name used by DRANET.
	DraDriverNet = "dra.net"

	// DraNetDeviceClassIB is the initial slurm-bridge DeviceClass mapping for
	// InfiniBand/RDMA network devices managed by DRANET.
	DraNetDeviceClassIB = "dranet-ib"

	// SlurmGresNameDRANet is the Slurm GRES name used for DRANET devices.
	//
	// This intentionally avoids Slurm's built-in "nic" GRES plugin. The native
	// plugin has NIC-specific device-file semantics that do not match DRANET's
	// Kubernetes DRA interface names.
	SlurmGresNameDRANet = "dranet"
)
