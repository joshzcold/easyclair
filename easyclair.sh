#!/bin/bash

TEARDOWN=true
SEARCH=""
POSTGRES_PORT=5432
CLAIR_API_PORT=6060
CLAIR_HEALTH_PORT=6061
REGISTRY_PORT=5000
CLEAR_DATABASE=false
DIR=$PWD
WAIT_DB=false

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
    docker run -d -e POSTGRES_PASSWORD="" --name clairdb -p ${POSTGRES_PORT}:5432 postgres:latest
else
   echo "clairdb is running" 	
fi
}

startdb(){
    docker run -d -e POSTGRES_PASSWORD="" --name clairdb -p ${POSTGRES_PORT}:5432 postgres:latest
    until PGPASSWORD="" psql -h "localhost" -p ${POSTGRES_PORT} -U "postgres" -c '\q'; do
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
while [ $secs -gt 0 ]; do
   echo -ne "$secs\033[0K\r"
   sleep 1
   : $((secs--))
done
}

setup(){
#Create Directories
mkdir -p $DIR/clair/config $DIR/clair/reports $DIR/clair/certs

#Run Services for clair
docker run -d -p ${REGISTRY_PORT}:5000 \
  --name clairreg \
  registry:latest


#Create clair config file and directory
cat <<EOT > ${DIR}/clair/config/clair.yaml
clair:
  database:
    type: pgsql
    options:
      source: host=localhost port=${POSTGRES_PORT} user=postgres sslmode=disable statement_timeout=60000
  api:
    addr: "0.0.0.0:${CLAIR_API_PORT}"
    healthaddr: "0.0.0.0:${CLAIR_HEALTH_PORT}"
EOT


cat <<EOT > $DIR/clair/config/clairctl.yaml
clair:
  port: ${CLAIR_API_PORT}
  healthPort: ${CLAIR_HEALTH_PORT}
  uri: http://localhost
  report:
    path: /reports
    format: html
docker:
  insecure-registries:
    - "localhost:${REGISTRY_PORT}"
EOT

#Start Clairctl
docker run --net=host -d --name clairctl \
-v ${DIR}/clair/reports:/reports:rw \
-v ${DIR}/clair/config:/config:ro \
jgsqware/clairctl:master

#Start Clair
docker run  --net=host -d -p ${CLAIR_API_PORT}:6060 -p ${CLAIR_HEALTH_PORT}:6061 -v \
	$DIR/clair/config:/config --name clair \
	quay.io/coreos/clair:latest \
	-config=/config/clair.yaml \
	-insecure-tls
}



executeclair(){
#Get local images and push them to local registry
mapfile -t ARRAY <<< $(docker image ls | grep "${SEARCH}")
for LINE in "${ARRAY[@]}"
do
	IFS=' '
	read -ra FULL_REPO <<< "$LINE"

	TAG="${FULL_REPO[0]}:${FULL_REPO[1]}"

	IFS='/' # / is set as delimiter
	read -ra ADDR <<< "${FULL_REPO[0]}" # str is read into an array as tokens separated by IFS
    	IMAGENAME="${ADDR[-1]}"

	echo "IMAGE NAME: $IMAGENAME"
docker tag "$TAG" localhost:${REGISTRY_PORT}/"${IMAGENAME}:latest"
PUSH+=("localhost:${REGISTRY_PORT}/${IMAGENAME}:latest")
done

for IMG in "${PUSH[@]}"
do
docker push "$IMG"
done


#Push to Clair
for SCAN in "${PUSH[@]}"
do
docker exec -t clairctl clairctl --config /config/clairctl.yaml push "$SCAN"
docker exec -t clairctl clairctl --config /config/clairctl.yaml analyze "$SCAN"
docker exec -t clairctl clairctl --config /config/clairctl.yaml report "$SCAN"
docker exec -t clairctl clairctl --config /config/clairctl.yaml report "$SCAN" --format json
docker exec -t clairctl clairctl --config /config/clairctl.yaml delete "$SCAN"
done	
}


while getopts "hnd:s:-:" optchar; do
    case "${optchar}" in
		h)
			print_usage
			exit
			;;
		n)
			TEARDOWN=false
			echo "teardown $TEARDOWN"
			;;
		d)
			if [[ -d "$OPTARG" ]]; then
			 DIR=$OPTARG
			 echo "working directory $DIR"
		  	else
			 echo "-d parameter: working directory is invalid"
		 	 exit	 
			fi
			;;
		s)
			SEARCH="$OPTARG"
			echo "search term $SEARCH"
			;;
		-)
			case "${OPTARG}" in
			            help)
		                    print_usage
				    exit
                   		 ;;
                		postgres-port)
		                    val="${!OPTIND}"; OPTIND=$(( $OPTIND + 1 ))
                		    POSTGRES_PORT=${val}
                		    echo "postgres port $POSTGRES_PORT"
                   		 ;;
                		clair-api-port)
		                    val="${!OPTIND}"; OPTIND=$(( $OPTIND + 1 ))
                		    CLAIR_API_PORT=${val}
                		    echo "clair api port $CLAIR_API_PORT"
                   		 ;;
                		clair-health-port)
		                    val="${!OPTIND}"; OPTIND=$(( $OPTIND + 1 ))
                		    CLAIR_HEALTH_PORT=${val}
                		    echo "clair health port $CLAIR_HEALTH_PORT"
                   		 ;;
                		registry-port)
		                    val="${!OPTIND}"; OPTIND=$(( $OPTIND + 1 ))
                		    REGISTRY_PORT=${val}
                		    echo "registry port $REGISTRY_PORT"
                   		 ;;
                		clear-database)
		                    CLEAR_DATABASE=true
                		    echo "clear database $CLEAR_DATABASE"
                   		 ;;

                		wait-for-db)
		                    WAIT_DB=true
                		    echo "WAIT_DB is $WAIT_DB"
                   		 ;;
               			 *)
                   			 if [[ "$OPTERR" = 1 ]] && [[ "${optspec:0:1}" != ":" ]]; then
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

if [[ "$CLEAR_DATABASE" = true ]]
then
	cleanup-deletedb
	startdb
else
	cleanup
fi

if [[ "$WAIT_DB" = true ]]
then
	waitforclairsetup
fi

setup
executeclair

if [[ "$TEARDOWN" = true ]] && [[ "$CLEAR_DATABASE" = true ]]
then
	cleanup-deletedb
	echo "Cleared clairdb"
elif [[ "$TEARDOWN" = true ]] 
then
	cleanup
else
	echo "kept docker containers running"
fi

echo "analysis done, reports will be stored at  $DIR/clair/reports"
exit
