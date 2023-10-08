#!/usr/bin/env bash

set -euo pipefail

NUM_OF_NODES="${1}"
RUN_CT="${2:-true}"
LISTEN="${LISTEN:-"0.0.0.0"}"
SSL="${SSL:-false}"
V6ONLY="${V6ONLY:-false}"

destroy() {
    local NAME
    for idx in $(seq 1 "${NUM_OF_NODES}"); do
        NAME="n${idx}.${DOCKER_NET}"
        echo "Destroying $NAME"
        docker rm -f "${NAME}" 2> /dev/null
    done
}

if [ -z "${DOCKER_NET:-}" ]; then
    echo "\$DOCKER_NET is not specified, creating a network for it"
    echo "You may also choose to create a docker net"
    echo "e.g."
    echo "docker network create gen.rpc"
    echo "docker network create --ipv6 --subnet 2001:0DB8::/112 gen.rpc"
    echo "NOTE: the network must have at least one dot in its name"
    export DOCKER_NET="gen.rpc"
    destroy
    docker network rm $DOCKER_NET || true
    if [ "$LISTEN" = '::' ]; then
        docker network create --ipv6 --subnet 2001:0DB8::/112 $DOCKER_NET
    else
        docker network create $DOCKER_NET
    fi
fi

DOCKER_RUN_ARGS="-d --network $DOCKER_NET"

if [ -z "${DOCKER_IMAGE:-}" ]; then
    ## The default image name in Makefile 'docker' target
    DOCKER_IMAGE="genrpc"
fi

CLUSTER_NODES=""
for idx in $(seq 1 "${NUM_OF_NODES}"); do
    CLUSTER_NODES="n${idx}.${DOCKER_NET}:$CLUSTER_NODES"
done

start_node() {
    local NAME="n${1}.${DOCKER_NET}"
    local IS_CT="${2}"
    echo "Starting ${NAME}..."
    # shellcheck disable=SC2086
    docker run --name "${NAME}" $DOCKER_RUN_ARGS "$DOCKER_IMAGE" bash -c 'sleep 6000'
    docker exec "${NAME}" bash -c 'echo -n "cookie1" > ~/.erlang.cookie'
    docker exec "${NAME}" bash -c 'chmod 600 ~/.erlang.cookie'
    docker exec -d "${NAME}" epmd -daemon
    PROJ_ROOT="$(docker exec "${NAME}" pwd | tr -d '\r')"
    local SCRIPT_FILE='test/integration/set_app_env.escript'
    if [ "$IS_CT" = 'no_dont_run_ct' ]; then
        docker exec -d \
            -e PROJ_ROOT="${PROJ_ROOT}" \
            -e TEST_WITH_SOCKET_IP="${LISTEN}" \
            -e TEST_WITH_IPV6ONLY="${V6ONLY}" \
            -e TEST_WITH_SSL="${SSL}" \
            "${NAME}" \
            bash -c "rebar3 as test shell --name gen_rpc@${NAME} --script ${SCRIPT_FILE} > shell.log"
    else
        docker exec \
            -e PROJ_ROOT="${PROJ_ROOT}" \
            -e TEST_WITH_SOCKET_IP="${LISTEN}" \
            -e TEST_WITH_IPV6ONLY="${V6ONLY}" \
            -e TEST_WITH_SSL="${SSL}" \
            -e CLUSTER_NODES="${CLUSTER_NODES}" \
            "${NAME}" \
            bash -c "rebar3 ct --name gen_rpc@${NAME} --suite test/integration_suite"
    fi
}

run_ct() {
    destroy
    for idx in $(seq 2 "${NUM_OF_NODES}"); do
        start_node "$idx" 'no_dont_run_ct'
    done
    start_node 1 'yes_run_ct'
}

if [ "$RUN_CT" = 'true' ]; then
    trap destroy EXIT
    run_ct
else
    ## keep the nodes running so we can manually attach to the nodes
    destroy
    for idx in $(seq 1 "${NUM_OF_NODES}"); do
        start_node "$idx" 'no_dont_run_ct'
    done
fi
