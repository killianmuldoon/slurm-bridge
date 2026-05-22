// SPDX-FileCopyrightText: Copyright (C) SchedMD LLC.
// SPDX-License-Identifier: Apache-2.0

package nodeinfo

import (
	"sort"

	resourcev1 "k8s.io/api/resource/v1"
	"k8s.io/utils/ptr"

	"github.com/SlinkyProject/slurm-bridge/internal/wellknown"
)

// NetInfo holds information about a single network device.
type NetInfo struct {
	Name          string `json:"name"`
	PoolName      string `json:"poolName"`
	Index         int    `json:"index"`
	IfName        string `json:"ifName"`
	RDMA          bool   `json:"rdma"`
	Encapsulation string `json:"encapsulation"`
}

type NetMap struct {
	DeviceClass string
	NetInfoMap  map[int]*NetInfo
}

const (
	DraDriverNet_IfName        resourcev1.QualifiedName = "dra.net/ifName"
	DraDriverNet_RDMA          resourcev1.QualifiedName = "dra.net/rdma"
	DraDriverNet_Encapsulation resourcev1.QualifiedName = "dra.net/encapsulation"
)

func NewNetInfos(rSlice *resourcev1.ResourceSlice) []*NetInfo {
	netInfos := []*NetInfo{}
	if rSlice.Spec.Driver != wellknown.DraDriverNet {
		return netInfos
	}
	for _, device := range rSlice.Spec.Devices {
		netInfo := &NetInfo{
			Name:          device.Name,
			PoolName:      rSlice.Spec.Pool.Name,
			IfName:        ptr.Deref(device.Attributes[DraDriverNet_IfName].StringValue, ""),
			RDMA:          ptr.Deref(device.Attributes[DraDriverNet_RDMA].BoolValue, false),
			Encapsulation: ptr.Deref(device.Attributes[DraDriverNet_Encapsulation].StringValue, ""),
		}
		if netInfo.PoolName == "" {
			netInfo.PoolName = ptr.Deref(rSlice.Spec.NodeName, "")
		}
		if !isDefaultDRANetIBDevice(netInfo) {
			continue
		}
		netInfos = append(netInfos, netInfo)
	}
	return netInfos
}

func NewNetMap(deviceClass string, netInfos []*NetInfo) NetMap {
	sort.Slice(netInfos, func(i, j int) bool {
		if netInfos[i].IfName != netInfos[j].IfName {
			return netInfos[i].IfName < netInfos[j].IfName
		}
		return netInfos[i].Name < netInfos[j].Name
	})

	netMap := NetMap{
		DeviceClass: deviceClass,
		NetInfoMap:  make(map[int]*NetInfo, len(netInfos)),
	}
	for i, netInfo := range netInfos {
		netInfo.Index = i
		netMap.NetInfoMap[i] = netInfo
	}
	return netMap
}

func isDefaultDRANetIBDevice(netInfo *NetInfo) bool {
	return netInfo != nil &&
		netInfo.RDMA &&
		netInfo.Encapsulation == "infiniband" &&
		netInfo.IfName != ""
}
