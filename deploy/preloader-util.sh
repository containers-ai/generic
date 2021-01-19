#!/usr/bin/env bash

#################################################################################################################
#
#   This script is created for demo purpose.
#   Usage:
#       [-p] # Prepare environment
#           Requirement:
#                [-a cluster_name] # Specify cluster name
#       [-c] # clean environment for preloader test
#       [-e] # Enable preloader pod
#       [-r] # Run preloader (normal mode: historical + current)
#       [-o] # Run preloader (historical + ab test)
#       [-f future data point (hour)] # Run preloader future mode
#       [-d] # Disable & Remove preloader
#       [-v] # Revert environment to normal mode
#       [-n nginx_prefix_name] # Specify nginx prefix name (optional)
#       [-h] # Display script usage
#   Standalone options:
#       [-i] # Install Nginx
#       [-k] # Remove Nginx
#       [-b] # Retrigger ab test inside preloader pod
#       [-g ab_traffic_ratio] # ab test traffic ratio (default:4000) [e.g., -g 4000]
#       [-t replica number] # Nginx default replica number (default:5) [e.g., -t 5]
#
#################################################################################################################

show_usage()
{
    cat << __EOF__

    Usage:
        [-p] # Prepare environment
            Requirement:
                [-a cluster_name] # Specify cluster name
        [-c] # clean environment for preloader test
        [-e] # Enable preloader pod
        [-r] # Run preloader (normal mode: historical + current)
        [-o] # Run preloader (historical + ab test)
        [-f future data point (hour)] # Run preloader future mode
        [-d] # Disable & Remove preloader
        [-v] # Revert environment to normal mode
        [-n nginx_prefix_name] # Specify nginx prefix name (optional)
        [-h] # Display script usage
    Standalone options:
        [-i] # Install Nginx
        [-k] # Remove Nginx
        [-b] # Retrigger ab test inside preloader pod
        [-g ab_traffic_ratio] # ab test traffic ratio (default:4000) [e.g., -g 4000]
        [-t replica number] # Nginx default replica number (default:5) [e.g., -t 5]

__EOF__
    exit 1
}

pods_ready()
{
  [[ "$#" == 0 ]] && return 0

  namespace="$1"

  kubectl get pod -n $namespace \
    -o=jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' |egrep -v "\-build|\-deploy"\
      | while read name status _junk; do
          if [ "$status" != "True" ]; then
            echo "Waiting for pod $name in namespace $namespace to be ready..."
            return 1
          fi
        done || return 1

  return 0
}

leave_prog()
{
    scale_up_pods
    if [ ! -z "$(ls -A $file_folder)" ]; then      
        echo -e "\n$(tput setaf 6)Downloaded YAML files are located under $file_folder $(tput sgr 0)"
    fi
 
    cd $current_location > /dev/null
}

check_version()
{
    openshift_required_minor_version="9"
    k8s_required_version="11"

    oc version 2>/dev/null|grep "oc v"|grep -q " v[4-9]"
    if [ "$?" = "0" ];then
        # oc version is 4-9, passed
        openshift_minor_version="12"
        return 0
    fi

    # OpenShift Container Platform 4.x
    oc version 2>/dev/null|grep -q "Server Version: 4"
    if [ "$?" = "0" ];then
        # oc server version is 4, passed
        openshift_minor_version="12"
        return 0
    fi

    oc version 2>/dev/null|grep "oc v"|grep -q " v[0-2]"
    if [ "$?" = "0" ];then
        # oc version is 0-2, failed
        echo -e "\n$(tput setaf 10)Error! OpenShift version less than 3.$openshift_required_minor_version is not supported by Federator.ai$(tput sgr 0)"
        exit 5
    fi

    # oc major version = 3
    openshift_minor_version=`oc version 2>/dev/null|grep "oc v"|cut -d '.' -f2`
    # k8s version = 1.x
    k8s_version=`kubectl version 2>/dev/null|grep Server|grep -o "Minor:\"[0-9]*.\""|tr ':+"' " "|awk '{print $2}'`

    if [ "$openshift_minor_version" != "" ] && [ "$openshift_minor_version" -lt "$openshift_required_minor_version" ]; then
        echo -e "\n$(tput setaf 10)Error! OpenShift version less than 3.$openshift_required_minor_version is not supported by Federator.ai$(tput sgr 0)"
        exit 5
    elif [ "$openshift_minor_version" = "" ] && [ "$k8s_version" != "" ] && [ "$k8s_version" -lt "$k8s_required_version" ]; then
        echo -e "\n$(tput setaf 10)Error! Kubernetes version less than 1.$k8s_required_version is not supported by Federator.ai$(tput sgr 0)"
        exit 6
    elif [ "$openshift_minor_version" = "" ] && [ "$k8s_version" = "" ]; then
        echo -e "\n$(tput setaf 10)Error! Can't get Kubernetes or OpenShift version$(tput sgr 0)"
        exit 5
    fi
}


wait_until_pods_ready()
{
  period="$1"
  interval="$2"
  namespace="$3"
  target_pod_number="$4"

  wait_pod_creating=1
  for ((i=0; i<$period; i+=$interval)); do

    if [[ "$wait_pod_creating" = "1" ]]; then
        # check if pods created
        if [[ "`kubectl get po -n $namespace 2>/dev/null|wc -l`" -ge "$target_pod_number" ]]; then
            wait_pod_creating=0
            echo -e "\nChecking pods..."
        else
            echo "Waiting for pods in namespace $namespace to be created..."
        fi
    else
        # check if pods running
        if pods_ready $namespace; then
            echo -e "\nAll $namespace pods are ready."
            return 0
        fi
        echo "Waiting for pods in namespace $namespace to be ready..."
    fi

    sleep "$interval"
    
  done

  echo -e "\n$(tput setaf 1)Warning!! Waited for $period seconds, but all pods are not ready yet. Please check $namespace namespace$(tput sgr 0)"
  leave_prog
  exit 4
}

wait_until_data_pump_finish()
{
  period="$1"
  interval="$2"
  type="$3"

  for ((i=0; i<$period; i+=$interval)); do
    if [ "$type" = "future" ]; then
        echo "Waiting for data pump (future mode) to finish ..."
        kubectl logs -n $install_namespace $current_preloader_pod_name | grep -q "Completed to loader container future metrics data"
        if [ "$?" = "0" ]; then
            echo -e "\n$(tput setaf 6)The data pump (future mode) is finished.$(tput sgr 0)"
            return 0
        fi
    else #historical mode
        echo "Waiting for data pump to finish ..."
        if [[ "`kubectl logs -n $install_namespace $current_preloader_pod_name | egrep "Succeed to generate pods historical metrics|Succeed to generate nodes historical metrics" | wc -l`" -gt "1" ]]; then
            echo -e "\n$(tput setaf 6)The data pump is finished.$(tput sgr 0)"
            return 0
        fi
    fi
    
    sleep "$interval"
  done

  echo -e "\n$(tput setaf 1)Warning!! Waited for $period seconds, but the data pump is still running.$(tput sgr 0)"
  leave_prog
  exit 4
}

get_current_preloader_name()
{
    current_preloader_pod_name=""
    current_preloader_pod_name="`kubectl get pods -n $install_namespace |grep "federatorai-agent-preloader-"|awk '{print $1}'|head -1`"
    echo "current_preloader_pod_name = $current_preloader_pod_name"
}

get_current_executor_name()
{
    current_executor_pod_name="`kubectl get pods -n $install_namespace |grep "alameda-executor-"|awk '{print $1}'|head -1`"
    echo "current_executor_pod_name = $current_executor_pod_name"
}

delete_all_alamedascaler()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Deleting old alamedascaler if necessary...$(tput sgr 0)"
    while read _scaler_name _cluster_name _scaler_ns
    do
        if [ "$_scaler_name" = "" ] || [ "$_cluster_name" = "" ] || [ "$_scaler_ns" = "" ]; then
           continue
        fi

        if [ "$_scaler_name" = "$_cluster_name" ]; then
            # Ignore cluster-only alamedascaler
            continue
        fi

        kubectl delete alamedascaler $_scaler_name -n $_scaler_ns
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error in deleting old alamedascaler named $_scaler_name in ns $_scaler_ns.$(tput sgr 0)"
            leave_prog
            exit 8
        fi
    done <<< "$(kubectl get alamedascaler --all-namespaces --output jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.clusterName}{" "}{.metadata.namespace}{"\n"}' 2>/dev/null)"
    echo "Done"
    end=`date +%s`
    duration=$((end-start))
    echo "Duration delete_all_alamedascaler = $duration" >> $debug_log
}

wait_for_cluster_status_data_ready()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Checking cluster status...$(tput sgr 0)"
    influxdb_pod_name="`kubectl get pods -n $install_namespace |grep "alameda-influxdb-"|awk '{print $1}'|head -1`"
    repeat_count="30"
    sleep_interval="20"
    pass="n"
    for i in $(seq 1 $repeat_count)
    do
        kubectl exec $influxdb_pod_name -n $install_namespace -- influx -ssl -unsafeSsl -precision rfc3339 -username admin -password adminpass -database alameda_cluster_status -execute "select * from pod" 2>/dev/null |grep -q "${alamedascaler_name}"
        if [ "$?" != 0 ]; then
            echo "Not ready, keep retrying cluster status..."
            sleep $sleep_interval
        else
            pass="y"
            break
        fi
    done
    if [ "$pass" = "n" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to find alamedascaler ($alamedascaler_name) status in alameda_cluster_status measurement.$(tput sgr 0)"
        leave_prog
        exit 8
    fi

    echo "Done."
    end=`date +%s`
    duration=$((end-start))
    echo "Duration wait_for_cluster_status_data_ready = $duration" >> $debug_log
}

refine_preloader_variables_with_alamedaservice()
{
    ## Assign preloader environment variables
    local _env_list=""
    if [ "${PRELOADER_GRANULARITY}" != "" ]; then
        echo -e "\nSetting variable PRELOADER_GRANULARITY='${PRELOADER_GRANULARITY}'"
        _env_list="${_env_list}
    - name: PRELOADER_PRELOADER_GRANULARITY
      value: \"${PRELOADER_GRANULARITY}\"  # unit is sec, history preloaded data granularity
"
    fi
    if [ "${PRELOADER_PRELOAD_COUNT}" != "" ]; then
        echo -e "Setting variable PRELOADER_PRELOAD_COUNT='${PRELOADER_PRELOAD_COUNT}'"
        _env_list="${_env_list}
    - name: PRELOADER_PRELOADER_PRELOAD_COUNT
      value: \"${PRELOADER_PRELOAD_COUNT}\"
"
    fi
    if [ "${PRELOADER_PRELOAD_UNIT}" != "" ]; then
        echo -e "Setting variable PRELOADER_PRELOAD_UNIT='${PRELOADER_PRELOAD_UNIT}'"
        _env_list="${_env_list}
    - name: PRELOADER_PRELOADER_PRELOAD_UNIT
      value: \"${PRELOADER_PRELOAD_UNIT}\"    # "month"/"day"/"hour"/"minute"
"
    fi
    if [ "${_env_list}" != "" ]; then
        patch_data="
spec:
  federatoraiAgentPreloader:
    env:${_env_list}
"
        echo -e "\nPatching alamedaservice for enabling environment variables of preloader ..."
        kubectl patch alamedaservice ${alamedaservice_name} -n ${install_namespace} --type merge --patch "${patch_data}"
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error! Failed in patching AlamedaService.$(tput sgr 0)"
            exit 1
        fi
        # restart preloader pod
        get_current_preloader_name
        [ "${current_preloader_pod_name}" != "" ] && kubectl -n $install_namespace delete pod $current_preloader_pod_name --wait=true
    fi
}

run_ab_test()
{
    echo -e "\n$(tput setaf 6)Running ab test in preloader...$(tput sgr 0)"

    get_current_preloader_name
    if [ "$current_preloader_pod_name" = "" ]; then
        echo -e "\n$(tput setaf 1)ERROR! Can't find installed preloader pod.$(tput sgr 0)"
        leave_prog
        exit 8
    fi

    # Modify parameters
    nginx_ip=$(kubectl -n $nginx_ns get svc|grep "${nginx_name}"|awk '{print $3}')
    [ "$nginx_ip" = "" ] && echo -e "$(tput setaf 1)Error! Can't get svc ip of namespace $nginx_ns$(tput sgr 0)" && return

    sed -i "s/SVC_IP=.*/SVC_IP=${nginx_ip}/g" $preloader_folder/generate_loads.sh
    sed -i "s/SVC_PORT=.*/SVC_PORT=${nginx_port}/g" $preloader_folder/generate_loads.sh
    sed -i "s/traffic_ratio.*/traffic_ratio = ${traffic_ratio}/g" $preloader_folder/define.py

    for ab_file in "${ab_files_list[@]}"
    do
        kubectl cp -n $install_namespace $preloader_folder/$ab_file ${current_preloader_pod_name}:/opt/alameda/federatorai-agent/
    done
    # New traffic folder
    kubectl -n $install_namespace exec $current_preloader_pod_name -- mkdir -p /opt/alameda/federatorai-agent/traffic
    # trigger ab test
    kubectl -n $install_namespace exec $current_preloader_pod_name -- bash -c "bash /opt/alameda/federatorai-agent/generate_loads.sh >run_output 2>run_output &"
    if [ "$?" != "0" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to trigger ab test inside preloader.$(tput sgr 0)"
    fi
    echo "Done."
}

run_preloader_command()
{
    running_mode="$1"
    if [ "$running_mode" = "historical_only" ]; then
        # Need to change data adapter to collect metrics
        patch_data_adapter_for_preloader "false"
    elif [ "$running_mode" = "normal" ]; then
        # collect meta data only
        patch_data_adapter_for_preloader "true"
    fi
    # Move scale_down inside run_preloader_command, just in case we need to patch data adapter (historical_only mode)
    scale_down_pods

    # check env is ready
    wait_for_cluster_status_data_ready

    start=`date +%s`
    echo -e "\n$(tput setaf 6)Running preloader in $running_mode mode...$(tput sgr 0)"
    get_current_preloader_name
    if [ "$current_preloader_pod_name" = "" ]; then
        echo -e "\n$(tput setaf 1)ERROR! Can't find installed preloader pod.$(tput sgr 0)"
        leave_prog
        exit 8
    fi

    if [ "$running_mode" = "historical_only" ]; then
        kubectl exec -n $install_namespace $current_preloader_pod_name -- /opt/alameda/federatorai-agent/bin/transmitter loadhistoryonly --state=true
    fi

    kubectl exec -n $install_namespace $current_preloader_pod_name -- /opt/alameda/federatorai-agent/bin/transmitter enable
    if [ "$?" != "0" ]; then
        echo -e "\n$(tput setaf 1)Error in executing preloader enable command.$(tput sgr 0)"
        leave_prog
        exit 8
    fi
    echo "Checking..."
    sleep 20
    kubectl logs -n $install_namespace $current_preloader_pod_name | grep -i "Start PreLoader agent"
    if [ "$?" != "0" ]; then
        echo -e "\n$(tput setaf 1)Preloader pod is not running correctly. Please contact support staff$(tput sgr 0)"
        leave_prog
        exit 5
    fi

    if [ "$running_mode" = "historical_only" ]; then
        run_ab_test
    fi

    wait_until_data_pump_finish 3600 60 "historical"
    echo "Done."
    end=`date +%s`
    duration=$((end-start))
    echo "Duration run_preloader_command in $running_mode mode = $duration" >> $debug_log
}

run_futuremode_preloader()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Running future mode preloader...$(tput sgr 0)"
    get_current_preloader_name
    if [ "$current_preloader_pod_name" = "" ]; then
        echo -e "\n$(tput setaf 1)ERROR! Can't find installed preloader pod.$(tput sgr 0)"
        leave_prog
        exit 8
    fi
    
    kubectl exec -n $install_namespace $current_preloader_pod_name -- /opt/alameda/federatorai-agent/bin/transmitter loadfuture --hours=$future_mode_length
    if [ "$?" != "0" ]; then
        echo -e "\n$(tput setaf 1)Error in executing preloader loadfuture command.$(tput sgr 0)"
        leave_prog
        exit 8
    fi

    echo "Checking..."
    sleep 10
    wait_until_data_pump_finish 3600 60 "future"
    echo "Done."
    end=`date +%s`
    duration=$((end-start))
    echo "Duration run_futuremode_preloader = $duration" >> $debug_log
}

scale_down_pods()
{
    echo -e "\n$(tput setaf 6)Scaling down alameda-ai and alameda-ai-dispatcher ...$(tput sgr 0)"
    original_alameda_ai_replicas="`kubectl get deploy alameda-ai -n $install_namespace -o jsonpath='{.spec.replicas}'`"
    # Bring down federatorai-operator to prevent it start scale down pods automatically
    kubectl patch deployment federatorai-operator -n $install_namespace -p '{"spec":{"replicas": 0}}'
    kubectl patch deployment alameda-ai -n $install_namespace -p '{"spec":{"replicas": 0}}'
    kubectl patch deployment alameda-ai-dispatcher -n $install_namespace -p '{"spec":{"replicas": 0}}'
    kubectl patch deployment $restart_recommender_deploy -n $install_namespace -p '{"spec":{"replicas": 0}}'
    echo "Done"
}

scale_up_pods()
{
    echo -e "\n$(tput setaf 6)Scaling up alameda-ai and alameda-ai-dispatcher ...$(tput sgr 0)"
    if [ "`kubectl get deploy alameda-ai -n $install_namespace -o jsonpath='{.spec.replicas}'`" -eq "0" ]; then
        if [ "$original_alameda_ai_replicas" != "" ]; then
            kubectl patch deployment alameda-ai -n $install_namespace -p "{\"spec\":{\"replicas\": $original_alameda_ai_replicas}}"
        else
            kubectl patch deployment alameda-ai -n $install_namespace -p '{"spec":{"replicas": 1}}'
        fi
        do_something="y"
    fi

    if [ "`kubectl get deploy alameda-ai-dispatcher -n $install_namespace -o jsonpath='{.spec.replicas}'`" -eq "0" ]; then
        kubectl patch deployment alameda-ai-dispatcher -n $install_namespace -p '{"spec":{"replicas": 1}}'
        do_something="y"
    fi

    if [ "`kubectl get deploy $restart_recommender_deploy -n $install_namespace -o jsonpath='{.spec.replicas}'`" -eq "0" ]; then
        kubectl patch deployment $restart_recommender_deploy -n $install_namespace -p '{"spec":{"replicas": 1}}'
        do_something="y"
    fi

    if [ "`kubectl get deploy federatorai-operator -n $install_namespace -o jsonpath='{.spec.replicas}'`" -eq "0" ]; then
        kubectl patch deployment federatorai-operator -n $install_namespace -p '{"spec":{"replicas": 1}}'
        do_something="y"
    fi

    if [ "$do_something" = "y" ]; then
        wait_until_pods_ready 600 30 $install_namespace 5
    fi
    echo "Done"
}

reschedule_dispatcher()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Rescheduling alameda-ai dispatcher...$(tput sgr 0)"
    current_dispatcher_pod_name="`kubectl get pods -n $install_namespace |grep "alameda-ai-dispatcher-"|awk '{print $1}'|head -1`"
    if [ "$current_dispatcher_pod_name" = "" ]; then
        echo -e "\n$(tput setaf 1)ERROR! Can't find alameda-ai dispatcher pod.$(tput sgr 0)"
        leave_prog
        exit 8
    fi

    kubectl delete pod -n $install_namespace $current_dispatcher_pod_name
    if [ "$?" != "0" ]; then
        echo -e "\n$(tput setaf 1)Error in deleting dispatcher pod.$(tput sgr 0)"
        leave_prog
        exit 8
    fi
    echo ""
    wait_until_pods_ready 600 30 $install_namespace 5
    echo "Done."
    end=`date +%s`
    duration=$((end-start))
    echo "Duration reschedule_dispatcher = $duration" >> $debug_log

}

patch_data_adapter_for_preloader()
{
    only_mode="$1"
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Updating data adapter (collect metadata only mode to $only_mode) for preloader...$(tput sgr 0)"

    kubectl get alamedaservice $alamedaservice_name -n $install_namespace -o yaml|grep "\- name: COLLECT_METADATA_ONLY" -A1|grep -q $only_mode
    if [ "$?" != "0" ]; then
        kubectl patch alamedaservice $alamedaservice_name -n $install_namespace --type merge --patch "{\"spec\":{\"federatoraiDataAdapter\":{\"env\":[{\"name\": \"COLLECT_METADATA_ONLY\",\"value\": \"$only_mode\"}]}}}"
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error in updating data adapter to collect_metadata_only = \"$only_mode\" mode.$(tput sgr 0)"
            leave_prog
            exit 8
        fi
        echo ""
        wait_until_pods_ready 600 30 $install_namespace 5
    fi

    # kubectl -n $install_namespace get configmap federatorai-data-adapter-config -o yaml | grep -E -q "^[[:blank:]]+collect_metadata_only = $only_mode"
    # if [ "$?" != "0" ]; then
    #     if [ "$only_mode" = "true" ]; then
    #         # Set collect_metadata_only = true
    #         kubectl -n $install_namespace get configmap federatorai-data-adapter-config -o yaml |sed "s/collect_metadata_only = false/collect_metadata_only = true/g" |kubectl apply -f -
    #     else
    #         # Set collect_metadata_only = false
    #         kubectl -n $install_namespace get configmap federatorai-data-adapter-config -o yaml |sed "s/collect_metadata_only = true/collect_metadata_only = false/g" |kubectl apply -f -
    #     fi

    #     if [ "$?" != "0" ]; then
    #         echo -e "\n$(tput setaf 1)Error in updating data adapter to collect_metadata_only = \"$only_mode\" mode.$(tput sgr 0)"
    #         leave_prog
    #         exit 8
    #     fi
    #     wait_until_pods_ready 600 30 $install_namespace 5
    # fi

    echo "Done."
    end=`date +%s`
    duration=$((end-start))
    echo "Duration patch_data_adapter_for_preloader = $duration" >> $debug_log
}

patch_datahub_for_preloader()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Updating datahub for preloader...$(tput sgr 0)"
    kubectl get alamedaservice $alamedaservice_name -n $install_namespace -o yaml|grep "\- name: ALAMEDA_DATAHUB_APIS_METRICS_SOURCE" -A1|grep -q influxdb
    if [ "$?" != "0" ]; then
        kubectl patch alamedaservice $alamedaservice_name -n $install_namespace --type merge --patch '{"spec":{"alamedaDatahub":{"env":[{"name": "ALAMEDA_DATAHUB_APIS_METRICS_SOURCE","value": "influxdb"}]}}}'
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error in updating datahub pod.$(tput sgr 0)"
            leave_prog
            exit 8
        fi
        echo ""
        wait_until_pods_ready 600 30 $install_namespace 5
    fi
    echo "Done"
    end=`date +%s`
    duration=$((end-start))
    echo "Duration patch_datahub_for_preloader = $duration" >> $debug_log
}

patch_datahub_back_to_normal()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Rolling back datahub...$(tput sgr 0)"
    kubectl get alamedaservice $alamedaservice_name -n $install_namespace -o yaml|grep "\- name: ALAMEDA_DATAHUB_APIS_METRICS_SOURCE" -A1|grep -q prometheus
    if [ "$?" != "0" ]; then
        kubectl patch alamedaservice $alamedaservice_name -n $install_namespace --type merge --patch '{"spec":{"alamedaDatahub":{"env":[{"name": "ALAMEDA_DATAHUB_APIS_METRICS_SOURCE","value": "prometheus"}]}}}'
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error in rolling back datahub pod.$(tput sgr 0)"
            leave_prog
            exit 8
        fi
        echo ""
        wait_until_pods_ready 600 30 $install_namespace 5
    fi
    echo "Done"
    end=`date +%s`
    duration=$((end-start))
    echo "Duration patch_datahub_back_to_normal = $duration" >> $debug_log
}

check_influxdb_retention()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Checking retention policy...$(tput sgr 0)"
    influxdb_pod_name="`kubectl get pods -n $install_namespace |grep "alameda-influxdb-"|awk '{print $1}'|head -1`"
    kubectl exec $influxdb_pod_name -n $install_namespace -- influx -ssl -unsafeSsl -precision rfc3339 -username admin -password adminpass -database alameda_metric -execute "show retention policies"|grep "autogen"|grep -q "3600h"
    if [ "$?" != "0" ]; then
        echo -e "\n$(tput setaf 1)Error! retention policy of alameda_metric pod is not 3600h.$(tput sgr 0)"
        leave_prog
        exit 8
    fi
    echo "Done"
    end=`date +%s`
    duration=$((end-start))
    echo "Duration check_influxdb_retention = $duration" >> $debug_log
}

patch_grafana_for_preloader()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Adding flag for grafana ...$(tput sgr 0)"
    influxdb_pod_name="`kubectl get pods -n $install_namespace |grep "alameda-influxdb-"|awk '{print $1}'|head -1`"
    kubectl exec $influxdb_pod_name -n $install_namespace -- influx -ssl -unsafeSsl -precision rfc3339 -username admin -password adminpass -database alameda_metric -execute "select * from grafana_config order by time desc limit 1" 2>/dev/null|grep -q true
    if [ "$?" != "0" ]; then
        kubectl exec $influxdb_pod_name -n $install_namespace -- influx -ssl -unsafeSsl -precision rfc3339 -username admin -password adminpass -execute "show databases" |grep -q "alameda_metric"
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error! Can't find alameda_metric in influxdb.$(tput sgr 0)"
            leave_prog
            exit 8
        fi
        kubectl exec $influxdb_pod_name -n $install_namespace -- influx -ssl -unsafeSsl -precision rfc3339 -username admin -password adminpass -database alameda_metric -execute "insert grafana_config preloader=true"
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error! Adding flag for grafana failed.$(tput sgr 0)"
            leave_prog
            exit 8
        fi
    fi
    echo "Done"
    end=`date +%s`
    duration=$((end-start))
    echo "Duration patch_grafana_for_preloader = $duration" >> $debug_log
}

patch_grafana_back_to_normal()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Adding flag to roll back grafana ...$(tput sgr 0)"
    influxdb_pod_name="`kubectl get pods -n $install_namespace |grep "alameda-influxdb-"|awk '{print $1}'|head -1`"
    kubectl exec $influxdb_pod_name -n $install_namespace -- influx -ssl -unsafeSsl -precision rfc3339 -username admin -password adminpass -database alameda_metric -execute "select * from grafana_config order by time desc limit 1" 2>/dev/null|grep -q false
    if [ "$?" != "0" ]; then
        kubectl exec $influxdb_pod_name -n $install_namespace -- influx -ssl -unsafeSsl -precision rfc3339 -username admin -password adminpass -execute "show databases" |grep -q "alameda_metric"
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error! Can't find alameda_metric in influxdb.$(tput sgr 0)"
            leave_prog
            exit 8
        fi
        kubectl exec $influxdb_pod_name -n $install_namespace -- influx -ssl -unsafeSsl -precision rfc3339 -username admin -password adminpass -database alameda_metric -execute "insert grafana_config preloader=false"
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error! Adding flag to roll back grafana failed.$(tput sgr 0)"
            leave_prog
            exit 8
        fi
    fi
    echo "Done"
    end=`date +%s`
    duration=$((end-start))
    echo "Duration patch_grafana_back_to_normal = $duration" >> $debug_log
}

verify_metrics_exist()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Verifying metrics in influxdb ...$(tput sgr 0)"
    metricsArray=("container_cpu" "container_memory" "namespace_cpu" "namespace_memory" "node_cpu" "node_memory")
    metrics_required_number=`echo "${#metricsArray[@]}"`
    influxdb_pod_name="`kubectl get pods -n $install_namespace |grep "alameda-influxdb-"|awk '{print $1}'|head -1`"
    metrics_list=$(kubectl exec $influxdb_pod_name -n $install_namespace -- influx -ssl -unsafeSsl -precision rfc3339 -username admin -password adminpass -database alameda_metric -execute "show measurements")
    metrics_num_found="0"
    for i in $(seq 0 $((metrics_required_number-1)))
    do
        echo $metrics_list|grep -q "${metricsArray[$i]}"
        if [ "$?" = "0" ]; then
            metrics_num_found=$((metrics_num_found+1))
        fi
    done

    if [ "$metrics_num_found" -lt "$metrics_required_number" ]; then
        echo -e "\n$(tput setaf 1)Error! metrics in alameda_metric is not complete.$(tput sgr 0)"
        echo "=============================="
        echo "Required metrics number: $metrics_required_number"
        echo "Required metrics: ${metricsArray[*]}"
        echo "=============================="
        echo "Required metrics found = $metrics_num_found"
        echo "Current metrics:"
        echo "$metrics_list"
        echo "=============================="
        leave_prog
        exit 8
    fi
    echo "Done"
    end=`date +%s`
    duration=$((end-start))
    echo "Duration verify_metrics_exist = $duration" >> $debug_log
}

delete_nginx_example()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Deleting NGINX sample ...$(tput sgr 0)"
    dc_name="`kubectl get dc -n $nginx_ns 2>/dev/null|grep -v "NAME"|awk '{print $1}'`"
    if [ "$dc_name" != "" ]; then
        kubectl delete dc $dc_name -n $nginx_ns
    fi
    deploy_name="`kubectl get deploy -n $nginx_ns 2>/dev/null|grep -v "NAME"|awk '{print $1}'`"
    if [ "$deploy_name" != "" ]; then
        kubectl delete deploy $deploy_name -n $nginx_ns
    fi
    kubectl get ns $nginx_ns >/dev/null 2>&1
    if [ "$?" = "0" ]; then
        kubectl delete ns $nginx_ns
    fi
    echo "Done"
    end=`date +%s`
    duration=$((end-start))
    echo "Duration delete_nginx_example = $duration" >> $debug_log
}

new_nginx_example()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Creating a new NGINX sample pod ...$(tput sgr 0)"

    if [[ "`kubectl get po -n $nginx_ns 2>/dev/null|grep -v "NAME"|grep "Running"|wc -l`" -gt "0" ]]; then
        echo "nginx-preloader-sample namespace and pod already exist."
    else
        if [ "$openshift_minor_version" != "" ]; then
            # OpenShift
            nginx_openshift_yaml="nginx_openshift.yaml"
            cat > ${nginx_openshift_yaml} << __EOF__
{
    "kind": "List",
    "apiVersion": "v1",
    "metadata": {},
    "items": [
        {
            "apiVersion": "apps.openshift.io/v1",
            "kind": "DeploymentConfig",
            "metadata": {
                "labels": {
                    "app": "${nginx_name}"
                },
                "name": "${nginx_name}"
            },
            "spec": {
                "replicas": ${replica_number},
                "selector": {
                    "app": "${nginx_name}",
                    "deploymentconfig": "${nginx_name}"
                },
                "strategy": {
                    "resources": {},
                    "rollingParams": {
                        "intervalSeconds": 1,
                        "maxSurge": "25%",
                        "maxUnavailable": "25%",
                        "timeoutSeconds": 600,
                        "updatePeriodSeconds": 1
                    },
                    "type": "Rolling"
                },
                "template": {
                    "metadata": {
                        "labels": {
                            "app": "${nginx_name}",
                            "deploymentconfig": "${nginx_name}"
                        }
                    },
                    "spec": {
                        "containers": [
                            {
                                "image": "twalter/openshift-nginx:stable-alpine",
                                "imagePullPolicy": "IfNotPresent",
                                "name": "${nginx_name}",
                                "ports": [
                                    {
                                        "containerPort": ${nginx_port},
                                        "protocol": "TCP"
                                    }
                                ],
                                "resources":
                                {
                                    "limits":
                                        {
                                        "cpu": "200m",
                                        "memory": "20Mi"
                                        },
                                    "requests":
                                        {
                                        "cpu": "100m",
                                        "memory": "10Mi"
                                        }
                                },
                                "terminationMessagePath": "/dev/termination-log"
                            }
                        ],
                        "dnsPolicy": "ClusterFirst",
                        "restartPolicy": "Always",
                        "securityContext": {},
                        "terminationGracePeriodSeconds": 30
                    }
                }
            }
        },
        {
            "apiVersion": "v1",
            "kind": "Service",
            "metadata": {
                "labels": {
                    "app": "${nginx_name}"
                },
                "name": "${nginx_name}"
            },
            "spec": {
                "ports": [
                    {
                        "name": "http",
                        "port": ${nginx_port},
                        "protocol": "TCP",
                        "targetPort": ${nginx_port}
                    }
                ],
                "selector": {
                    "app": "${nginx_name}",
                    "deploymentconfig": "${nginx_name}"
                }
            }
        },
        {
            "apiVersion": "route.openshift.io/v1",
            "kind": "Route",
            "metadata": {
                "labels": {
                    "app": "${nginx_name}"
                },
                "name": "${nginx_name}"
            },
            "spec": {
                "port": {
                    "targetPort": ${nginx_port}
                },
                "to": {
                    "kind": "Service",
                    "name": "${nginx_name}"
                },
                "weight": 100,
                "wildcardPolicy": "None"
            }
        }
    ]
}
__EOF__
            oc new-project $nginx_ns
            oc apply -f ${nginx_openshift_yaml}
            if [ "$?" != "0" ]; then
                echo -e "\n$(tput setaf 1)Error! create NGINX app failed.$(tput sgr 0)"
                leave_prog
                exit 8
            fi
            echo ""
            wait_until_pods_ready 600 30 $nginx_ns 1
            oc project $install_namespace
        else
            # K8S
            nginx_k8s_yaml="nginx_k8s.yaml"
            cat > ${nginx_k8s_yaml} << __EOF__
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${nginx_name}
  namespace: ${nginx_ns}
  labels:
     app: ${nginx_name}
spec:
  selector:
    matchLabels:
      app: ${nginx_name}
  replicas: ${replica_number}
  template:
    metadata:
      labels:
        app: ${nginx_name}
    spec:
      containers:
      - name: ${nginx_name}
        image: nginx:1.7.9
        resources:
            limits:
                cpu: "200m"
                memory: "20Mi"
            requests:
                cpu: "100m"
                memory: "10Mi"
        ports:
        - containerPort: ${nginx_port}
      serviceAccountName: ${nginx_name}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${nginx_name}
rules:
- apiGroups:
  - policy
  resources:
  - podsecuritypolicies
  verbs:
  - use
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${nginx_name}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ${nginx_name}
subjects:
- kind: ServiceAccount
  name: ${nginx_name}
  namespace: ${nginx_ns}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${nginx_name}
  namespace: ${nginx_ns}
__EOF__
            kubectl create ns $nginx_ns
            kubectl apply -f $nginx_k8s_yaml
            if [ "$?" != "0" ]; then
                echo -e "\n$(tput setaf 1)Error! create NGINX app failed.$(tput sgr 0)"
                leave_prog
                exit 8
            fi
            echo ""
            wait_until_pods_ready 600 30 $nginx_ns 1
        fi
    fi
    echo "Done."
    end=`date +%s`
    duration=$((end-start))
    echo "Duration new_nginx_example = $duration" >> $debug_log
}

get_datadog_agent_info()
{
    while read a b c
    do
        dd_namespace=$a
        dd_key=$b
        dd_api_secret_name=$c
        if [ "$dd_namespace" != "" ] && [ "$dd_key" != "" ] && [ "$dd_api_secret_name" != "" ]; then
           break
        fi
    done<<<"$(kubectl get daemonset --all-namespaces -o jsonpath='{range .items[*]}{@.metadata.namespace}{"\t"}{range .spec.template.spec.containers[*]}{.env[?(@.name=="DD_API_KEY")].name}{"\t"}{.env[?(@.name=="DD_API_KEY")].valueFrom.secretKeyRef.name}{"\n"}{end}{"\t"}{end}' 2>/dev/null| grep "DD_API_KEY")"

    if [ "$dd_key" = "" ] || [ "$dd_namespace" = "" ] || [ "$dd_api_secret_name" = "" ]; then
        return
    fi
    dd_api_key="`kubectl get secret -n $dd_namespace $dd_api_secret_name -o jsonpath='{.data.api-key}'`"
    dd_app_key="`kubectl get secret -n $dd_namespace -o jsonpath='{range .items[*]}{.data.app-key}'`"
    dd_cluster_agent_deploy_name="$(kubectl get deploy -n $dd_namespace |grep -v NAME|awk '{print $1}'|grep "cluster-agent$")"
    dd_cluster_name="$(kubectl get deploy $dd_cluster_agent_deploy_name -n $dd_namespace -o jsonpath='{range .spec.template.spec.containers[*]}{.env[?(@.name=="DD_CLUSTER_NAME")].value}' 2>/dev/null | awk '{print $1}')"
}

get_datasource_in_alamedaorganization()
{
    # ##Get cluster specific data source setting
    # data_source_type="$(kubectl get alamedaorganization -o jsonpath="{range .items[*]}{.spec.clusters[?(@.name==\"$cluster_name\")].dataSource.type}")"
    # if [ "$data_source_type" != "" ]; then
    #     return
    # fi

    # Get global data source setting
    data_source_type="$(kubectl get alamedaorganization -o jsonpath='{range .items[*]}{.spec.dataSource.type}')"
    if [ "$data_source_type" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to find global data source setting in alamedaorganization CR.$(tput sgr 0)"
        echo -e "$(tput setaf 1)Remember to set up alamedaorganization before running preloader.$(tput sgr 0)"
        exit 3
    fi
}

# 4.4 will handle local cluster automatically
# add_dd_tags_to_executor_env()
# {
#     start=`date +%s`
#     echo -e "\n$(tput setaf 6)Adding dd tags to executor env...$(tput sgr 0)"
#     if [ "$cluster_name" = "" ]; then
#         echo -e "\n$(tput setaf 1)Error! Cluster name can't be empty. Use option '-a' to specify cluster name$(tput sgr 0)"
#         show_usage
#         exit 3
#     fi
#     kubectl patch alamedaservice $alamedaservice_name -n ${install_namespace} --type merge --patch "{\"spec\":{\"alamedaExecutor\":{\"env\":[{\"name\": \"ALAMEDA_EXECUTOR_CLUSTERNAME\",\"value\": \"$cluster_name\"}]}}}"
#     if [ "$?" != "0" ]; then
#         echo -e "\n$(tput setaf 1)Error! Failed to set ALAMEDA_EXECUTOR_CLUSTERNAME as alamedaExecutor env.$(tput sgr 0)"
#         leave_prog
#         exit 8
#     fi

#     echo "Done"
#     end=`date +%s`
#     duration=$((end-start))
#     echo "Duration add_dd_tags_to_executor_env = $duration" >> $debug_log
# }

check_cluster_name_not_empty()
{
    if [ "$cluster_name" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Cluster name can't be empty. Use option '-a' to specify cluster name$(tput sgr 0)"
        echo -e "$(tput setaf 1)You can look up cluster name info by following command: $(tput sgr 0)"
        echo -e "$(tput setaf 1)kubectl -n <Federator.ai namespace> get alamedascaler$(tput sgr 0)"
        show_usage
        exit 3
    fi
}

add_alamedascaler_for_nginx()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Adding NGINX alamedascaler ...$(tput sgr 0)"
    check_cluster_name_not_empty
    nginx_alamedascaler_file="nginx_alamedascaler_file"

    if [ "$openshift_minor_version" = "" ]; then
        # K8S
        kind_type="Deployment"
    else
        # OpenShift
        kind_type="DeploymentConfig"
    fi

    kubectl get alamedascaler -n ${install_namespace} 2>/dev/null|grep -q "$alamedascaler_name"
    if [ "$?" != "0" ]; then
        cat > ${nginx_alamedascaler_file} << __EOF__
apiVersion: autoscaling.containers.ai/v1alpha2
kind: AlamedaScaler
metadata:
    name: ${alamedascaler_name}
    namespace: ${install_namespace}
spec:
    clusterName: ${cluster_name}
    controllers:
    - type: generic
      enableExecution: ${enable_execution}
      scaling: ${autoscaling_method}
      evictable: true
      generic:
        target:
          namespace: ${nginx_ns}
          name: ${nginx_name}
          kind: ${kind_type}
        hpaParameters:
          maxReplicas: 40
          minReplicas: 1
__EOF__
        kubectl apply -f ${nginx_alamedascaler_file}
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error! Add alamedascaler for NGINX app failed.$(tput sgr 0)"
            leave_prog
            exit 8
        fi
        sleep 10
    fi
    echo "Done"
    end=`date +%s`
    duration=$((end-start))
    echo "Duration add_alamedascaler_for_nginx = $duration" >> $debug_log
}

cleanup_influxdb_prediction_related_contents()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Cleaning old influxdb prediction/recommendation/planning records ...$(tput sgr 0)"
    influxdb_pod_name="`kubectl get pods -n $install_namespace |grep "alameda-influxdb-"|awk '{print $1}'|head -1`"
    for database in alameda_prediction alameda_recommendation alameda_planning alameda_fedemeter
    do
        echo "database=$database"
        # prepare sql command
        m_list=""
        sql_cmd=""
        measurement_list="`kubectl exec $influxdb_pod_name -n $install_namespace -- influx -ssl -unsafeSsl -precision rfc3339 -username admin -password adminpass -database $database -execute "show measurements" 2>&1 |tail -n+4`"
        for measurement in `echo $measurement_list`
        do
            m_list="${m_list} ${measurement}"
            sql_cmd="${sql_cmd}drop measurement $measurement;"
        done
        if [ "${m_list}" != "" ]; then
            echo "cleaning up measurements: ${m_list}"
            kubectl exec $influxdb_pod_name -n $install_namespace -- influx -ssl -unsafeSsl -precision rfc3339 -username admin -password adminpass -database $database -execute "${sql_cmd}" | grep -v "^$"
        fi
    done
    echo "Done."
    end=`date +%s`
    duration=$((end-start))
    echo "Duration cleanup_influxdb_prediction_related_contents = $duration" >> $debug_log
}

cleanup_alamedaai_models()
{
    start=`date +%s`
    #/var/lib/alameda/alameda-ai/models/online/workload_prediction
    echo -e "\n$(tput setaf 6)Cleaning old alameda ai model ...$(tput sgr 0)"
    for ai_pod_name in `kubectl get pods -n $install_namespace -o jsonpath='{range .items[*]}{"\n"}{.metadata.name}'|grep alameda-ai-|grep -v dispatcher`
    do
        kubectl exec $ai_pod_name -n $install_namespace -- rm -rf /var/lib/alameda/alameda-ai/models/online/workload_prediction
    done
    echo "Done."
    end=`date +%s`
    duration=$((end-start))
    echo "Duration cleanup_alamedaai_models = $duration" >> $debug_log
}

cleanup_influxdb_preloader_related_contents()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Cleaning old influxdb preloader metrics records ...$(tput sgr 0)"
    influxdb_pod_name="`kubectl get pods -n $install_namespace |grep "alameda-influxdb-"|awk '{print $1}'|head -1`"
    
    measurement_list="`kubectl exec $influxdb_pod_name -n $install_namespace -- influx -ssl -unsafeSsl -precision rfc3339 -username admin -password adminpass -database alameda_metric -execute "show measurements" 2>&1 |tail -n+4`"
    echo "database=alameda_metric"
    # prepare sql command
    m_list=""
    for measurement in `echo $measurement_list`
    do
        if [ "$measurement" = "grafana_config" ]; then
            continue
        fi
        m_list="${m_list} ${measurement}"
        sql_cmd="${sql_cmd}drop measurement $measurement;"
    done
    if [ "${m_list}" != "" ]; then
        echo "cleaning up measurements: ${m_list}"
        kubectl exec $influxdb_pod_name -n $install_namespace -- influx -ssl -unsafeSsl -precision rfc3339 -username admin -password adminpass -database alameda_metric -execute "${sql_cmd}" | grep -v "^$"
    fi

    echo "Done."
    end=`date +%s`
    duration=$((end-start))
    echo "Duration cleanup_influxdb_preloader_related_contents = $duration" >> $debug_log
}

check_prediction_status()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Checking the prediction status of monitored objects ...$(tput sgr 0)"
    influxdb_pod_name="`kubectl get pods -n $install_namespace |grep "alameda-influxdb-"|awk '{print $1}'|head -1`"
    measurements_list="`oc exec alameda-influxdb-54949c7c-jp4lk -- influx -ssl -unsafeSsl -precision rfc3339 -username admin -password adminpass -database alameda_cluster_status -execute "show measurements"|tail -n+4`"
    for measurement in `echo $measurements_list`
    do
        record_number="`oc exec $influxdb_pod_name -- influx -ssl -unsafeSsl -precision rfc3339 -username admin -password adminpass -database alameda_cluster_status -execute "select count(*) from $measurement"|tail -1|awk '{print $NF}'`"
        echo "$measurement = $xx"
        case $future_mode_length in
                ''|*[!0-9]*) echo -e "\n$(tput setaf 1)future mode length (hour) needs to be an integer.$(tput sgr 0)" && show_usage ;;
                *) ;;
        esac

        re='^[0-9]+$'
        if ! [[ $xx =~ $re ]] ; then
            echo "error: Not a number" >&2; exit 1
        else
            yy=$(($yy + $xx))
        fi
    done
    end=`date +%s`
    duration=$((end-start))
    echo "Duration check_prediction_status() = $duration" >> $debug_log
}

check_deployment_status()
{
    period="$1"
    interval="$2"
    deploy_name="$3"
    deploy_status_expected="$4"

    for ((i=0; i<$period; i+=$interval)); do
        kubectl -n $install_namespace get deploy $deploy_name >/dev/null 2>&1
        if [ "$?" = "0" ] && [ "$deploy_status_expected" = "on" ]; then
            echo -e "Depolyment $deploy_name exists."
            return 0
        elif [ "$?" != "0" ] && [ "$deploy_status_expected" = "off" ]; then
            echo -e "Depolyment $deploy_name is gone."
            return 0
        fi
        echo "Waiting for deployment $deploy_name become expected status ($deploy_status_expected)..."
        sleep "$interval"
    done
    echo -e "\n$(tput setaf 1)Error!! Waited for $period seconds, but deployment $deploy_name status is not ($deploy_status_expected).$(tput sgr 0)"
    leave_prog
    exit 7
}

# switch_alameda_executor_in_alamedaservice()
# {
#     start=`date +%s`
#     switch_option="$1"
#     get_current_executor_name
#     modified="n"
#     if [ "$current_executor_pod_name" = "" ] && [ "$switch_option" = "on" ]; then
#         # Turn on
#         echo -e "\n$(tput setaf 6)Enabling executor in alamedaservice...$(tput sgr 0)"
#         kubectl patch alamedaservice $alamedaservice_name -n $install_namespace --type merge --patch '{"spec":{"enableExecution": true}}'
#         if [ "$?" != "0" ]; then
#             echo -e "\n$(tput setaf 1)Error in enabling executor pod.$(tput sgr 0)"
#             leave_prog
#             exit 8
#         fi
#         modified="y"
#         check_deployment_status 180 10 "alameda-executor" "on"
#     elif [ "$current_executor_pod_name" != "" ] && [ "$switch_option" = "off" ]; then
#         # Turn off
#         echo -e "\n$(tput setaf 6)Disable executor in alamedaservice...$(tput sgr 0)"
#         kubectl patch alamedaservice $alamedaservice_name -n $install_namespace --type merge --patch '{"spec":{"enableExecution": false}}'
#         if [ "$?" != "0" ]; then
#             echo -e "\n$(tput setaf 1)Error in deleting preloader pod.$(tput sgr 0)"
#             leave_prog
#             exit 8
#         fi
#         modified="y"
#         check_deployment_status 180 10 "alameda-executor" "off"
#     fi

#     if [ "$modified" = "y" ]; then
#         echo ""
#         wait_until_pods_ready 600 30 $install_namespace 5
#     fi

#     get_current_executor_name
#     if [ "$current_executor_pod_name" = "" ] && [ "$switch_option" = "on" ]; then
#         echo -e "\n$(tput setaf 1)ERROR! Can't find executor pod.$(tput sgr 0)"
#         leave_prog
#         exit 8
#     elif [ "$current_executor_pod_name" != "" ] && [ "$switch_option" = "off" ]; then
#         echo -e "\n$(tput setaf 1)ERROR! Executor pod still exists as $current_executor_pod_name.$(tput sgr 0)"
#         leave_prog
#         exit 8
#     fi

#     echo "Done"
#     end=`date +%s`
#     duration=$((end-start))
#     echo "Duration switch_alameda_executor_in_alamedaservice = $duration" >> $debug_log
# }

enable_preloader_in_alamedaservice()
{
    start=`date +%s`

    # Refine variables before running preloader
    refine_preloader_variables_with_alamedaservice

    get_current_preloader_name
    if [ "$current_preloader_pod_name" != "" ]; then
        echo -e "\n$(tput setaf 6)Skip preloader installation due to preloader pod exists.$(tput sgr 0)"
        echo -e "Deleting preloader pod to renew the pod state..."
        kubectl delete pod -n $install_namespace $current_preloader_pod_name
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error in deleting preloader pod.$(tput sgr 0)"
            leave_prog
            exit 8
        fi
    else
        echo -e "\n$(tput setaf 6)Enabling preloader in alamedaservice...$(tput sgr 0)"
        kubectl patch alamedaservice $alamedaservice_name -n $install_namespace --type merge --patch '{"spec":{"enablePreloader": true}}'
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error in updating alamedaservice $alamedaservice_name.$(tput sgr 0)"
            leave_prog
            exit 8
        fi
    fi
    # Check if preloader is ready
    check_deployment_status 180 10 "federatorai-agent-preloader" "on"
    echo ""
    wait_until_pods_ready 600 30 $install_namespace 5
    get_current_preloader_name
    if [ "$current_preloader_pod_name" = "" ]; then
        echo -e "\n$(tput setaf 1)ERROR! Can't find installed preloader pod.$(tput sgr 0)"
        leave_prog
        exit 8
    fi
    echo "Done"
    end=`date +%s`
    duration=$((end-start))
    echo "Duration enable_preloader_in_alamedaservice = $duration" >> $debug_log
}

add_svc_for_nginx()
{
    # K8S only
    if [ "$openshift_minor_version" = "" ]; then
        start=`date +%s`
        echo -e "\n$(tput setaf 6)Adding svc for NGINX ...$(tput sgr 0)"

        # Check if svc already exist
        kubectl get svc ${nginx_name} -n $nginx_ns &>/dev/null
        if [ "$?" = "0" ]; then
            echo "svc already exists in namespace $nginx_ns"
            echo "Done"
            return
        fi

        nginx_svc_yaml="nginx_svc.yaml"
        cat > ${nginx_svc_yaml} << __EOF__
apiVersion: v1
kind: Service
metadata:
  name: ${nginx_name}
  namespace: ${nginx_ns}
  labels:
    app: ${nginx_name}
spec:
  type: NodePort
  ports:
  - port: ${nginx_port}
    nodePort: 31020
    targetPort: ${nginx_port}
    protocol: TCP
    name: http
  selector:
    app: ${nginx_name}
__EOF__

        kubectl apply -f $nginx_svc_yaml
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error! Apply NGINX svc yaml failed.$(tput sgr 0)"
            leave_prog
            exit 8
        fi

        echo "Done"
        end=`date +%s`
        duration=$((end-start))
        echo "Duration add_svc_for_nginx = $duration" >> $debug_log
    fi
}

check_recommendation_pod_type()
{
    dispatcher_type_deploy_name="federatorai-recommender-dispatcher"
    non_dispatcher_type_deploy_name="alameda-recommender"
    kubectl -n $install_namespace get deploy $dispatcher_type_deploy_name >/dev/null 2>&1
    if [ "$?" = "0" ]; then
        # federatorai-recommender-worker and federatorai-recommender-dispatcher
        restart_recommender_deploy=$dispatcher_type_deploy_name
    else
        # alameda-recommender
        restart_recommender_deploy=$non_dispatcher_type_deploy_name
    fi
}

disable_preloader_in_alamedaservice()
{
    start=`date +%s`
    echo -e "\n$(tput setaf 6)Disabling preloader in alamedaservice...$(tput sgr 0)"
    get_current_preloader_name
    if [ "$current_preloader_pod_name" != "" ]; then
        kubectl patch alamedaservice $alamedaservice_name -n $install_namespace  --type merge --patch '{"spec":{"enablePreloader": false}}'
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error in updating alamedaservice $alamedaservice_name.$(tput sgr 0)"
            leave_prog
            exit 8
        fi

        # Check if preloader is removed and other pods are ready
        check_deployment_status 180 10 "federatorai-agent-preloader" "off"
        echo ""
        wait_until_pods_ready 600 30 $install_namespace 5
        get_current_preloader_name
        if [ "$current_preloader_pod_name" != "" ]; then
            echo -e "\n$(tput setaf 1)ERROR! Can't stop preloader pod.$(tput sgr 0)"
            leave_prog
            exit 8
        fi
    fi
    echo "Done"
    end=`date +%s`
    duration=$((end-start))
    echo "Duration disable_preloader_in_alamedaservice = $duration" >> $debug_log
}

clean_environment_operations()
{
    cleanup_influxdb_preloader_related_contents
    cleanup_influxdb_prediction_related_contents
    cleanup_alamedaai_models
}

if [ "$#" -eq "0" ]; then
    show_usage
    exit
fi

while getopts "f:n:t:s:x:g:cdehikprvoba:" o; do
    case "${o}" in
        p)
            prepare_environment="y"
            ;;
        i)
            install_nginx="y"
            ;;
        k)
            remove_nginx="y"
            ;;
        c)
            clean_environment="y"
            ;;
        e)
            enable_preloader="y"
            ;;
        b)
            run_ab_from_preloader="y"
            ;;
        r)
            run_preloader_with_normal_mode="y"
            ;;
        o)
            run_preloader_with_historical_only="y"
            ;;
        f)
            future_mode_enabled="y"
            f_arg=${OPTARG}
            ;;
        t)
            replica_num_specified="y"
            t_arg=${OPTARG}
            ;;
        s)
            enable_execution_specified="y"
            s_arg=${OPTARG}
            ;;
        a)
            cluster_name_specified="y"
            a_arg=${OPTARG}
            ;;
        # x)
        #     autoscaling_specified="y"
        #     x_arg=${OPTARG}
        #     ;;
        g)
            traffic_ratio_specified="y"
            g_arg=${OPTARG}
            ;;
        n)
            nginx_name_specified="y"
            n_arg=${OPTARG}
            ;;
        d)
            disable_preloader="y"
            ;;
        v)
            revert_environment="y"
            ;;
        h)
            show_usage
            exit
            ;;
        *)
            echo "Warning! wrong parameter, ignore it."
            ;;
    esac
done

kubectl version|grep -q "^Server"
if [ "$?" != "0" ];then
    echo -e "\nPlease login to Kubernetes first."
    exit
fi

install_namespace="`kubectl get pods --all-namespaces |grep "alameda-datahub-"|awk '{print $1}'|head -1`"

if [ "$install_namespace" = "" ];then
    echo -e "\n$(tput setaf 1)Error! Please Install Federatorai before running this script.$(tput sgr 0)"
    exit 3
fi

if [[( "$prepare_environment" = "y" && "$cluster_name_specified" != "y" ) || ( "$install_nginx" = "y" && "$cluster_name_specified" != "y" )]]; then
    check_cluster_name_not_empty
fi

if [ "$cluster_name_specified" = "y" ]; then
    cluster_name="$a_arg"
    check_cluster_name_not_empty

    # check data source
    get_datasource_in_alamedaorganization
    if [ "$data_source_type" = "datadog" ]; then
        # No double check for prometheus or sysdig for now.
        # Do DD_CLUSTER_NAME check
        get_datadog_agent_info
        if [ "$dd_cluster_name" = "" ]; then
            echo -e "\n$(tput setaf 1)Error! Failed to auto-discover DD_CLUSTER_NAME value in Datadog cluster agent env variable.$(tput sgr 0)"
            echo -e "\n$(tput setaf 1)Please help to set up cluster name accordingly.$(tput sgr 0)"
            exit 7
        else
            if [ "$cluster_name" != "$dd_cluster_name" ]; then
                echo -e "\n$(tput setaf 1)Error! Cluster name ($cluster_name) specified through (-a) option doesn not match the DD_CLUSTER_NAME ($dd_cluster_name) value in Datadog cluster agent env variable.$(tput sgr 0)"
                exit 5
            fi
        fi
    fi

    # check cluster-only alamedascaler exist
    kubectl get alamedascaler -n $install_namespace -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.clusterName}{"\n"}'|grep -q "^${cluster_name} ${cluster_name}"
    if [ "$?" != "0" ];then
        echo -e "\n$(tput setaf 1)Error! Failed to find cluster-only alamedascaler with cluster name ($cluster_name).$(tput sgr 0)"
        echo -e "\n$(tput setaf 1)Please use Federator.ai GUI to configure cluster first.$(tput sgr 0)"
        exit 7
    fi
fi

if [ "$future_mode_enabled" = "y" ]; then
    future_mode_length=$f_arg
    case $future_mode_length in
        ''|*[!0-9]*) echo -e "\n$(tput setaf 1)future mode length (hour) needs to be an integer.$(tput sgr 0)" && show_usage ;;
        *) ;;
    esac
fi

if [ "$traffic_ratio_specified" = "y" ]; then
    traffic_ratio=$g_arg
    case $traffic_ratio in
        ''|*[!0-9]*) echo -e "\n$(tput setaf 1)ab test traffic ratio needs to be an integer.$(tput sgr 0)" && show_usage ;;
        *) ;;
    esac
else
    traffic_ratio="4000"
fi

if [ "$run_preloader_with_normal_mode" = "y" ] && [ "$run_preloader_with_historical_only" = "y" ]; then
    echo -e "\n$(tput setaf 1)Error! You can specify either the '-r' or the '-o' parameter, but not both.$(tput sgr 0)" && show_usage
    exit 3
fi

if [ "$run_preloader_with_normal_mode" = "y" ] && [ "$run_ab_from_preloader" = "y" ]; then
    echo -e "\n$(tput setaf 1)Error! You can specify either the '-r' or the '-b' parameter, but not both.$(tput sgr 0)" && show_usage
    exit 3
fi

if [ "$run_preloader_with_historical_only" = "y" ] && [ "$run_ab_from_preloader" = "y" ]; then
    echo -e "\n$(tput setaf 1)Error! You can specify either the '-o' or the '-b' parameter, but not both.$(tput sgr 0)" && show_usage
    exit 3
fi

if [ "$replica_num_specified" = "y" ]; then
    replica_number=$t_arg
    case $replica_number in
        ''|*[!0-9]*) echo -e "\n$(tput setaf 1)replica number needs to be an integer.$(tput sgr 0)" && show_usage ;;
        *) ;;
    esac
else
    # default replica
    replica_number="5"
fi

# if [ "$autoscaling_specified" = "y" ]; then
#     autoscaling_method=$x_arg
#     if [ "$autoscaling_method" != "vpa" ] && [ "$autoscaling_method" != "hpa" ]; then
#         echo -e "\n$(tput setaf 1) Pod autoscaling method needs to be \"vpa\" or \"hpa\".$(tput sgr 0)" && show_usage
#     fi
# else
#     autoscaling_method="hpa"
# fi
autoscaling_method="hpa"

if [ "$nginx_name_specified" = "y" ]; then
    nginx_name=$n_arg
    if [ "$nginx_name" = "" ]; then
        echo -e "\n$(tput setaf 1)nginx name needs to be specified with n parameter.$(tput sgr 0)"
    fi
else
    # Set default nginx name
    nginx_name="nginx-prepared"
fi

echo "Checking environment version..."
check_version
echo "...Passed"

alamedaservice_name="`kubectl get alamedaservice -n $install_namespace -o jsonpath='{range .items[*]}{.metadata.name}'`"
if [ "$alamedaservice_name" = "" ]; then
    echo -e "\n$(tput setaf 1)Error! Failed to get alamedaservice name.$(tput sgr 0)"
    leave_prog
    exit 8
fi

check_recommendation_pod_type

file_folder="/tmp/preloader"
nginx_ns="nginx-preloader-sample"
if [ "$openshift_minor_version" = "" ]; then
    # K8S
    nginx_port="80"
else
    # OpenShift
    nginx_port="8081"
fi
alamedascaler_name="nginx-alamedascaler"

debug_log="debug.log"

rm -rf $file_folder
mkdir -p $file_folder
current_location=`pwd`
if [ "$enable_execution_specified" = "y" ]; then
    enable_execution="$s_arg"
else
    enable_execution="true"
fi
# copy preloader ab files if run historical only mode enabled
preloader_folder="$(dirname $0)/preloader_ab_runner"
if [ "$run_preloader_with_historical_only" = "y" ] || [ "$run_ab_from_preloader" = "y" ]; then
    # Check folder exists
    [ ! -d "$preloader_folder" ] && echo -e "$(tput setaf 1)Error! Can't locate $preloader_folder folder.$(tput sgr 0)" && exit 3

    ab_files_list=("define.py" "generate_loads.sh" "generate_traffic1.py" "run_ab.py" "transaction.txt")
    for ab_file in "${ab_files_list[@]}"
    do
        # Check files exist
        [ ! -f "$preloader_folder/$ab_file" ] && echo -e "$(tput setaf 1)Error! Can't locate file ($preloader_folder/$ab_file).$(tput sgr 0)" && exit 3
    done

    cp -r $preloader_folder $file_folder
    if [ "$?" != "0" ]; then
        echo -e "\n$(tput setaf 1)Error! Can't copy folder $preloader_folder to $file_folder"
        exit 3
    fi
fi

cd $file_folder
echo "Receiving command '$0 $@'" >> $debug_log

if [ "$prepare_environment" = "y" ]; then
    delete_all_alamedascaler
    new_nginx_example
    add_svc_for_nginx
    #patch_datahub_for_preloader
    #patch_grafana_for_preloader
    patch_data_adapter_for_preloader "true"
    check_influxdb_retention
fi

if [ "$clean_environment" = "y" ]; then
    clean_environment_operations
fi

if [ "$enable_preloader" = "y" ]; then
    enable_preloader_in_alamedaservice
fi

if [ "$run_ab_from_preloader" = "y" ]; then
    run_ab_test
fi

if [ "$run_preloader_with_normal_mode" = "y" ] || [ "$run_preloader_with_historical_only" = "y" ]; then
    # Move scale_down_pods into run_preloader_command method
    #scale_down_pods
    if [ "$run_preloader_with_normal_mode" = "y" ]; then
        add_alamedascaler_for_nginx
        run_preloader_command "normal"
    else
        # historical mode
        get_datasource_in_alamedaorganization
        if [ "$data_source_type" = "datadog" ]; then
            if [ "$enable_execution_specified" = "y" ]; then
                enable_execution="$s_arg"
            else
                enable_execution="false"
            fi
        elif [ "$data_source_type" = "prometheus" ]; then
            echo ""
        elif [ "$data_source_type" = "sysdig" ]; then
            # Not sure for now
            if [ "$enable_execution_specified" = "y" ]; then
                enable_execution="$s_arg"
            else
                enable_execution="false"
            fi
        fi
        add_alamedascaler_for_nginx
        run_preloader_command "historical_only"
    fi
    verify_metrics_exist
    scale_up_pods
    #check_prediction_status
fi

if [ "$future_mode_enabled" = "y" ]; then
    run_futuremode_preloader
    verify_metrics_exist
fi

if [ "$disable_preloader" = "y" ]; then
    # scale up if any failure encounter previously or program abort
    scale_up_pods
    #switch_alameda_executor_in_alamedaservice "off"
    disable_preloader_in_alamedaservice
fi

if [ "$revert_environment" = "y" ]; then
    # scale up if any failure encounter previously or program abort
    scale_up_pods
    delete_all_alamedascaler
    delete_nginx_example
    #patch_datahub_back_to_normal
    #patch_grafana_back_to_normal
    patch_data_adapter_for_preloader "false"
    clean_environment_operations
fi

if [ "$install_nginx" = "y" ]; then
    new_nginx_example
    add_svc_for_nginx
    add_alamedascaler_for_nginx
fi

if [ "$remove_nginx" = "y" ]; then
    delete_nginx_example
fi

leave_prog
exit 0
