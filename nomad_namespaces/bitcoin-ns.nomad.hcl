name        = "bitcoin"
description = "Namespace for bitcoin workloads."

capabilities {
  enabled_task_drivers   = ["docker"]
  enabled_network_modes  = ["bridge"]
}