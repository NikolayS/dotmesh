#!/bin/sh

set -ex

OUT=../yaml

rm -rf $OUT
mkdir -p $OUT

cp etcd-operator-clusterrole.yaml etcd-operator-dep.yaml dotmesh-etcd-cluster.yaml $OUT

if [ -z "$CI_DOCKER_TAG" ]
then
	 # Non-CI build
	 CI_DOCKER_TAG=latest
fi

sed "s/DOCKER_TAG/$CI_DOCKER_TAG/" < dotmesh.yaml > $OUT/dotmesh-k8s-1.7.yaml
sed "s_rbac.authorization.k8s.io/v1beta1_rbac.authorization.k8s.io/v1_"< $OUT/dotmesh-k8s-1.7.yaml > $OUT/dotmesh-k8s-1.8.yaml
sed "s_ClusterIP_LoadBalancer_" < $OUT/dotmesh-k8s-1.8.yaml > $OUT/dotmesh-k8s-1.8.aks.yaml

cp configmap.yaml $OUT/configmap.yaml
sed "s_/usr/libexec/kubernetes/kubelet-plugins/volume/exec_/home/kubernetes/flexvolume_" < configmap.yaml > $OUT/configmap.gke.yaml
sed "s_/usr/libexec/kubernetes/kubelet-plugins/volume/exec_/etc/kubernetes/volumeplugins_" < configmap.yaml > $OUT/configmap.aks.yaml
