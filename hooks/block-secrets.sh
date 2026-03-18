#!/bin/bash
# Block commands that expose secrets

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.command // empty')

# Block kubectl get secret with -o (outputs secret data)
if echo "$COMMAND" | grep -qE 'kubectl.*get.*secret.*-o'; then
    echo "BLOCKED: Retrieving secret data. Pattern matched: 'kubectl get secret -o'. Never expose secret values."
    exit 1
fi

# Block kubectl get secret with jsonpath (extracts secret data)
if echo "$COMMAND" | grep -qE 'kubectl.*get.*secret.*jsonpath'; then
    echo "BLOCKED: Retrieving secret data. Pattern matched: 'kubectl get secret jsonpath'. Never expose secret values."
    exit 1
fi

# Block kubectl describe secret (shows secret data)
if echo "$COMMAND" | grep -qE 'kubectl.*describe.*secret'; then
    echo "BLOCKED: Describing secrets. Pattern matched: 'kubectl describe secret'. Never expose secret values."
    exit 1
fi

# Block oc get secret with -o
if echo "$COMMAND" | grep -qE 'oc.*get.*secret.*-o'; then
    echo "BLOCKED: Retrieving secret data. Pattern matched: 'oc get secret -o'. Never expose secret values."
    exit 1
fi

# Block oc get secret with jsonpath
if echo "$COMMAND" | grep -qE 'oc.*get.*secret.*jsonpath'; then
    echo "BLOCKED: Retrieving secret data. Pattern matched: 'oc get secret jsonpath'. Never expose secret values."
    exit 1
fi

# Block oc describe secret
if echo "$COMMAND" | grep -qE 'oc.*describe.*secret'; then
    echo "BLOCKED: Describing secrets. Pattern matched: 'oc describe secret'. Never expose secret values."
    exit 1
fi

exit 0
