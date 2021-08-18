#!/bin/bash
#
# backs up running database clusters and uploads to s3
# TODO fix cleanup

main() {
  init
  # dump globals and upload to S3
  if ! dump_schema ; then 
    err "globals dump failed"
  else
    if ! copy_to_s3 "${SCHEMA_FILE}" ; then
      err "globals upload failed"
    fi
  fi

  # dump all running databases and upload to S3

  for DBNAME in "${RUNNING_DATABASES[@]}" ; do
    # skip empty array elements 
    if [[ -z "${DBNAME}" ]] ; then
      continue
    fi

    DATABASE_FILE="${MYHOSTNAME}-${PORT}-${DBNAME}"
    # dump DB
    if ! dump_database "${DBNAME}" ; then
      err "${DBNAME} dump failed"
    else
      # copy to s3
      if ! copy_to_s3 "${DATABASE_FILE}" 1 ; then
        err "${DBNAME} upload failed" 
      fi
    fi
  done
}

err() {
   echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] BT_BACKUP_ERROR: $*" >&2
   exit 1
}

init() {
  # determine ec2metadata binary name 
  ec2Metadata=$(command -v ec2metadata ec2-metadata | head -n1)
  if [[ -z "${ec2Metadata}" ]] ; then 
    err 'ec2metadata/ec2-metadata not installed or not found'
    exit 1
  fi


  # set environment variables
  REGION=$($ec2Metadata --availability-zone | cut -f2 -d ' ' | sed 's/[a-z]$//')
  INSTANCEID=$($ec2Metadata --instance-id | sed 's/instance-id:\ //')
  DATE=$(date '+%F')
  MYHOSTNAME=$(/usr/local/bin/aws ec2 describe-instances --region "${REGION}" --instance-ids "${INSTANCEID}" --query 'Reservations[].Instances[].Tags[?Key==`Name`].Value[]' --output text)
  STATE=$(/usr/local/bin/aws ec2 describe-instances --region "${REGION}" --instance-ids "${INSTANCEID}" --query 'Reservations[].Instances[].Tags[?Key==`state`].Value[]' --output text)
  PORT=$(/usr/local/bin/aws ec2 describe-instances --region "${REGION}" --instance-ids "${INSTANCEID}" --query 'Reservations[].Instances[].Tags[?Key==`dbPort`].Value[]' --output text)
  BUCKET=$(/usr/local/bin/aws ec2 describe-instances --region "${REGION}" --instance-ids "${INSTANCEID}" --query 'Reservations[].Instances[].Tags[?Key==`backupBucket`].Value[]' --output text)
  LOCAL_DIR=$(/usr/local/bin/aws ec2 describe-instances --region "${REGION}" --instance-ids "${INSTANCEID}" --query 'Reservations[].Instances[].Tags[?Key==`localBackupDir`].Value[]' --output text)
  PGBIN=$(/usr/local/bin/aws ec2 describe-instances --region "${REGION}" --instance-ids "${INSTANCEID}" --query 'Reservations[].Instances[].Tags[?Key==`pgBin`].Value[]' --output text)

  CPUCORES=$(getconf _NPROCESSORS_ONLN)
  SCHEMA_FILE="${MYHOSTNAME}-${PORT}-schema.sql"

  # check
  if [[ -z "${MYHOSTNAME}" \
    || ! -d "${LOCAL_DIR}" \
    || -z "${REGION}" \
    || -z "${DATE}" \
    || -z "${STATE}" \
    || -z "${PORT}" \
    || -z "${BUCKET}" \
    || -z "${CPUCORES}" ]] ; then
    err "Startup variables not defined"
  fi

  # cleanup old backup, necessary for -Fd dumps
  rm -rf ${LOCAL_DIR:?}/${MYHOSTNAME:?}* 

  # get running DBs
  mapfile -t RUNNING_DATABASES <  <( "${PGBIN}/psql" \
    --user=postgres \
    --host=127.0.0.1 \
    --command="select datname from pg_database WHERE datname != 'template0'" \
    --quiet \
    --tuples-only \
    | tr -d ' ' )
}

dump_schema() {
  # plaintext uncompressed dump - small, faster restore
  "${PGBIN}/pg_dumpall" \
    --username=postgres \
    --host="127.0.0.1" \
    --port="${PORT}" \
    --schema-only \
    --file="${LOCAL_DIR}/${SCHEMA_FILE}"
}

dump_database() {
  # multicore dump to directory format speeds up the dump, max compression
  DBNAME=$1
  "${PGBIN}/pg_dump" \
    --format=directory \
    --username="postgres" \
    --compress=9 \
    --jobs="${CPUCORES}" \
    --host="127.0.0.1" \
    --port="${PORT}" \
    --dbname="${DBNAME:?}" \
    --file="${LOCAL_DIR}/${DATABASE_FILE}" \
    --exclude-table 'log_bmsi_loginlog' \
    --exclude-table 'log_bmsi_sessions' \
    --exclude-table 'forms_cards_printed' \
    --exclude-table 'forms_history' \
    --exclude-table 'forms_values' 
     
  
}

copy_to_s3 () {
  # upload a file - add a second argument to recursively copy a local folder
  COPY_FILE=$1
   
  if [[ -n "$2" ]] ; then
    /usr/local/bin/aws s3 cp \
      --region="${REGION}" \
      --only-show-errors \
      --recursive \
      "${LOCAL_DIR}/${COPY_FILE}" "s3://${BUCKET}/${STATE}/${DATE}/${COPY_FILE}" 
  else
    /usr/local/bin/aws s3 cp \
      --only-show-errors \
      --region="${REGION}" \
      "${LOCAL_DIR}/${COPY_FILE}" "s3://${BUCKET}/${STATE}/${DATE}/${COPY_FILE}" 
  fi

}


main

