#!/usr/bin/env bash

basename() {
  : "${1%/}"
  printf '%s\n' "${_##*/}"
}

show_help() {
  name=$(basename "${0}")
  cat <<EOF
${name} resets the offsets for every partition in a given BROKER_URI's Kafka consumer
GROUP + TOPIC to the latest (i.e. the end of the current log) in both Kafka and Zookeeper.

Usage:
  ${name} ([--kafka | -k] | [--zookeeper | -z]) GROUP TOPIC BROKER_URI ZOOKEEPER_URI
  ${name} -h | --help | -?

Options:
  -k, --kafka             Only reset offset in Kafka
  -z, --zookeeper         Only reset offset in Zookeeper
  -h, --help, -?          Show this help message
EOF
  exit 0
}

check_kafka_version() {
  KAFKA_BROKER="${1}"

  KAFKA_CMD="ls -l /opt/kafka/current | awk '{print \$NF}' | awk -F- '{print \$NF}'"
  KAFKA_VERSION="$(ssh ${KAFKA_BROKER} -C "${KAFKA_CMD}")"

  KAFKA_MAJOR=$(echo ${KAFKA_VERSION} | awk -F. '{print $1}')
  if [ "${KAFKA_MAJOR}" -eq 0 ]; then
    KAFKA_MINOR=$(echo ${KAFKA_VERSION} | awk -F. '{print $2}')
  fi

  if [ "${KAFKA_MAJOR}" -gt 0 -o "${KAFKA_MINOR}" -gt 10 ]; then
    echo "You seem to be running Kafka v${KAFKA_MAJOR}.${KAFKA_MINOR}"
    echo "This tool should not be necessary if you're using Kafka >= 0.11"
    exit 1
  fi
}

partition_count() {
  KAFKA_TOPIC="${1}"
  KAFKA_BROKER="${2}"
  ZOOKEEPER_URI="${3}"

  KAFKA_CMD="\
/opt/kafka/current/bin/kafka-topics.sh \
  --zookeeper ${ZOOKEEPER_URI} \
  --describe \
  --topic ${KAFKA_TOPIC} \
| awk 'NR==1 {print \$2}' \
| awk -F: '{print \$NF}'"

  ssh ${KAFKA_BROKER} -C "${KAFKA_CMD}"
}

reset_kafka_offsets() {
  KAFKA_GROUP="${1}"
  KAFKA_TOPIC="${2}"
  KAFKA_BROKER="${3}"
  ZOOKEEPER_URI="${4}"

  PARTITION_COUNT=$(partition_count ${KAFKA_TOPIC} ${KAFKA_BROKER} ${ZOOKEEPER_URI})
  ((PARTITION_COUNT--))
  KAFKA_CMD="\
for partition in \$(seq 0 ${PARTITION_COUNT}); do \
  echo -n \"Partition #\${partition}: \"; \
  /opt/kafka/current/bin/kafka-console-consumer.sh \
    --bootstrap-server \$(hostname -I | tr -d ' '):9092 \
    --topic ${KAFKA_TOPIC} \
    --partition \${partition} \
    --consumer-property group.id=${KAFKA_GROUP} \
    --max-messages 0 \
    --offset latest; \
done"

  ssh ${KAFKA_BROKER} -C "${KAFKA_CMD}"
}

get_current_offsets() {
  KAFKA_GROUP="${1}"
  KAFKA_TOPIC="${2}"
  KAFKA_BROKER="${3}"
  ZOOKEEPER_URI="${4}"

  KAFKA_CMD="\
/opt/kafka/current/bin/kafka-consumer-groups.sh \
  --zookeeper ${ZOOKEEPER_URI} \
  --describe \
  --group ${KAFKA_GROUP} \
| awk '\$2 == \"${KAFKA_TOPIC}\" {print \$4}'"

  KAFKA_OFFSETS=""
  for offset in $(ssh ${KAFKA_BROKER} -C "${KAFKA_CMD}"); do
    KAFKA_OFFSETS="${KAFKA_OFFSETS}${offset} "
  done

  echo "${KAFKA_OFFSETS}"
}

zk_get() {
  ZOOKEEPER_URI="${1}"
  ZK_ENDPOINT="${2}"

  zkcli -s ${ZOOKEEPER_URI} get ${ZK_ENDPOINT} 2>/dev/null | head -1
}

reset_zookeeper_offsets() {
  KAFKA_GROUP="${1}"
  KAFKA_TOPIC="${2}"
  KAFKA_BROKER="${3}"
  ZOOKEEPER_URI="${4}"

  LATEST_OFFSETS="$(get_current_offsets ${KAFKA_GROUP} ${KAFKA_TOPIC} ${KAFKA_BROKER} ${ZOOKEEPER_URI})"
  PARTITION=0

  for offset in ${LATEST_OFFSETS}; do
    ZK_ENDPOINT="/consumers/${KAFKA_GROUP}/offsets/${KAFKA_TOPIC}/${PARTITION}"
    OLD_OFFSET="$(zk_get ${ZOOKEEPER_URI} ${ZK_ENDPOINT})"

    zkcli -s ${ZOOKEEPER_URI} set ${ZK_ENDPOINT} ${offset} 2>&1 >/dev/null

    NEW_OFFSET="$(zk_get ${ZOOKEEPER_URI} ${ZK_ENDPOINT})"
    echo "Adjusted offset for partition #${PARTITION}: ${OLD_OFFSET} -> ${NEW_OFFSET}"

    ((PARTITION++))
  done
}

multi_target_warning() {
  echo "Choose only one target! (Use the --kafka | --zookeeper flags)" >&2
  echo "If you're trying to target both, don't pass either flag." >&2
  echo >&2
  show_help
}

# Options parsing
RESET_TARGET="both"
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case $1 in
    -\?|-h|--help)
      show_help
      ;;
    -k|--kafka)
      if [ "${RESET_TARGET}" = "both" ]; then
        RESET_TARGET="kafka"
        shift
      else
        multi_target_warning
      fi
      ;;
    -z|--zookeeper)
      if [ "${RESET_TARGET}" = "both" ]; then
        RESET_TARGET="zookeeper"
        shift
      else
        multi_target_warning
      fi
      ;;
    *)
      POSITIONAL+=("$1")
      shift
  esac
done
set -- "${POSITIONAL[@]}"

require() {
  name="${2:-${1}}"
  command -v "${1}" >/dev/null 2>&1 || {
    printf 'The %s tool is required to use this script!\n' "${name}" >&2
    [[ -z "${3}" ]] || printf '\tSee: %s\n' "${3}" >&2
    exit 1
  }
}

require 'zkcli' 'zkcli' 'https://github.com/let-us-go/zkcli'

[[ $# -ne 4 ]] && show_help

KAFKA_GROUP="${1}"
KAFKA_TOPIC="${2}"
KAFKA_BROKER="${3}"
ZOOKEEPER_URI="${4}"

check_kafka_version ${KAFKA_BROKER}

if [ "${RESET_TARGET}" = "both" -o "${RESET_TARGET}" = "kafka" ]; then
  echo "Resetting offsets in Kafka!"
  reset_kafka_offsets "${KAFKA_GROUP}" "${KAFKA_TOPIC}" "${KAFKA_BROKER}" "${ZOOKEEPER_URI}"
fi

if [ "${RESET_TARGET}" = "both" -o "${RESET_TARGET}" = "zookeeper" ]; then
  if [ "${RESET_TARGET}" = "both" ]; then echo; fi
  echo "Resetting offsets in Zookeeper!"
  reset_zookeeper_offsets "${KAFKA_GROUP}" "${KAFKA_TOPIC}" "${KAFKA_BROKER}" "${ZOOKEEPER_URI}"
fi

exit 0
