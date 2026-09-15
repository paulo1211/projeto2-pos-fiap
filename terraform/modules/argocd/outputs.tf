output "namespace" {
  value = kubernetes_namespace.argocd.metadata[0].name
}

output "release_name" {
  value = helm_release.argocd.name
}
