// SPDX-FileCopyrightText: Copyright (C) SchedMD LLC.
// SPDX-License-Identifier: Apache-2.0

package manifests

import (
	"crypto/sha256"
	"encoding/hex"
	"strings"
	"unicode"
)

const dnsLabelMaxLength = 63

func MachineNodeName(machine string) string {
	return KubernetesName("pai-machine", machine)
}

func KubernetesName(fallback string, parts ...string) string {
	source := strings.TrimSpace(strings.Join(parts, "-"))
	base := dnsLabel(source)
	if base == "" {
		base = dnsLabel(fallback)
	}
	if base == "" {
		base = "benchmark"
	}

	if base == source && len(base) <= dnsLabelMaxLength {
		return base
	}

	return hashedDNSLabel(base, source)
}

func LabelValue(value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return "unknown"
	}

	var b strings.Builder
	lastWasSeparator := false
	for _, r := range value {
		valid := unicode.IsLetter(r) || unicode.IsDigit(r) || r == '-' || r == '_' || r == '.'
		if valid {
			b.WriteRune(r)
			lastWasSeparator = false
			continue
		}
		if !lastWasSeparator {
			b.WriteByte('-')
			lastWasSeparator = true
		}
	}

	out := strings.Trim(b.String(), "-_.")
	if out == "" {
		out = "unknown"
	}
	if len(out) > dnsLabelMaxLength {
		out = strings.Trim(out[:dnsLabelMaxLength], "-_.")
	}
	if out == "" {
		return "unknown"
	}
	return out
}

func dnsLabel(value string) string {
	value = strings.ToLower(strings.TrimSpace(value))

	var b strings.Builder
	lastWasHyphen := false
	for _, r := range value {
		valid := (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9')
		if valid {
			b.WriteRune(r)
			lastWasHyphen = false
			continue
		}
		if !lastWasHyphen {
			b.WriteByte('-')
			lastWasHyphen = true
		}
	}

	return strings.Trim(b.String(), "-")
}

func hashedDNSLabel(base, source string) string {
	hash := shortHash(source)
	maxBaseLength := dnsLabelMaxLength - len(hash) - 1
	if len(base) > maxBaseLength {
		base = base[:maxBaseLength]
	}
	base = strings.Trim(base, "-")
	if base == "" {
		base = "pai-machine"
	}
	return base + "-" + hash
}

func shortHash(value string) string {
	sum := sha256.Sum256([]byte(value))
	return hex.EncodeToString(sum[:])[:8]
}
