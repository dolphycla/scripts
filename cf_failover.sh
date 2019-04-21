#!/bin/bash
# cf-failver.sh - https://github.com/dolphycla/scripts
# A minimal, portable failover client for CloudFlare API v4 meant for use with icinga2
# Requires: curl (w/ HTTPS support), grep, awk

helptext=`cat << ENDHELP
Usage: cf-failover.sh [OPTION] -e=EMAIL -a=APIKEY -z=ZONENAME -r=RECORDNAME
  Or:  cf-failover.sh [OPTION] -e=EMAIL -a=APIKEY -y=ZONEID -q=RECORDID
A minimal, portable DDNS client for CloudFlare

Required
  -e , --email=    CloudFlare account email
  -a , --apikey=  CloudFlare account API key
  -z , --zonename=  Zone name in the form of subdomain.domain.tld
  -p , --record_name Record name
    OR
  -y , --state=  Service State
  -r , --state_type=  Service State type
    OR
  -q , --check_attempt=  Service check attempt
  -l , --recordid=    CloudFlare record ID
Options
  -f, --force    Force a DNS update, even if FailOver IP hasn't changed
  -t, --test    Test action without updating DNS record
  -f , --failover=    Manually specify FailOver IP address, skip detection
  -h, --help    Print this message and exit
ENDHELP`

cf_log='/tmp/cf_failover.log'
timestamp=`date +"%m-%d-%Y %H:%S:%T"`
#Configuration - these options can be hard-coded or passed as parameters
###############
# CF credentials - required
cf_email=''
cf_api_key=''
# Zone name - can be blank if zone_id is set
zone_name=''
# Zone ID - if blank, will be looked up using zone_name
zone_id='' # If blank, will be looked up
# DNS record name  (e.g. domain.tld or subdomain.domain.tld)
# - can be blank if record_id is set
record_name=''
# DNS record ID - if blank, will be looked up using record_name
record_id=''

###############
#The defaults below should be fine.
# Command to run for curl requests. If using alternate version, specify path.
curl_command='curl'
# FailOver address - DNS A record will be updated to point to this address
FAILPOVER_addr=''
# Force update if address hasn't changed?
force=false
# CloudFlare API (v4) URL
cf_api_url='https://api.cloudflare.com/client/v4/'
#END CONFIGURATION



#Functions
###############
validate_ip_addr () {
    if [ -z $1 ]; then return 1; fi
    if [ "${1}" != "${1#*[0-9].[0-9]}" ] && [ "${1}" != "${1#*:[0-9a-fA-F]}" ]; then
        return 1
    fi
    return 0
}

logs_output () {

    echo "${timestamp} - ${1}"
}

set_FAILPOVER_addr () {
    if [ ! -z $1 ]; then
        if validate_ip_addr $1; then
      FAILPOVER_addr="${1}"
            return 0
        else
            logs_output "FailOver IP is invalid." >> ${cf_log}
      exit 1
        fi
    fi
    return 1
}


get_zone_id () {
    if [ -z $zone_id ]; then
  set_zone_id $zone_name
    fi
    logs_output "${zone_id}" >> ${cf_log}
    return 0
}


lookup_zone_id () {
    local zones
    local zname

    if [ ! -z $1 ]; then
        zname="${1}"
    else
        zname=$zone_name
    fi

    if [ -z $zname ]; then
        logs_output "No zone name provided." >> ${cf_log}
        exit 1
    fi

    zones=`${curl_command} -s -X GET "${cf_api_url}/zones?name=${zname}" -H "X-Auth-Email: ${cf_email}" -H "X-Auth-Key: ${cf_api_key}" -H "Content-Type: application/json"`

    if [ ! "${zones}" ]; then
        logs_output "Request to API failed during zone lookup." >> ${cf_log}
        exit 1
    fi

    if [ -n "${zones##*\"success\":true*}" ]; then
        logs_output "Failed to lookup zone ID. Check zone name or specify an ID." >> ${cf_log}
        logs_output "${zones}" >> ${cf_log}
        exit 1
    fi

    logs_output "${zones}" | grep -Po '(?<="id":")[^"]*' | head -1
    return 0
}


set_zone_id () {
    if [ ! -z $1 ]; then
        if [ -n "${1##*\.*}"]; then
      zone_id=`lookup_zone_id "${1}"`
            return 0
        else
            zone_id="${1}"
      return 0
        fi
    elif [ -n $zone_name ]; then
        set_zone_id $zone_name
  return 0
    fi
    return 1
}

#TBD - refactor this like the get/set/lookup_zone_id functions
get_record_id () {
    local records
    local records_count

    if [ -z $record_name ]; then
        logs_output "No record name provided." >> ${cf_log}
        exit 1
    fi

    if [ -z $zone_name ] && [ -z $zone_id ]; then
        logs_output "No zone name or ID provided." >> ${cf_log}
        exit 1
    fi

    # No zone ID? Look it up by name.
    if [ -z $zone_id ] && [ -n $zone_name ]; then
        set_zone_id $zone_name
    fi

    records=`${curl_command} -s -X GET "${cf_api_url}/zones/${zone_id}/dns_records?name=${record_name}&type=A" -H "X-Auth-Email: ${cf_email}" -H "X-Auth-Key: ${cf_api_key}" -H "Content-Type: application/json"`

    if [ ! "${records}" ]; then
        logs_output "Request to API failed during record lookup." >> ${cf_log}
        exit 1
    fi

    if [ -n "${records##*\"success\":true*}" ]; then
        logs_output "Failed to lookup DNS record ID. Check record name or specify an ID." >> ${cf_log}
        logs_output "${records}" >> ${cf_log}
        exit 1
    fi

    records=`logs_output "${records}"| grep -Po '(?<="id":")[^"]*'`
    records_count=`logs_output "${records}" | wc -w`

    if [ $records_count -gt 1 ]; then
        logs_output "Multiple DNS A records match ${record_name}. Please specify a record ID." >> ${cf_log}
        exit 1
    fi

    record_id="${records}"
    return 0
}


do_record_update () {
    # Perform record update
    api_dns_update=`${curl_command} -s -X PUT "${cf_api_url}/zones/${zone_id}/dns_records/${record_id}" -H "X-Auth-Email: ${cf_email}" -H "X-Auth-Key: ${cf_api_key}" -H "Content-Type: application/json" --data "{\"id\":\"${zone_id}\",\"type\":\"A\",\"name\":\"${record_name}\",\"content\":\"${FAILPOVER_addr}\"}"`

    if [ ! "${api_dns_update}" ]; then
        logs_output "There was a problem communicating with the API server. Check your connectivity and parameters." >> ${cf_log}
        logs_output "${api_dns_update}" >> ${cf_log}
        exit 1
    fi

    if [ -n "${api_dns_update##*\"success\":true*}" ]; then
        logs_output "Record update failed." >> ${cf_log}
        logs_output "${api_dns_update}" >> ${cf_log}
        exit 1
    fi

    return 0
}

#End functions


#Main
###############
# Remove any trailing slashes from storage_dir and cf_api_url
cf_api_url=${cf_api_url%%+(/)}

# Show help and exit if no option was passed in the command line

if [ -z "${1}" ]; then
    logs_output "${helptext}" >> ${cf_log}
    exit 0
fi

# Get options and arguments from the command line
POSITIONAL=()
while [[ $# -gt 0 ]]
do
key="$1"

case $key in
    -z|--zonename)
    zone_name="$2"
    shift # past argument
    shift # past value
    ;;
    -p|--recordname)
    record_name="$2"
    shift # past argument
    shift # past value
    ;;
    -l|--recordid)
    record_id="$2"
    shift # past argument
    shift # past value
    ;;

    -e|--cf_email)
    cf_email="$2"
    shift # past argument
    shift # past value
    ;;
    -a|--apikey)
    cf_api_key="$2"
    shift # past argument
    shift # past value
    ;;
    -f|--FailOver)
    FAILPOVER_addr="$2"
    shift # past argument
    shift # past value
    ;;
    --default)
    DEFAULT=YES
    shift # past argument
    ;;
    *)    # unknown option
    POSITIONAL+=("$1") # save it in an array for later
    shift # past argument
    ;;
esac
done
set -- "${POSITIONAL[@]}" # restore positional parameters




# Check if curl supports https
curl_https_check=`${curl_command} --version`
if [ -n "${curl_https_check##*https*}" ]; then
    logs_output "Your version of curl doesn't support HTTPS. Exiting." >> ${cf_log}
    exit 1
fi


# If we need to look up a zone/record ID from the names, do so
if [ -z $zone_id ]; then
    set_zone_id
fi
if [ -z $record_id ]; then
    get_record_id # TBD - refactor
fi


logs_output "Record id: ${record_id}" >> ${cf_log}
logs_output "Zone name: ${zone_name}" >> ${cf_log}
logs_output "Zone id: ${zone_id}" >> ${cf_log}
do_record_update

logs_output "Record updated." >> ${cf_log}

exit 0
