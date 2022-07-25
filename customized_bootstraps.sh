#!/bin/bash

/etc/eks/bootstrap.sh ${cluster_name} \
  --use-max-pods false --cni-prefix-delegation-enabled \
  --kubelet-extra-args '--max-pods=110'  \
  --container-runtime containerd 