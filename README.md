# easyclair
bash script to start a clair scan easily 

*IMPORTANT:* clairdb needs to populate with vulnerabilites before you get an accurate result. I have a flag that waits for 30 minutes before starting a scan. This doesn't look into the database to confirm its done so if you can improve this pull requests are welcome 🙂

By deafult this scripts keeps the clairdb running docker so that you don't have to repopulate it each time you do a scan.


uses 4 docker images:
 - quay.io/coreos/clair:latest [link](https://quay.io/repository/coreos/clair?tag=latest&tab=tags)
 - jgsqware/clairctl:master [link](https://hub.docker.com/r/jgsqware/clairctl)
 - registry:latest [link](https://hub.docker.com/_/registry)
 - postgres:latest [link](https://hub.docker.com/_/postgres)

## Dependencies
- Docker `docker version`
- psql `psql --version` This is included in postgres installation. probably could be removed in a feature improvement

## Usage
```
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
```
## Example
scan images matching string, wait for db, place config and results in dir (recommended)

`./easyclair.sh -s ubuntu --wait-for-db -d clairscan/`

scan all local images on computer without waiting for db

`./easyclair.sh`

scan all local images on computer and wait for clairdb to populate

`./easyclair.sh --wait-for-db`

scan images matching string 

`./easyclair -s ubuntu`
