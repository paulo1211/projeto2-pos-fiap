import os
import sys
import threading
import json
import uuid
import logging
import boto3
from botocore.config import Config
from botocore.exceptions import NoCredentialsError, ClientError
from flask import Flask, jsonify
from dotenv import load_dotenv
from opentelemetry import propagate, trace
from opentelemetry.instrumentation.utils import suppress_instrumentation
from opentelemetry.trace import SpanKind, Status, StatusCode

# Carrega configuração local antes dos SDKs e clientes.
load_dotenv()

import telemetry

# OpenTelemetry + logging com trace_id/span_id. O botocore instrumentado gera
# spans das chamadas ao DynamoDB/SQS feitas dentro do processamento.
telemetry.setup_telemetry("analytics-service")
telemetry.instrument_botocore()
log = logging.getLogger(__name__)
tracer = trace.get_tracer("analytics-service")



# --- Configuração ---
AWS_REGION = os.getenv("AWS_REGION")
SQS_QUEUE_URL = os.getenv("AWS_SQS_URL")
DYNAMODB_TABLE_NAME = os.getenv("AWS_DYNAMODB_TABLE")

if not all([AWS_REGION, SQS_QUEUE_URL, DYNAMODB_TABLE_NAME]):
    log.critical("Erro: AWS_REGION, AWS_SQS_URL, e AWS_DYNAMODB_TABLE devem ser definidos.")
    sys.exit(1)

# --- Clientes Boto3 ---
# Criamos a sessão uma vez
try:
    session = boto3.Session(region_name=AWS_REGION)
    # Uma tentativa por operação: reentrega SQS trata falhas de processamento.
    # Read timeout do SQS é maior que WaitTimeSeconds=5.
    sqs_client = session.client("sqs", config=Config(
        connect_timeout=2, read_timeout=7,
        retries={"total_max_attempts": 1, "mode": "standard"},
    ))
    dynamodb_client = session.client("dynamodb", config=Config(
        connect_timeout=2, read_timeout=3,
        retries={"total_max_attempts": 1, "mode": "standard"},
    ))
    log.info(f"Clientes Boto3 inicializados na região {AWS_REGION}")
except NoCredentialsError:
    log.critical("Credenciais da AWS não encontradas. Verifique seu ambiente.")
    sys.exit(1)
except Exception as e:
    log.critical(f"Erro ao inicializar o Boto3: {e}")
    sys.exit(1)


# --- SQS Worker ---

def _queue_name():
    return SQS_QUEUE_URL.rstrip("/").rsplit("/", 1)[-1]


def _mark_error(message, error):
    """Marca o span de processamento atual como erro."""
    span = trace.get_current_span()
    span.record_exception(error)
    span.set_status(Status(StatusCode.ERROR, message))


def _trace_context(message):
    """Extrai o contexto W3C (traceparent/tracestate) que o evaluation-service
    injeta nos MessageAttributes, ligando o trace do produtor ao consumidor."""
    carrier = {
        name: attr["StringValue"]
        for name, attr in message.get("MessageAttributes", {}).items()
        if attr.get("DataType") == "String" and "StringValue" in attr
    }
    return propagate.extract(carrier)


def handle_message(message):
    """Processa a mensagem dentro de um span CONSUMER filho do span PRODUCER
    do evaluation-service (mesmo trace distribuído)."""
    with tracer.start_as_current_span(
        f"{_queue_name()} process",
        context=_trace_context(message),
        kind=SpanKind.CONSUMER,
        attributes={
            "messaging.system": "aws_sqs",
            "messaging.operation": "process",
            "messaging.destination.name": _queue_name(),
            "messaging.message.id": message.get("MessageId", ""),
        },
    ):
        process_message(message)


def process_message(message):
    """ Processa uma única mensagem SQS e a insere no DynamoDB """
    try:
        log.info(f"Processando mensagem ID: {message['MessageId']}")
        body = json.loads(message['Body'])
        
        # Gera um ID único para o item no DynamoDB
        event_id = str(uuid.uuid4())
        
        # Constrói o item no formato do DynamoDB
        item = {
            'analytics': {'S': event_id},
            'event_id': {'S': event_id},
            'user_id': {'S': body['user_id']},
            'flag_name': {'S': body['flag_name']},
            'result': {'BOOL': body['result']},
            'timestamp': {'S': body['timestamp']}
        }
        
        # Insere no DynamoDB
        dynamodb_client.put_item(
            TableName=DYNAMODB_TABLE_NAME,
            Item=item
        )
        
        log.info(f"Evento {event_id} (Flag: {body['flag_name']}) salvo no DynamoDB.")
        
        # Se tudo deu certo, deleta a mensagem da fila
        sqs_client.delete_message(
            QueueUrl=SQS_QUEUE_URL,
            ReceiptHandle=message['ReceiptHandle']
        )
        
    except json.JSONDecodeError as e:
        log.error(f"Erro ao decodificar JSON da mensagem ID: {message['MessageId']}")
        _mark_error("JSON inválido", e)
        # Não deleta a mensagem, pode ser uma "poison pill"
    except ClientError as e:
        log.error(f"Erro do Boto3 (DynamoDB ou SQS) ao processar {message['MessageId']}: {e}")
        _mark_error(f"Erro do Boto3: {e}", e)
        # Não deleta a mensagem, tenta novamente
    except Exception as e:
        log.error(f"Erro inesperado ao processar {message['MessageId']}: {e}")
        _mark_error(f"Erro inesperado: {e}", e)
        # Não deleta a mensagem, tenta novamente

def sqs_worker_loop():
    """ Loop principal do worker que ouve a fila SQS """
    log.info("Iniciando o worker SQS...")
    while not _worker_stop.is_set():
        try:
            # Long-polling: espera até 5s por mensagens. O polling em si não
            # gera span (seria um trace "vazio" a cada 5s); os traces começam
            # no processamento de cada mensagem.
            with suppress_instrumentation():
                response = sqs_client.receive_message(
                    QueueUrl=SQS_QUEUE_URL,
                    MaxNumberOfMessages=10,  # Processa em lotes de até 10
                    WaitTimeSeconds=5,
                    # Necessário para receber o traceparent/tracestate.
                    MessageAttributeNames=["All"],
                )
            
            messages = response.get('Messages', [])
            if not messages:
                # Nenhuma mensagem, continua o loop
                continue
                
            log.info(f"Recebidas {len(messages)} mensagens.")
            
            for message in messages:
                if _worker_stop.is_set():
                    # Não deletar: mensagens não iniciadas voltam após visibility timeout.
                    break
                handle_message(message)
                
        except ClientError as e:
            log.error(f"Erro do Boto3 no loop principal do SQS: {e}")
            _worker_stop.wait(10) # Interrompível no encerramento
        except Exception as e:
            log.error(f"Erro inesperado no loop principal do SQS: {e}")
            _worker_stop.wait(10)

# --- Servidor Flask (Apenas para Health Check) ---

app = Flask(__name__)
telemetry.instrument_flask(app)

@app.route('/health')
def health():
    # Uma verificação de saúde real poderia checar a conexão com o DynamoDB/SQS
    return jsonify({"status": "ok"})

# --- Inicialização ---

_worker_stop = threading.Event()
_worker_thread = None


def start_worker():
    """Chamado por post_worker_init do gunicorn ou pelo entrypoint local."""
    global _worker_thread
    if _worker_thread is not None and _worker_thread.is_alive():
        return
    _worker_stop.clear()
    _worker_thread = threading.Thread(target=sqs_worker_loop, daemon=True)
    _worker_thread.start()


def stop_worker(timeout=20):
    """Para novos polls/mensagens e aguarda a operação em andamento."""
    _worker_stop.set()
    if _worker_thread is not None:
        _worker_thread.join(timeout)
        return not _worker_thread.is_alive()
    return True


if __name__ == '__main__':
    start_worker()
    try:
        port = int(os.getenv("PORT", 8005))
        app.run(host='0.0.0.0', port=port, debug=False)
    finally:
        stop_worker()
        telemetry.shutdown_telemetry()
