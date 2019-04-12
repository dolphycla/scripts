#!/bin/sh
# cf-failver.sh - https://github.com/dolphycla/scripts
# A minimal, portable failover client for CloudFlare API v4 meant for use with icinga2
# Requires: curl (w/ HTTPS support), grep, awk

helptext=`cat << ENDHELP
Usage: cf-failover.sh [OPTION] -e=EMAIL -a=APIKEY -z=ZONENAME -r=RECORDNAME
  Or:  cf-failover.sh [OPTION] -e=EMAIL -a=APIKEY -y=ZONEID -q=RECORDID
A minimal, portable DDNS client for CloudFlare

Required
  -e=, --email=		CloudFlare account email
  -a=, --apikey=	CloudFlare account API key
  -z=, --zonename=	Zone name in the form of subdomain.domain.tld
    OR
  -y=, --zoneid=	CloudFlare zone ID
  -r=, --recordname=	Record name in the form of subdomain.domain.tld
    OR
  -q=, --recordid=	CloudFlare record ID

Options
  -f, --force		Force a DNS update, even if FailOver IP hasn't changed
  -t, --test		Test action without updating DNS record
  -f=, --failover=		Manually specify FailOver IP address, skip detection
  --get-zone-id		Print zone ID corresponding to zone name and exit
  --get-record-id	Print record ID corresponding to record name and exit
  -h, --help		Print this message and exit
ENDHELP`


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
# Where to store the address from our last update. /tmp/.
storage_dir='/tmp/'
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



set_FAILPOVER_addr () {
    if [ ! -z $1 ]; then
        if validate_ip_addr $1; then
	    FAILPOVER_addr="${1}"
            return 0
        else
            echo "FailOver IP is invalid."
	    exit 1
        fi
    fi
    return 1
}


get_zone_id () {
    if [ -z $zone_id ]; then
	set_zone_id $zone_name
    fi
    echo "${zone_id}"
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
        echo "No zone name provided."
        exit 1
    fi

    zones=`${curl_command} -s -X GET "${cf_api_url}/zones?name=${zname}" -H "X-Auth-Email: ${cf_email}" -H "X-Auth-Key: ${cf_api_key}" -H "Content-Type: application/json"`

    if [ ! "${zones}" ]; then
        echo "Request to API failed during zone lookup."
        exit 1
    fi

    if [ -n "${zones##*\"success\":true*}" ]; then
        echo "Failed to lookup zone ID. Check zone name or specify an ID."
        echo "${zones}"
        exit 1
    fi

    echo "${zones}" | grep -Po '(?<="id":")[^"]*' | head -1
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
        echo "No record name provided."
        exit 1
    fi

    if [ -z $zone_name ] && [ -z $zone_id ]; then
        echo "No zone name or ID provided."
        exit 1
    fi

    # No zone ID? Look it up by name.
    if [ -z $zone_id ] && [ -n $zone_name ]; then
        set_zone_id $zone_name
    fi

    records=`${curl_command} -s -X GET "${cf_api_url}/zones/${zone_id}/dns_records?name=${record_name}&type=A" -H "X-Auth-Email: ${cf_email}" -H "X-Auth-Key: ${cf_api_key}" -H "Content-Type: application/json"`

    if [ ! "${records}" ]; then
        echo "Request to API failed during record lookup."
        exit 1
    fi

    if [ -n "${records##*\"success\":true*}" ]; then
        echo "Failed to lookup DNS record ID. Check record name or specify an ID."
        echo "${records}"
        exit 1
    fi

    records=`echo "${records}" | grep -Po '(?<="id":")[^"]*'`
    records_count=`echo "${records}" | wc -w`

    if [ $records_count -gt 1 ]; then
        echo "Multiple DNS A records match ${record_name}. Please specify a record ID."
        exit 1
    fi

    record_id="${records}"
    return 0
}


do_record_update () {
    # Perform record update
    api_dns_update=`${curl_command} -s -X PUT "${cf_api_url}/zones/${zone_id}/dns_records/${record_id}" -H "X-Auth-Email: ${cf_email}" -H "X-Auth-Key: ${cf_api_key}" -H "Content-Type: application/json" --data "{\"id\":\"${zone_id}\",\"type\":\"A\",\"name\":\"${record_name}\",\"content\":\"${FAILPOVER_addr}\"}"`

    if [ ! "${api_dns_update}" ]; then
        echo "There was a problem communicating with the API server. Check your connectivity and parameters."
        echo "${api_dns_update}"
        exit 1
    fi

    if [ -n "${api_dns_update##*\"success\":true*}" ]; then
        echo "Record update failed."
        echo "${api_dns_update}"
        exit 1
    fi

    return 0
}

#End functions


#Main
###############
# Remove any trailing slashes from storage_dir and cf_api_url
storage_dir=${storage_dir%%+(/)}
cf_api_url=${cf_api_url%%+(/)}

# Show help and exit if no option was passed in the command line

if [ -z "${1}" ]; then
    echo "${helptext}"
    exit 0
fi

# Get options and arguments from the command line
for key in "$@"; do
    case $key in
    -z=*|--zonename=*)
        zone_name="${key#*=}"
        shift
    ;;
    -r=*|--recordname=*)
        record_name="${key#*=}"
        shift
    ;;
    -y=*|--zoneid=*)
        set_zone_id "${key#*=}"
        shift
    ;;
    -q=*|--recordid=*)
        record_id="${key#*=}"
        shift
    ;;
    -e=*|--email=*)
        cf_email="${key#*=}"
        shift
    ;;
    -a=*|--apikey=*)
        cf_api_key="${key#*=}"
        shift
    ;;
    -f=*|--FailOver=*)
        set_FAILPOVER_addr "${key#*=}"
        shift
    ;;
    -f|--force)
        force=true
        shift
    ;;
    -t|--test)
        run_mode="test"
        shift
    ;;
    -h|--help)
        echo "${helptext}"
        exit 0
    ;;
    *)
        echo "Unknown option '${key}'"
        exit 1
    ;;
    esac
done

# Check if curl supports https
curl_https_check=`${curl_command} --version`
if [ -n "${curl_https_check##*https*}" ]; then
    echo "Your version of curl doesn't support HTTPS. Exiting."
    exit 1
fi


# If we need to look up a zone/record ID from the names, do so
if [ -z $zone_id ]; then
    set_zone_id
fi
if [ -z $record_id ]; then
    get_record_id # TBD - refactor
fi


if [ "$run_mode" = "test" ]; then
    echo "TEST:	In zone ${zone_name}[${zone_id}],"
    echo "	update A record ${record_name}[${record_id}]"
    echo "	to point to ${FAILPOVER_addr}"
    exit 0
fi

do_record_update

echo "Record updated."

exit 0
