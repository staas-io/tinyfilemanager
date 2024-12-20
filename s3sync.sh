#!/bin/bash
set -eo pipefail

ME=$(basename "$0")

PARSED_KEYS=($(echo $AWS_ACCESS_KEY_ID | tr ',' ' '))
PARSED_SECS=($(echo $AWS_SECRET_ACCESS_KEY | tr ',' ' '))
PARSED_BUCS=($(echo $AWS_BUCKET_NAME | tr ',' ' '))
PARSED_ENPS=($(echo $S3_ENDPOINT | tr ',' ' '))
PARSED_SPAS=($(echo $S3SYNC_PATH | tr ',' ' '))

check() {
	len=${#PARSED_KEYS[@]}
	echo "len:$len"

	for (( i=0; i<len; i++ )); do
		AWS_ACCESS_KEY_ID="${PARSED_KEYS[$i]}"
		AWS_SECRET_ACCESS_KEY="${PARSED_SECS[$i]}"
		AWS_BUCKET_NAME="${PARSED_BUCS[$i]}"
		S3_BUCKET="${AWS_BUCKET_NAME:-}"
		S3_ENDPOINT="${PARSED_ENPS[$i]}"
		S3_ENDPOINT_URL="${S3_ENDPOINT:-}"
		S3SYNC_PATH="${PARSED_SPAS[$i]}"
		S3SYNC_PATH="${S3SYNC_PATH:-s3://${AWS_BUCKET_NAME}/}"

		echo "---"
		echo "AWS_ACCESS_KEY_ID:$AWS_ACCESS_KEY_ID"
		echo "AWS_SECRET_ACCESS_KEY:$AWS_SECRET_ACCESS_KEY"
		echo "AWS_BUCKET_NAME:$AWS_BUCKET_NAME"
		echo "S3_BUCKET:$S3_BUCKET"
		echo "S3_ENDPOINT_URL:$S3_ENDPOINT_URL"
		echo "S3SYNC_PATH:$S3SYNC_PATH"
		echo "S3SYNC_LOCAL_DIR:$S3SYNC_LOCAL_DIR"
	done
}

download() {
	AWS_ACCESS_KEY_ID="${PARSED_KEYS[0]}"
	AWS_SECRET_ACCESS_KEY="${PARSED_SECS[0]}"
	AWS_BUCKET_NAME="${PARSED_BUCS[0]}"
	S3_BUCKET="${AWS_BUCKET_NAME:-}"
	S3_ENDPOINT="${PARSED_ENPS[0]}"
	S3_ENDPOINT_URL="${S3_ENDPOINT:-}"
	S3SYNC_PATH="${PARSED_SPAS[0]}"
	S3SYNC_PATH="${S3SYNC_PATH:-s3://${AWS_BUCKET_NAME}/}"

	if [[ -f "${S3SYNC_LOCAL_DIR%/}/s3sync.downloaded" ]]; then echo 'Info: local dir is already downloaded, remove the s3sync.downloaded to retry'; return 0; fi

	if which s5cmd >/dev/null; then
		cmd="s5cmd --endpoint-url='${S3_ENDPOINT}' sync $@ '${S3SYNC_PATH%/}/*' '${S3SYNC_LOCAL_DIR%/}/'"
	else
		cmd="aws s3 sync '${S3SYNC_PATH}' '${S3SYNC_LOCAL_DIR}' --endpoint='${S3_ENDPOINT}' $@"
	fi

	# echo $cmd $@
	eval $cmd

	# fix any permissions issues%
	chmod -vR a=rwx "${S3SYNC_LOCAL_DIR}"

	echo $(date '+%Y-%m-%d-%H:%M:%S') > "${S3SYNC_LOCAL_DIR%/}/s3sync.downloaded"
}

upload() {
	len=${#PARSED_KEYS[@]}

	for (( i=0; i<len; i++ )); do
		AWS_ACCESS_KEY_ID="${PARSED_KEYS[$i]}"
		AWS_SECRET_ACCESS_KEY="${PARSED_SECS[$i]}"
		AWS_BUCKET_NAME="${PARSED_BUCS[$i]}"
		S3_BUCKET="${AWS_BUCKET_NAME:-}"
		S3_ENDPOINT="${PARSED_ENPS[$i]}"
		S3_ENDPOINT_URL="${S3_ENDPOINT:-}"
		S3SYNC_PATH="${PARSED_SPAS[$i]}"
		S3SYNC_PATH="${S3SYNC_PATH:-s3://${AWS_BUCKET_NAME}/}"

		if which s5cmd >/dev/null; then
			cmd="s5cmd --endpoint-url='${S3_ENDPOINT}' sync --delete $@ '${S3SYNC_LOCAL_DIR%/}/*' '${S3SYNC_PATH%/}/'"
		else
			cmd="aws s3 sync '${S3SYNC_LOCAL_DIR}' '${S3SYNC_PATH}' --endpoint='${S3_ENDPOINT}' --delete $@"
		fi

		# echo $cmd
		eval $cmd || true
	done
}

watch_upload() {
	echo "...watching '$S3SYNC_LOCAL_DIR'"
	if [ ! -d "$S3SYNC_LOCAL_DIR" ]; then return 0; fi

	LOCK="./watch.lock"
	rm -f $LOCK

	inotifywait -mr "${S3SYNC_LOCAL_DIR}" -e create -e delete -e move -e modify --format '%w%f %e' | \
	while read -r file _ ; do
		# ignore sqlite tmp files
		if [[ "${file}" =~ \.db-(journal|wal|shm)$ ]]; then
			continue
		fi

		if [[ -f $LOCK ]]; then continue; fi

		touch $LOCK
		sh -c "sleep 66s;rm -f $LOCK" &
		sleep 60 # sleeping before execution to accumulate any other file changes...
		upload "$@" 2>&1 || true
		rm -f $LOCK
	done
}

main() {
	case "${1}" in
		download)
			download "${@:2}"
			;;
		upload)
			upload "${@:2}"
			;;
		check)
			check "${@:2}"
			;;
		auto)
			download "${@:2}"
			sleep 10
			watch_upload "${@:2}"
			;;
		help|--help|-h)
			cat <<-EOF
			Usage: ${ME} [command] [extra parameters]

			Commands:
			  download: download all remote files to S3SYNC_LOCAL_DIR and exit
			  ---
			  upload: sync S3SYNC_LOCAL_DIR to S3
			    Ex: /app/s3sync.sh upload --exclude "*.txt" --exclude "*.gz"
			  ---
			  auto: watch for changes in S3SYNC_LOCAL_DIR and sync S3SYNC_LOCAL_DIR to S3
			    Ex: /app/s3sync.sh auto --exclude "*.txt" --exclude "*.gz"
			EOF
			exit 0
			;;
		*)
			echo "$(date -u): Unknown command: ${1}" > /dev/stderr
			exit 1
			;;
	esac
}

if [[ -n "${S3SYNC_ENABLE}" ]]; then main $@; else echo 'S3SYNC_ENABLE is not set'; sleep infinity; fi
