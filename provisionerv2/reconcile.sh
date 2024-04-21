#!/usr/bin/env bash
# ASSUMES LOGGED INTO APPROPRIATE IBM CLOUD ACCOUNT: TO DO THAT AUTOMATICALLY
# ibmcloud login -a https://cloud.ibm.com --apikey XXXX -r us-south

# ASSUMES LOGGED INTO AZURE ACCOUNT. For methods look at:
# https://learn.microsoft.com/en-us/cli/azure/authenticate-azure-cli
set +x
source config.env
set -x
core_machinegroup_reconcile() {
  HOST_LABELS_VAL=$(echo "$HOST_LABELS" | awk -F '=' '{print $2}')
  WORKER_POOL_WITH_ZONE="${HOST_LABELS_VAL}-$ZONE"
  LABEL_VAL="worker_pool_with_zone=$WORKER_POOL_WITH_ZONE"
	export INSTANCE_DATA=/tmp/instancedata.txt
	if ! gcloud compute instances list --filter "labels.$LABEL_VAL" >$INSTANCE_DATA; then
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
			gcloud compute instances create "$NAME_PREFIX-$(date +%s)" --labels="${LABEL_VAL}" --machine-type=${MACHINE_TYPE} --source-instance-template ${SOURCE_INSTANCE_TEMPLATE} --zone ${ZONE} --metadata-from-file user-data=${IGN_FILE_PATH}
		done
	fi
}

reconcile_cp_nodes() {
	export MACHINE_TYPE="e2-standard-4"
	export SOURCE_INSTANCE_TEMPLATE="satellite-e2e-rhcos"
	export CP_WORKER_ZONE_FILE=/tmp/cp-worker-zones.txt
	jq -r '.workerZones[]' "$LOCATION_DATA_FILE" >"$CP_WORKER_ZONE_FILE"
	ROKS_CLUSTER_COUNT=$(grep "Red Hat OpenShift" "$SERVICES_DATA_FILE" | wc -l)
	export COUNT=0
	if ((ROKS_CLUSTER_COUNT <= 1)); then
		COUNT=2
	elif ((ROKS_CLUSTER_COUNT <= 6)); then
		COUNT=4
	elif ((ROKS_CLUSTER_COUNT <= 12)); then
		COUNT=8
	else
		COUNT=16
	fi
	while read -r zoneraw; do
		export ZONE="$zoneraw"
		export HOST_LABELS="worker-pool=${LOCATION_ID}-cp"
		core_machinegroup_reconcile
		while true; do
			if ! bx sat host assign --location "$LOCATION_ID" --zone "$ZONE" --host-label "zone=$ZONE" --host-label os=RHCOS --host-label "$HOST_LABELS"; then
				break
			fi
			sleep 5
			continue
		done
	done <"$CP_WORKER_ZONE_FILE"
}

reconcile_cluster_wp_nodes() {
	export ROKS_CLUSTER_LIST_FILE=/tmp/roks-cluster-list
	grep "Red Hat OpenShift" "$SERVICES_DATA_FILE" >"$ROKS_CLUSTER_LIST_FILE"
	while read -r line; do
		CLUSTER_ID="$(echo $line | awk '{print $2}')"
		export CLUSTER_WORKER_POOL_INFO_FILE=/tmp/roks-cluster-workerpools.json
		bx cs worker-pools --cluster "$CLUSTER_ID" --output json >"$CLUSTER_WORKER_POOL_INFO_FILE"
		for row in $(cat "$CLUSTER_WORKER_POOL_INFO_FILE" | jq -r '.[] | @base64'); do
			_jq() {
				# shellcheck disable=SC2086
				echo "${row}" | base64 --decode | jq -r ${1}
			}
			export COUNT=$(_jq '.workerCount')
			export SOURCE_INSTANCE_TEMPLATE=$(_jq '.labels["ibm-cloud.kubernetes.io/reconciler-instancetemplate"]')
			export MACHINE_TYPE=$(_jq '.labels["ibm-cloud.kubernetes.io/reconciler-instancetype"]')
			if [[ "$SOURCE_INSTANCE_TEMPLATE" == "null" ]] || [[ "$SOURCE_INSTANCE_TEMPLATE" == "" ]]; then
				echo "bad template value"
				continue
			fi
			if [[ "$MACHINE_TYPE" == "null" ]] || [[ "$MACHINE_TYPE" == "" ]]; then
				echo "bad instance type value"
				continue
			fi
			HOST_LABEL_VALUE=$(_jq '.hostLabels["worker-pool"]')
			OPERATING_SYS=$(_jq '.operatingSystem')
			if [[ "$OPERATING_SYS" != "RHCOS" ]]; then
			  echo "bad operating system"
			  continue
			fi
			if [[ "$HOST_LABEL_VALUE" == "null" ]] || [[ "$HOST_LABEL_VALUE" == "" ]]; then
			  echo "bad host label"
			  continue
			fi
			export HOST_LABELS="worker-pool=${HOST_LABEL_VALUE}"
			zones_in_pool=$(_jq '.zones[]')
			zones_in_pool_file=/tmp/zones-in-pool
			echo "$zones_in_pool" >"$zones_in_pool_file"
			for zonerawinfo in $(cat "$zones_in_pool_file" | jq -r '. | @base64'); do
			  _jq_zonerawinfo() {
          # shellcheck disable=SC2086
          echo "${zonerawinfo}" | base64 --decode | jq -r ${1}
        }
				export ZONE=$(_jq_zonerawinfo '.id')
				core_machinegroup_reconcile
				while true; do
					if ! bx sat host assign --zone "$ZONE"  --location "$LOCATION_ID" --cluster "$CLUSTER_ID" --host-label "zone=$ZONE" --host-label os=RHCOS --host-label "$HOST_LABELS"; then
						break
					fi
					sleep 5
					continue
				done
			done <"$zones_in_pool_file"
		done
	done<"$ROKS_CLUSTER_LIST_FILE"
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
	export LOCATION_DATA_FILE=/tmp/location-data.json
	export HOSTS_DATA_FILE=/tmp/${LOCATION_ID}-hosts-data.txt
	export SERVICES_DATA_FILE=/tmp/${LOCATION_ID}-services-data.txt
	if ! bx sat location get --location $LOCATION_ID --output json >$LOCATION_DATA_FILE; then
		continue
	fi
	if ! bx sat hosts --location $LOCATION_ID --output json >$HOSTS_DATA_FILE; then
		continue
	fi
	if ! bx sat services --location $LOCATION_ID >$SERVICES_DATA_FILE; then
		continue
	fi
	remove_dead_machines
	reconcile_cp_nodes
	reconcile_cluster_wp_nodes
done
