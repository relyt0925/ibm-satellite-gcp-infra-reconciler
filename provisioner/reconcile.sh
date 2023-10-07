#!/usr/bin/env bash
set -x
# ASSUMES LOGGED INTO APPROPRIATE IBM CLOUD ACCOUNT: TO DO THAT AUTOMATICALLY
# ibmcloud login -a https://cloud.ibm.com --apikey XXXX -r us-south

# ASSUMES LOGGED INTO GCLOUD ACCOUNT. For methods look at:
# https://cloud.google.com/container-registry/docs/advanced-authentication

source config.env
core_machinegroup_reconcile() {
	export INSTANCE_DATA=/tmp/instancedata.txt
	if ! gcloud compute instances list --filter "labels.$HOST_LABELS" >$INSTANCE_DATA; then
		continue
	fi
	TOTAL_INSTANCES=$(cat $INSTANCE_DATA | wc -l)
	if ((TOTAL_INSTANCES > 0)); then
		#remove header from count
		TOTAL_INSTANCES=$((TOTAL_INSTANCES - 1))
	fi
	if ((COUNT > TOTAL_INSTANCES)); then
		NUMBER_TO_SCALE=$((COUNT - TOTAL_INSTANCES))
		if [[ -n "$HOST_LINK_AGENT_ENDPOINT" ]]; then
			IGN_FILE_PATH=$(bx sat host attach --location "$LOCATION_ID" --operating-system "RHCOS" --host-label "$HOST_LABELS" --host-link-agent-endpoint "$HOST_LINK_AGENT_ENDPOINT" | grep "register-host")
		else
			IGN_FILE_PATH=$(bx sat host attach --location "$LOCATION_ID" --operating-system "RHCOS" --host-label "$HOST_LABELS" | grep "register-host")
		fi
		if [[ "$IGN_FILE_PATH" != *".ign" ]]; then
			return
		fi
		NAME_PREFIX="sat"
		for i in $(seq 1 $NUMBER_TO_SCALE); do
			gcloud compute instances create "$NAME_PREFIX-$(date +%s)" --labels="${HOST_LABELS}" --machine-type=${MACHINE_TYPE} --source-instance-template ${SOURCE_INSTANCE_TEMPLATE} --zone ${ZONE} --metadata-from-file user-data=${IGN_FILE_PATH}
		done
	fi
}

remove_dead_machines() {
	for row in $(cat "$HOSTS_DATA_FILE" | jq -r '.[] | @base64'); do
		_jq() {
			# shellcheck disable=SC2086
			echo "${row}" | base64 --decode | jq -r ${1}
		}
		HEALTH_STATE=$(_jq '.health.status')
		NAME=$(_jq '.name')
		if [[ "$HEALTH_STATE" == "reload-required" ]]; then
			INSTANCE_DATA_FILE_PATH=/tmp/rminstancedata.json
			NAME_IN_GCE=$(echo "$NAME" | awk -F '.' '{print $1}')
			ZONE_IN_GCE=$(echo "$NAME" | awk -F '.' '{print $2}')
			if ! gcloud compute instances list --filter name=$NAME_IN_GCE >$INSTANCE_DATA_FILE_PATH; then
				continue
			fi
			if grep "$NAME_IN_GCE" $INSTANCE_DATA_FILE_PATH; then
				if ! gcloud compute instances delete $NAME_IN_GCE --zone "$ZONE_IN_GCE" --quiet; then
					continue
				fi
			fi
			ibmcloud sat host rm --location "$LOCATION_ID" --host "$NAME" -f
		fi
	done
}

while true; do
	sleep 10
	echo "reconcile workload"
	export LOCATION_LIST_FILE=/tmp/location-lists.txt
	export HOSTS_DATA_FILE=/tmp/${LOCATION_ID}-hosts-data.txt
	export SERVICES_DATA_FILE=/tmp/${LOCATION_ID}-services-data.txt
	if ! bx sat locations >$LOCATION_LIST_FILE; then
		continue
	fi
	if ! grep "$LOCATION_ID" /tmp/location-lists.txt; then
		if [[ -n "$LOCATION_ZONE_1" ]] && [[ -n "$LOCATION_ZONE_2" ]] && [[ -n "$LOCATION_ZONE_3" ]]; then
			bx sat location create --name "$LOCATION_ID" --coreos-enabled --managed-from "$MANAGED_FROM_LOCATION" \
				--ha-zone "$LOCATION_ZONE_1" --ha-zone "$LOCATION_ZONE_2" --ha-zone "$LOCATION_ZONE_3"
		else
			bx sat location create --name "$LOCATION_ID" --coreos-enabled --managed-from "$MANAGED_FROM_LOCATION"
		fi
	fi
	if ! bx sat hosts --location $LOCATION_ID --output json >$HOSTS_DATA_FILE; then
		continue
	fi
	if ! bx sat services --location $LOCATION_ID >$SERVICES_DATA_FILE; then
		continue
	fi
	remove_dead_machines
	for FILE in worker-pool-metadata/*/*; do
		CLUSTERID=$(echo ${FILE} | awk -F '/' '{print $(NF-1)}')
		if [[ "$FILE" == *"control-plane"* ]]; then
			source $FILE
			core_machinegroup_reconcile
			# ensure machines assigned
			while true; do
				if ! bx sat host assign --location "$LOCATION_ID" --zone "$ZONE" --host-label os=RHCOS --host-label "$HOST_LABELS"; then
					break
				fi
				sleep 5
				continue
			done
		else
			CLUSTERID=$(echo ${FILE} | awk -F '/' '{print $(NF-1)}')
			WORKER_POOL_NAME=$(echo ${FILE} | awk -F '/' '{print $NF}' | awk -F '.' '{print $1}')
			source $FILE
			if ! grep $CLUSTERID $SERVICES_DATA_FILE; then
				if ! bx cs cluster create satellite --name $CLUSTERID --location "$LOCATION_ID" --version "$DOWNSTREAM_CLUSTER_OC_VERSION" --operating-system RHCOS; then
					continue
				fi
			fi
			WORKER_POOL_FILE=/tmp/worker-pool-info.txt
			if ! bx cs worker-pools --cluster $CLUSTERID >$WORKER_POOL_FILE; then
				continue
			fi
			if ! grep "$WORKER_POOL_NAME" $WORKER_POOL_FILE; then
				bx cs worker-pool create satellite --name $WORKER_POOL_NAME --cluster $CLUSTERID --zone ${ZONE} --size-per-zone "$COUNT" --host-label "$HOST_LABELS" --operating-system RHCOS
			fi
			if ! bx cs worker-pool resize --cluster $CLUSTERID --worker-pool $WORKER_POOL_NAME --size-per-zone "$COUNT"; then
				continue
			fi
			core_machinegroup_reconcile
			while true; do
				if ! bx sat host assign --location "$LOCATION_ID" --cluster "$CLUSTERID" --host-label os=RHCOS --host-label "$HOST_LABELS"; then
					break
				fi
				sleep 5
				continue
			done
		fi
	done
done
