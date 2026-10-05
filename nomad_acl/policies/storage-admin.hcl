# This token creates volumes, scales groups to 0, and stops allocations.
# It cannot submit jobs, because a submitted job's workload identity reads
# every variable at nomad/jobs/<job>/<group>/<task>. The copy and holder
# jobs are submitted with the bootstrap token for that reason. The controller
# key and the bitcoind and electrs items are written with the bootstrap token
# too.
#
# Reconcile applies this file from main. Mint a 24h token per session with
# the bootstrap token. Do not write that secret into a workflow file.
#
#   nomad acl token create -name storage-admin -type client -ttl=24h \
#     -policy storage-admin -t '{{ .SecretID }}'
#
# nomad job scale also checks read-job-scaling.

namespace "default" {
  capabilities = [
    "list-jobs",
    "read-job",
    "scale-job",
    "read-job-scaling",
    "alloc-lifecycle",
    "read-logs",
    "csi-write-volume",
    "csi-read-volume",
    "csi-list-volume",
    "csi-mount-volume",
  ]
}

namespace "bitcoin" {
  capabilities = [
    "list-jobs",
    "read-job",
    "scale-job",
    "read-job-scaling",
    "alloc-lifecycle",
    "read-logs",
    "csi-write-volume",
    "csi-read-volume",
    "csi-list-volume",
    "csi-mount-volume",
  ]
}

plugin {
  policy = "read"
}

node {
  policy = "read"
}
