// SPDX-FileCopyrightText: Copyright (C) SchedMD LLC.
// SPDX-License-Identifier: Apache-2.0

package slurmjobir

import (
	"context"
	"testing"

	"github.com/SlinkyProject/slurm-bridge/internal/wellknown"
	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	apiequality "k8s.io/apimachinery/pkg/api/equality"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	kubescheme "k8s.io/client-go/kubernetes/scheme"
	"k8s.io/utils/ptr"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	jobset "sigs.k8s.io/jobset/api/jobset/v1alpha2"
)

func newJobSet(name string) *jobset.JobSet {
	return &jobset.JobSet{
		ObjectMeta: metav1.ObjectMeta{
			Namespace: metav1.NamespaceDefault,
			Name:      name,
		},
	}
}

func TestTranslateToSlurmJobIR_TrainerOwnedJobSet(t *testing.T) {
	scheme := runtime.NewScheme()
	utilruntime.Must(kubescheme.AddToScheme(scheme))
	utilruntime.Must(batchv1.AddToScheme(scheme))
	utilruntime.Must(jobset.AddToScheme(scheme))

	js := newJobSet("trainjob")
	js.Annotations = map[string]string{
		wellknown.AnnotationJobName:   "trainjob",
		wellknown.AnnotationTimeLimit: "30",
	}
	js.OwnerReferences = []metav1.OwnerReference{
		{
			APIVersion: "trainer.kubeflow.org/v1alpha1",
			Kind:       "TrainJob",
			Name:       "trainjob",
			Controller: ptr.To(true),
		},
	}

	job := newJob("trainjob-launcher-0")
	job.OwnerReferences = []metav1.OwnerReference{
		{
			APIVersion: jobset.GroupVersion.String(),
			Kind:       "JobSet",
			Name:       "trainjob",
			Controller: ptr.To(true),
		},
	}

	pod := newJobPod("trainjob-launcher-0-abcde", "trainjob-launcher-0")
	pod.Labels[jobset.JobSetNameKey] = "trainjob"
	pod.OwnerReferences = []metav1.OwnerReference{
		{
			APIVersion: batchv1.SchemeGroupVersion.String(),
			Kind:       "Job",
			Name:       "trainjob-launcher-0",
			Controller: ptr.To(true),
		},
	}

	c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(js, job, pod).Build()
	got, err := TranslateToSlurmJobIR(c, context.Background(), pod)
	if err != nil {
		t.Fatalf("TranslateToSlurmJobIR() error = %v", err)
	}
	if got.RootPOM.TypeMeta != jobSet_v1alpha2 {
		t.Fatalf("TranslateToSlurmJobIR() root type = %v, want %v", got.RootPOM.TypeMeta, jobSet_v1alpha2)
	}
	if got.RootPOM.Name != "trainjob" {
		t.Fatalf("TranslateToSlurmJobIR() root name = %q, want trainjob", got.RootPOM.Name)
	}
	if got.JobInfo.JobName == nil || *got.JobInfo.JobName != "trainjob" {
		t.Fatalf("TranslateToSlurmJobIR() job name = %v, want trainjob", got.JobInfo.JobName)
	}
	if got.JobInfo.TimeLimit == nil || *got.JobInfo.TimeLimit != 30 {
		t.Fatalf("TranslateToSlurmJobIR() time limit = %v, want 30", got.JobInfo.TimeLimit)
	}
	if len(got.Pods.Items) != 1 || got.Pods.Items[0].Name != pod.Name {
		t.Fatalf("TranslateToSlurmJobIR() pods = %v, want only %s", got.Pods.Items, pod.Name)
	}
}

func Test_translator_fromJobSet(t *testing.T) {
	type fields struct {
		Reader client.Reader
		ctx    context.Context
	}
	type args struct {
		pod     *corev1.Pod
		rootPOM *metav1.PartialObjectMetadata
	}
	tests := []struct {
		name    string
		fields  fields
		args    args
		want    *SlurmJobIR
		wantErr bool
	}{
		{
			name: "JobSet does not exist",
			fields: fields{
				Reader: func() client.Reader {
					scheme := runtime.NewScheme()
					utilruntime.Must(kubescheme.AddToScheme(scheme))
					utilruntime.Must(batchv1.AddToScheme(scheme))
					utilruntime.Must(jobset.AddToScheme(scheme))
					return fake.NewClientBuilder().WithScheme(scheme).WithObjects(
						newJobSet("foo"),
						newJob("foo"),
						newJobPod("foo", "bar"),
					).Build()
				}(),
				ctx: context.Background(),
			},
			args: args{
				pod: newJobPod("foo", "bar"),
				rootPOM: &metav1.PartialObjectMetadata{
					ObjectMeta: metav1.ObjectMeta{
						Name: "bar",
					},
				},
			},
			want:    nil,
			wantErr: true,
		},
		{
			name: "Job does not exist",
			fields: fields{
				Reader: func() client.Reader {
					scheme := runtime.NewScheme()
					utilruntime.Must(kubescheme.AddToScheme(scheme))
					utilruntime.Must(batchv1.AddToScheme(scheme))
					utilruntime.Must(jobset.AddToScheme(scheme))
					return fake.NewClientBuilder().WithScheme(scheme).WithObjects(
						newJobSet("foo"),
						newJob("foo"),
						newJobPod("foo", "bar"),
					).Build()
				}(),
				ctx: context.Background(),
			},
			args: args{
				pod: newJobPod("foo", "bar"),
				rootPOM: &metav1.PartialObjectMetadata{
					ObjectMeta: metav1.ObjectMeta{
						Namespace: metav1.NamespaceDefault,
						Name:      "foo",
					},
				},
			},
			want:    nil,
			wantErr: true,
		},
		{
			name: "JobSet to SlurmJobIR",
			fields: fields{
				Reader: func() client.Reader {
					scheme := runtime.NewScheme()
					utilruntime.Must(kubescheme.AddToScheme(scheme))
					utilruntime.Must(batchv1.AddToScheme(scheme))
					utilruntime.Must(jobset.AddToScheme(scheme))
					return fake.NewClientBuilder().WithScheme(scheme).WithObjects(
						newJobSet("foo"),
						newJob("foo"),
						newJobPod("foo", "foo"),
					).Build()
				}(),
				ctx: context.Background(),
			},
			args: args{
				pod: newJobPod("foo", "foo"),
				rootPOM: &metav1.PartialObjectMetadata{
					ObjectMeta: metav1.ObjectMeta{
						Namespace: metav1.NamespaceDefault,
						Name:      "foo",
					},
				},
			},
			want: &SlurmJobIR{
				JobInfo: SlurmJobIRJobInfo{
					MinNodes:   ptr.To(int32(1)),
					CpuPerTask: ptr.To(int32(22)),
					MemPerNode: ptr.To(int64(1)),
				},
				Pods: corev1.PodList{
					Items: []corev1.Pod{
						*newJobPod("foo", "foo"),
					},
				},
			},
			wantErr: false,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			tr := &translator{
				Reader: tt.fields.Reader,
				ctx:    tt.fields.ctx,
			}
			got, err := tr.fromJobSet(tt.args.pod, tt.args.rootPOM)
			if (err != nil) != tt.wantErr {
				t.Errorf("translator.fromJobSet() error = %v, wantErr %v", err, tt.wantErr)
				return
			}
			if !apiequality.Semantic.DeepEqual(got, tt.want) {
				t.Errorf("translator.fromJobSet() = %v, want %v", got, tt.want)
			}
		})
	}
}
