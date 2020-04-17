#!/bin/bash

teardown=true
search=""
postgres_port=5432
clair_api_port=6060
clair_health_port=6061
registry_port=5000
clear_database=false
working_dir="$(readlink -f .)"
wait_db=false

print_usage() {
cat << EOF
usage: easyclair
-s [search string] enter in key term for clairscan to choose docker images
	default: clairscan will analyze all images
-n Dont Tear Down: this will keep all containers running, but will still
        clear containers on startup
-d working directory: choose directory to put results and configs

--clear-database : this will delete docker container
          called "clairdb" before and after execution
          this will have clair take longer to setup
--wait-for-db : wait 30 minutes for clair db to populate with
	  vulnerabilities. This is recommended on first start up
--postgres-port  :  default port: 5432
--clair-api-port :  default port: 6060
--clair-health-port: default port: 6061
--registry-port : default port: 5000

recommend to change default port if using this in CI or have
other port conflicts

recommend to keep the clairdb up so you have accurate results from
the result of a populated clairdb. Population takes about 30 minutes.
EOF
}


cleanup-deletedb(){
# stop and delete registery if it exists
docker stop clairreg || true  && docker container rm clairreg || true
docker stop clair || true && docker container rm clair || true
docker stop clairctl || true && docker container rm clairctl || true
docker stop clairdb || true && docker container rm clairdb || true
}

cleanup(){
# stop and delete registery if it exists
docker stop clairreg || true  && docker container rm clairreg || true
docker stop clair || true && docker container rm clair || true
docker stop clairctl || true && docker container rm clairctl || true
if [[ ! "$(docker ps -q -f name=clairdb)" ]]; then
    if [[ "$(docker ps -aq -f status=exited -f name=clairdb)" ]]; then
        # cleanup
        docker container rm clairdb || true
    fi
    # run your container
    docker run -d -e POSTGRES_PASSWORD="" --name clairdb -p ${postgres_port}:5432 postgres:latest
else
   echo "clairdb is running" 	
fi
}

startdb(){
    docker run -d -e POSTGRES_PASSWORD="" --name clairdb -p ${postgres_port}:5432 postgres:latest
    until PGPASSWORD="" psql -h "localhost" -p ${postgres_port} -U "postgres" -c '\q'; do
  >&2 echo "Postgres is unavailable - checking until connection is good"
  sleep 1
done
}

waitforclairsetup(){

cat << EOF
--------------------------------------------------

Waiting 30 minutes for the clair postgres db 
to populate with CVE data

if you want to see the status of clair use command

$ watch docker container logs clair

script will continue after the thirty minutes

-------------------------------------------------
EOF

secs=$((30 * 60))
while [ "$secs" -gt 0 ]; do
   echo -ne "$secs\033[0K\r"
   sleep 1
   : $((secs--))
done
}

setup(){
#Create Directories
mkdir -p "${working_dir}"/clair/config "${working_dir}"/clair/reports "${working_dir}"/clair/certs

#Run Services for clair
docker run -d -p "${registry_port}":5000 \
  --name clairreg \
  registry:latest


#Create clair config file and directory
cat <<EOT > "${working_dir}"/clair/config/clair.yaml
clair:
  database:
    type: pgsql
    options:
      source: host=localhost port=${postgres_port} user=postgres sslmode=disable statement_timeout=60000
  api:
    addr: "0.0.0.0:${clair_api_port}"
    healthaddr: "0.0.0.0:${clair_health_port}"
EOT


cat <<EOT > "${working_dir}"/clair/config/clairctl.yaml
clair:
  port: ${clair_api_port}
  healthPort: ${clair_health_port}
  uri: http://localhost
  report:
    path: /reports
    format: html
docker:
  insecure-registries:
    - "localhost:${registry_port}"
EOT

#Start Clairctl
docker run --net=host -d --name clairctl \
-v "${working_dir}"/clair/reports:/reports:rw \
-v "${working_dir}"/clair/config:/config:ro \
jgsqware/clairctl:master

#Start Clair
docker run  --net=host -d -p "${clair_api_port}":6060 -p "${clair_health_port}":6061 -v \
	"${working_dir}"/clair/config:/config --name clair \
	quay.io/coreos/clair:latest \
	-config=/config/clair.yaml \
	-insecure-tls
}



executeclair(){
#Get local images and push them to local registry
mapfile -t array <<< $(docker image ls | grep "${search}")
for line in "${array[@]}"
do
	IFS=' '
	read -ra full_repo <<< "${line}"

	TAG="${full_repo[0]}:${full_repo[1]}"

	IFS='/' # / is set as delimiter
	read -ra addr <<< "${full_repo[0]}" # str is read into an array as tokens separated by IFS
    	image_name="${addr[-1]}"

	echo "IMAGE NAME: ${image_name}"
docker tag "${TAG}" localhost:"${registry_port}"/"${image_name}:latest"
push+=("localhost:${registry_port}/${image_name}:latest")
done

for img in "${push[@]}"
do
docker push "${img}"
done


#Push to Clair
for scan in "${push[@]}"
do
docker exec -t clairctl clairctl --config /config/clairctl.yaml push "${scan}"
docker exec -t clairctl clairctl --config /config/clairctl.yaml analyze "${scan}"
docker exec -t clairctl clairctl --config /config/clairctl.yaml report "${scan}"
docker exec -t clairctl clairctl --config /config/clairctl.yaml report "${scan}" --format json
docker exec -t clairctl clairctl --config /config/clairctl.yaml delete "${scan}"
done	
}


while getopts "hnd:s:-:" optchar; do
    case "${optchar}" in
		h)
			print_usage
			exit
			;;
		n)
			teardown=false
			echo "teardown ${teardown}"
			;;
		d)
			if [[ -d "${OPTARG}" ]]; then
        working_dir="$(readlink -f "${OPTARG}")"
			 echo "working directory ${working_dir}"
		  	else
			 echo "-d parameter: working directory is invalid"
		 	 exit	 
			fi
			;;
		s)
			search="${OPTARG}"
			echo "search term ${search}"
			;;
		-)
			case "${OPTARG}" in
			            help)
		                    print_usage
				    exit
                   		 ;;
                		postgres-port)
		                    val="${!OPTIND}"; OPTIND=$(( $OPTIND + 1 ))
                		    postgres_port=${val}
                		    echo "postgres port ${postgres_port}"
                   		 ;;
                		clair-api-port)
		                    val="${!OPTIND}"; OPTIND=$(( $OPTIND + 1 ))
                		    clair_api_port=${val}
                		    echo "clair api port ${clair_api_port}"
                   		 ;;
                		clair-health-port)
		                    val="${!OPTIND}"; OPTIND=$(( $OPTIND + 1 ))
                		    clair_health_port=${val}
                		    echo "clair health port ${clair_health_port}"
                   		 ;;
                		registry-port)
		                    val="${!OPTIND}"; OPTIND=$(( $OPTIND + 1 ))
                		    registry_port=${val}
                		    echo "registry port ${registry_port}"
                   		 ;;
                		clear-database)
		                    clear_database=true
                		    echo "clear database ${clear_database}"
                   		 ;;

                		wait-for-db)
		                    wait_db=true
                		    echo "wait_db is ${wait_db}"
                   		 ;;
               			 *)
                   			 if [[ "${OPTERR}" = 1 ]] && [[ "${optspec:0:1}" != ":" ]]; then
                      			 echo "Unknown option --${OPTARG}" >&2
                      			 print_usage
					 exit
                   			 fi
                    ;;
           	 esac
			;;
		:)
			;;
		\?)
			print_usage
			exit
			;;
	esac
done

if [[ "${clear_database}" = "true" ]]
then
	cleanup-deletedb
	startdb
else
	cleanup
fi

setup

if [[ "${wait_db}" = "true" ]]
then
	waitforclairsetup
fi

executeclair

if [[ "${teardown}" = "true" ]] && [[ "${clear_database}" = "true" ]]
then
	cleanup-deletedb
	echo "Cleared clairdb"
elif [[ "${teardown}" = "true" ]] 
then
	cleanup
else
	echo "kept docker containers running"
fi

echo "analysis done, reports will be stored at  ${working_dir}/clair/reports"
exit
