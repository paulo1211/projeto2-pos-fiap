output "namespace" {
  value = kubernetes_namespace.keda.metadata[0].name
}

output "release_name" {
  value = helm_release.keda.name
}
