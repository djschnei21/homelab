# Token for .github/workflows/reconcile.yml (scripts/reconcile-nomad.sh).
# Apply with a management token. Mint the token on the runner host so the
# secret goes straight into the file the workflow reads:
#
#   nomad acl policy apply -description "CI job reconcile" ci-reconcile nomad_acl/policies/ci-reconcile.hcl
#   (umask 077; mkdir -p ~/.nomad && nomad acl token create -name ci-reconcile -type client \
#     -policy ci-reconcile -t '{{ .SecretID }}' > ~/.nomad/reconcile.token)
#
# The script plans and runs nomad_jobs/ only. It does not apply namespaces,
# register volumes, stop, revert or purge jobs, or read variables.
#
# plan-job and register-job are the Nomad 2.0 split of submit-job, without
# deregister, purge or revert. read-job covers job status, job inspect, alloc
# status, and the eval and deployment monitor that job run waits on. list-jobs
# resolves the job name for status and inspect. read-logs is the failure
# diagnostics. Registering a job that claims a CSI volume (bitcoin-stack,
# prometheus, tailscale-proxy) needs csi-mount-volume and plugin read.

namespace "bitcoin" {
  capabilities = [
    "list-jobs",
    "read-job",
    "plan-job",
    "register-job",
    "read-logs",
    "csi-mount-volume",
  ]
}

namespace "default" {
  capabilities = [
    "list-jobs",
    "read-job",
    "plan-job",
    "register-job",
    "read-logs",
    "csi-mount-volume",
    # plugin-nfs-controller, plugin-nfs-nodes, democratic-csi-iscsi-controller,
    # and democratic-csi-iscsi-nodes carry csi_plugin blocks.
    "csi-register-plugin",
  ]
}

plugin {
  policy = "read"
}

# nomad node status for the RECONCILE_STATUS notice.
node {
  policy = "read"
}
