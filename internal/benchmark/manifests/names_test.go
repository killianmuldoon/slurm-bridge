// SPDX-FileCopyrightText: Copyright (C) SchedMD LLC.
// SPDX-License-Identifier: Apache-2.0

package manifests

import (
	"strings"
	"testing"
)

func TestLabelValueKeepsValidValue(t *testing.T) {
	got := LabelValue("run-1_A.2")
	if got != "run-1_A.2" {
		t.Fatalf("LabelValue() = %q, want unchanged valid value", got)
	}
}

func TestLabelValueHashesSanitizedValue(t *testing.T) {
	got := LabelValue("run/1")
	if !strings.HasPrefix(got, "run-1-") {
		t.Fatalf("LabelValue() = %q, want sanitized hash prefix", got)
	}
	if got == "run-1" {
		t.Fatalf("LabelValue() = %q, want hash suffix", got)
	}
	if len(got) > dnsLabelMaxLength {
		t.Fatalf("LabelValue() length = %d, want <= %d", len(got), dnsLabelMaxLength)
	}
}

func TestLabelValueHashesLongValues(t *testing.T) {
	a := LabelValue(strings.Repeat("a", 70))
	b := LabelValue(strings.Repeat("a", 69) + "b")
	if a == b {
		t.Fatalf("LabelValue() collision for long values: %q", a)
	}
	if len(a) > dnsLabelMaxLength || len(b) > dnsLabelMaxLength {
		t.Fatalf("LabelValue() lengths = %d/%d, want <= %d", len(a), len(b), dnsLabelMaxLength)
	}
}
