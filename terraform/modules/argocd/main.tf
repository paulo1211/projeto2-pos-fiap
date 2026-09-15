resource "kubernetes_namespace" "argocd" {
  metadata {
    name = var.namespace
  }
}

resource "helm_release" "argocd" {
  name       = "argocd"
  namespace  = kubernetes_namespace.argocd.metadata[0].name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.chart_version

  # LoadBalancer is used so the ArgoCD UI is reachable during the demo video
  # without an extra Ingress controller hop; tighten to ClusterIP + port-forward
  # for anything beyond a study/portfolio environment.
  set {
    name  = "server.service.type"
    value = "LoadBalancer"
  }

  create_namespace = false
}
