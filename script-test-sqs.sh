#!/bin/bash
SQS_URL="https://sqs.us-west-1.amazonaws.com/775419744057/evaluation-analytics"
for i in {1..50}; do
  aws sqs send-message --queue-url "$SQS_URL" --message-body "{\"user_id\": \"user-$i\", \"flag_name\": \"enable-new-dashboard\", \"result\": true, \"timestamp\": \"2026-07-14T11:00:00Z\"}" --no-cli-pager
done