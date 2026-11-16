#!/usr/bin/env python3
"""Runbook de self-healing do ToggleMaster (Etapa 3).

Recebe o webhook do Grafana Alerting (contact point togglemaster-incident) e,
para cada alerta em "firing" cujo label deployment esteja na allowlist, faz o
equivalente a `kubectl rollout restart deployment/<nome>`: um patch na
annotation kubectl.kubernetes.io/restartedAt do template do pod. Depois
acompanha o rollout até os pods novos ficarem disponíveis.

Segurança:
  - só aceita requisições com "Authorization: Bearer <SELF_HEALING_TOKEN>";
  - só age no namespace TARGET_NAMESPACE e nos deployments ALLOWED_DEPLOYMENTS
    (o RBAC do ServiceAccount repete a mesma restrição);
  - cooldown por deployment evita restart em loop (alert fatigue).

Só usa a biblioteca padrão do Python: roda direto na imagem python:alpine.
"""
import hmac
import json
import logging
import os
import ssl
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = os.environ.get("SELF_HEALING_TOKEN", "")
NAMESPACE = os.environ.get("TARGET_NAMESPACE", "togglemaster")
ALLOWED = {d.strip() for d in os.environ.get("ALLOWED_DEPLOYMENTS", "auth-service").split(",") if d.strip()}
COOLDOWN = int(os.environ.get("COOLDOWN_SECONDS", "300"))
ROLLOUT_TIMEOUT = int(os.environ.get("ROLLOUT_TIMEOUT_SECONDS", "300"))
DISCORD_URL = os.environ.get("DISCORD_WEBHOOK_URL", "")
PORT = int(os.environ.get("PORT", "8080"))

SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
API = "https://{}:{}".format(os.environ.get("KUBERNETES_SERVICE_HOST", "kubernetes.default.svc"),
                             os.environ.get("KUBERNETES_SERVICE_PORT", "443"))
MAX_BODY = 1024 * 1024

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s [self-healing] %(message)s")
log = logging.getLogger("self-healing")

_last_action = {}
_lock = threading.Lock()


def k8s(method, path, body=None, content_type="application/json"):
    """Chamada à API do Kubernetes com o token do ServiceAccount."""
    with open(f"{SA_DIR}/token") as f:  # o kubelet rotaciona o token: lê a cada chamada
        token = f.read().strip()
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, data=data, method=method, headers={
        "Authorization": f"Bearer {token}",
        "Content-Type": content_type,
        "Accept": "application/json",
    })
    ctx = ssl.create_default_context(cafile=f"{SA_DIR}/ca.crt")
    with urllib.request.urlopen(req, context=ctx, timeout=10) as resp:
        return json.load(resp)


def discord(message):
    """Registro da ação no canal do ChatOps (opcional)."""
    if not DISCORD_URL:
        return
    body = json.dumps({"username": "ToggleMaster Self-Healing", "content": message}).encode()
    req = urllib.request.Request(DISCORD_URL, data=body, method="POST",
                                 headers={"Content-Type": "application/json", "User-Agent": "togglemaster-self-healing"})
    try:
        urllib.request.urlopen(req, timeout=10).close()
    except (urllib.error.URLError, OSError) as e:
        log.warning("não foi possível avisar o Discord: %s", e)


def deployment_path(name):
    return f"/apis/apps/v1/namespaces/{NAMESPACE}/deployments/{name}"


def wait_rollout(name, generation, started):
    """Acompanha o rollout (como `kubectl rollout status`)."""
    deadline = time.time() + ROLLOUT_TIMEOUT
    while time.time() < deadline:
        time.sleep(5)
        try:
            dep = k8s("GET", deployment_path(name))
        except (urllib.error.URLError, OSError) as e:
            log.warning("falha ao consultar deployment/%s: %s", name, e)
            continue
        want = dep["spec"].get("replicas", 1)
        st = dep.get("status", {})
        log.info("rollout deployment/%s: %s/%s atualizados, %s disponíveis",
                 name, st.get("updatedReplicas", 0), want, st.get("availableReplicas", 0))
        if (st.get("observedGeneration", 0) >= generation and st.get("updatedReplicas", 0) == want
                and st.get("availableReplicas", 0) == want and st.get("replicas", 0) == want):
            secs = int(time.time() - started)
            log.info("RESULTADO: rollout de deployment/%s concluído em %ss; pods novos disponíveis", name, secs)
            discord(f"✅ Self-healing: `deployment/{name}` reiniciado e saudável em {secs}s "
                    f"({want} pod(s) novo(s)). Aguardando o alerta voltar ao normal.")
            return
    log.error("RESULTADO: rollout de deployment/%s não terminou em %ss; intervenção humana necessária",
              name, ROLLOUT_TIMEOUT)
    discord(f"⚠️ Self-healing: rollout de `deployment/{name}` não terminou em {ROLLOUT_TIMEOUT}s. "
            "Intervenção humana necessária.")


def rollout_restart(name, alertname, value):
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    patch = {"spec": {"template": {"metadata": {"annotations": {
        "kubectl.kubernetes.io/restartedAt": now,
        "self-healing/alert": alertname,
    }}}}}
    log.info("AÇÃO: kubectl rollout restart deployment/%s -n %s (alerta '%s', valor %s)",
             name, NAMESPACE, alertname, value)
    dep = k8s("PATCH", deployment_path(name), patch, "application/strategic-merge-patch+json")
    discord(f"🤖 Self-healing: alerta **{alertname}** (valor {value}) → "
            f"`kubectl rollout restart deployment/{name} -n {NAMESPACE}` executado às {now}.")
    threading.Thread(target=wait_rollout, args=(name, dep["metadata"]["generation"], time.time()),
                     daemon=True).start()


def handle(payload):
    status = payload.get("status")
    alerts = payload.get("alerts") or []
    log.info("notificação recebida: status=%s, %d alerta(s), grupo=%s",
             status, len(alerts), payload.get("groupKey", "-"))
    actions = []
    for alert in alerts:
        labels = alert.get("labels") or {}
        alertname = labels.get("alertname", "?")
        name = labels.get("deployment")
        if alert.get("status") != "firing":
            log.info("alerta '%s' %s: nada a fazer", alertname, alert.get("status"))
            continue
        if labels.get("namespace", NAMESPACE) != NAMESPACE or name not in ALLOWED:
            log.warning("alerta '%s' ignorado: deployment '%s' fora da allowlist %s", alertname, name, sorted(ALLOWED))
            continue
        with _lock:
            elapsed = time.time() - _last_action.get(name, 0)
            if elapsed < COOLDOWN:
                log.info("alerta '%s': deployment/%s reiniciado há %ds (cooldown %ds); sem nova ação",
                         alertname, name, elapsed, COOLDOWN)
                continue
            _last_action[name] = time.time()
        values = alert.get("values") or {}
        value = f"{values['A']:.1f}%" if isinstance(values.get("A"), (int, float)) else alert.get("valueString", "-")
        try:
            rollout_restart(name, alertname, value)
            actions.append(name)
        except urllib.error.HTTPError as e:
            with _lock:
                _last_action.pop(name, None)
            log.error("falha no rollout restart de deployment/%s: HTTP %s %s", name, e.code, e.read()[:300])
        except (urllib.error.URLError, OSError) as e:
            with _lock:
                _last_action.pop(name, None)
            log.error("falha no rollout restart de deployment/%s: %s", name, e)
    return actions


class Handler(BaseHTTPRequestHandler):
    server_version = "togglemaster-self-healing"

    def _reply(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/health":
            self._reply(200, {"status": "ok"})
        else:
            self._reply(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/alert":
            self._reply(404, {"error": "not found"})
            return
        auth = self.headers.get("Authorization", "")
        if not TOKEN or not hmac.compare_digest(auth.encode(), f"Bearer {TOKEN}".encode()):
            log.warning("requisição recusada: token ausente ou inválido (origem %s)", self.client_address[0])
            self._reply(401, {"error": "unauthorized"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = -1
        if length < 0 or length > MAX_BODY:
            self._reply(413, {"error": "payload inválido"})
            return
        try:
            payload = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            self._reply(400, {"error": "JSON inválido"})
            return
        self._reply(200, {"restarted": handle(payload)})

    def log_message(self, fmt, *args):
        pass  # as ações relevantes já são registradas; sem log de acesso das probes


if __name__ == "__main__":
    if not TOKEN:
        log.warning("SELF_HEALING_TOKEN vazio: todas as notificações serão recusadas "
                    "(rode terraform/scripts/sync-alerting-secrets.sh)")
    log.info("ouvindo :%d; namespace=%s; allowlist=%s; cooldown=%ss; discord=%s",
             PORT, NAMESPACE, sorted(ALLOWED), COOLDOWN, "sim" if DISCORD_URL else "não")
    ThreadingHTTPServer(("", PORT), Handler).serve_forever()
