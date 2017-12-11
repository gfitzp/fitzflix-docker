#!/bin/bash

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

configure_s3cmd () {

	# Configure .s3cfg if it hasn't yet already been configured
	if [ ! -f /root/.s3cfg ]
	then

		# There doesn't appear to be any way to set the gpg_passphrase variable on the command line, and building the .s3cfg file per
		# https://stackoverflow.com/questions/38622898/configuring-s3cmd-non-interactively-through-bash-script?rq=1#comment64712342_38629201 and then
		# using sed to replace the gpg_passphrase line with one containing our passphrase seems to give a permissions error,
		# so instead we have to fake our way through the interactive configuration process.
	
		echo -e "${S3_ACCESS_KEY}\n${S3_SECRET_KEY}\n\n\n\n${S3_GPG_PASSPHRASE}\n\n\n\nN\nY\n" | s3cmd --configure

	fi

}


configure_postfix() {

	# Configure the Postfix mail installation if it hasn't yet already been configured
	if [ ! -f /recipient.txt ]
	then

		# This configuration allows us to send mail using the G Suite SMTP relay
		# https://support.google.com/a/answer/176600?hl=en
		#
		# **********
		# Be sure to either whitelist your IP address or provide a username/password as environment variables!
		# https://support.google.com/a/answer/2956491?hl=en
		# **********
		
		echo ${EMAIL_HOSTNAME} > /etc/mailname &&
		/usr/sbin/postconf -e myhostname=${EMAIL_HOSTNAME} &&
		/usr/sbin/postconf -e mydestination="localhost.localdomain, localhost" &&
		/usr/sbin/postconf -e inet_interfaces=loopback-only &&
		/usr/sbin/postconf -e inet_protocols=ipv4 &&
		/usr/sbin/postconf -e relayhost=[smtp-relay.gmail.com]:587 &&
		/usr/sbin/postconf -e smtp_always_send_ehlo=yes &&
		/usr/sbin/postconf -e smtp_helo_name=${EMAIL_HOSTNAME} &&
		/usr/sbin/postconf -e smtp_use_tls=yes &&
		/usr/sbin/postconf -e smtp_tls_CAfile=/etc/ssl/certs/ssl-cert-snakeoil.pem &&
		
		# Only enable SMTP authentication if a username / password have been defined
		if [ ! -z "${EMAIL_USERNAME}" ] && [ ! -z "${EMAIL_PASSWORD}" ]
		then
			
			echo "[smtp-relay.gmail.com]:587 ${EMAIL_USERNAME}:${EMAIL_PASSWORD}" > /etc/postfix/sasl/sasl_passwd &&
			/usr/sbin/postmap /etc/postfix/sasl/sasl_passwd &&
			chmod 0600 /etc/postfix/sasl/sasl_passwd* &&
		
			/usr/sbin/postconf -e smtp_sasl_auth_enable=yes &&
			/usr/sbin/postconf -e smtp_sasl_password_maps=hash:/etc/postfix/sasl/sasl_passwd &&
			/usr/sbin/postconf -e smtp_sasl_security_options=noanonymous
			
		fi &&
		
		# Rather than passing the To: and From: lines separately for each email,
		# we define those lines once in recipient.txt and pass that file to sendmail
		echo "To: ${EMAIL_RECIPIENT}" > /recipient.txt &&
		echo "From: Fitzflix <fitzflix@${EMAIL_HOSTNAME}>" >> /recipient.txt &&
	
		# Restart Postfix
		/usr/sbin/service rsyslog restart &&
		/usr/sbin/service postfix reload
		
	fi
	
}


create_queues () {

	# Export a queue for each queue type
	# We have different queue types depending on what can be done where:
	
	# archive:	can be done on local and remote machines (preferably remote, due to the overhead needed to encrypt each file before uploading to S3)
	#         	parallel command doesn't need a --return variable since there's nothing to be returned from the remote host
	mysql -h ${MYSQL_HOST:-${MYSQL_PORT_3306_TCP_ADDR}} -P ${MYSQL_PORT:-${MYSQL_PORT_3306_TCP_PORT:=3306}} -u ${MYSQL_USER} -p${MYSQL_PASSWORD} ${MYSQL_DB:="fitzflix_db"} -e "SELECT * FROM V_QUEUE WHERE task = 'archive';" -B --skip-column-names > /queue_archive.tsv &&
	
	# encode:	can be done on local and remote machines (preferably remote, as the built-in CPU on my NAS isn't very powerful)
	#			needs a --return variable to return the transcoded video to our library
	mysql -h ${MYSQL_HOST:-${MYSQL_PORT_3306_TCP_ADDR}} -P ${MYSQL_PORT:-${MYSQL_PORT_3306_TCP_PORT:=3306}} -u ${MYSQL_USER} -p${MYSQL_PASSWORD} ${MYSQL_DB:="fitzflix_db"} -e "SELECT * FROM V_QUEUE WHERE task = 'encode';" -B --skip-column-names > /queue_encode.tsv &&
	
	# local:	items that can ONLY be done on a local machine, or simple tasks that don't need much CPU that can be done anywhere (so we prefer to process on the local machine - no need to spin up a droplet)
	#			e.g. we can only delete files on the host by the host, we can request files to be restored from Glacier from any machine as it's just a webservice call, etc.
	mysql -h ${MYSQL_HOST:-${MYSQL_PORT_3306_TCP_ADDR}} -P ${MYSQL_PORT:-${MYSQL_PORT_3306_TCP_PORT:=3306}} -u ${MYSQL_USER} -p${MYSQL_PASSWORD} ${MYSQL_DB:="fitzflix_db"} -e "SELECT * FROM V_QUEUE WHERE task NOT IN ('archive', 'encode');" -B --skip-column-names > /queue_local.tsv &&
	
	# Return the number of tasks we are able to perform on remote machines
	# We'll use this number to determine how many droplets to create
	remoteQueueSize=$(($(wc -l < /queue_archive.tsv) + $(wc -l < /queue_encode.tsv))) &&
	
	echo "Number of remote tasks to currently process:" &&
	echo ${remoteQueueSize}
	
}


submit_ssh_key () {

	# Create the ssh key if one doesn't already exist
	if [ ! -f /root/.ssh/id_rsa ]
	then
	
		mkdir -p /root/.ssh/ &&

		ssh-keygen -t rsa -b 4096 -a 100 -N '' -f /root/.ssh/id_rsa &&
		
		# Set the key's permissions
		
		chmod -R 700 /root/.ssh &&
		chmod 644 /root/.ssh/id_rsa.pub &&
		chmod 600 /root/.ssh/id_rsa
	
	fi

	# Get the existing key's fingerprint and key value
	current_fingerprint=$(ssh-keygen -E md5 -lf /root/.ssh/id_rsa.pub | cut -f2 -d \ | cut -c 5-) &&
	current_key=$(cat /root/.ssh/id_rsa.pub) &&

	# Check DigitalOcean for our current key fingerprint and get its key_id, or submit our key if it's not already there
	python3 /fitzflix.py keycheck --apikey=${DO_API_KEY} --fingerprint="${current_fingerprint}" --sshkey="${current_key}"
	
}


# ========================================================================================
# ========================================================================================

# Use the dropletSpecs.txt file as a lock
# If it exists, then an earlier queue is still running

if [[ -f /dropletSpecs.txt ]]
then
	exit
fi


# =====
# Start the queue process

# Configure s3cmd by building .s3cfg file if it does not already exist
configure_s3cmd &&

# Configure Postfix if it hasn't yet been configured
configure_postfix &&

# Determine how many remote-capable tasks we have in queue
numRemoteTasks=$(create_queues | tail -n1) &&

# Exit if we don't have any items in any queue
if [[ $(($(wc -l < /queue_archive.tsv) + $(wc -l < /queue_encode.tsv) + $(wc -l < /queue_local.tsv) )) -eq 0 ]]
then
	exit
fi &&

# Choose a particular droplet type based on the number of remote tasks to complete
python3 /fitzflix.py choose --apikey=${DO_API_KEY} --remotetasks=${numRemoteTasks} --maxdroplets=${DO_MAX_DROPLETS:=5} --region=${DO_REGION:="nyc3"} --cpu=${DO_MIN_CPU:=1} --ram=${DO_MIN_RAM:=1} | tee /dropletSpecs.txt &&

# Send an email with the number and type of droplets that were created
queueSubject=$(echo "Subject: Fitzflix `date +\"%Y-%m-%d %H:%M:%S %z\"` Queue") &&
cat /recipient.txt <(echo "${queueSubject}") <(head -n -2 /dropletSpecs.txt) | /usr/sbin/sendmail -t &&

queueStart=$(tail -n1 /dropletSpecs.txt | tr -s '\t' | cut -f1) &&
dropletType=$(tail -n1 /dropletSpecs.txt | tr -s '\t' | cut -f2) &&
numCPUs=$(tail -n1 /dropletSpecs.txt | tr -s '\t' | cut -f3) &&
simultaneousEncodes=$(tail -n1 /dropletSpecs.txt | tr -s '\t' | cut -f4) &&
hourlyCost=$(tail -n1 /dropletSpecs.txt | tr -s '\t' | cut -f5) &&
numDroplets=$(tail -n1 /dropletSpecs.txt | tr -s '\t' | cut -f6) &&

escapedQueueStart=$(printf %q "${queueStart}") &&
escapedDropletType=$(printf %q "${dropletType}") &&
escapedNumCPUs=$(printf %q "${numCPUs}") &&
escapedSimultaneousEncodes=$(printf %q "${simultaneousEncodes}") &&
escapedHourlyCost=$(printf %q "${hourlyCost}") &&
escapedNumDroplets=$(printf %q "${numDroplets}") &&

# Start the queue history
mysql -h ${MYSQL_HOST:-${MYSQL_PORT_3306_TCP_ADDR}} -P ${MYSQL_PORT:-${MYSQL_PORT_3306_TCP_PORT:=3306}} -u ${MYSQL_USER} -p${MYSQL_PASSWORD} ${MYSQL_DB:="fitzflix_db"} -e "INSERT INTO history_queue (queue_start, droplet_type, num_cpus, simultaneous_tasks, hourly_cost, num_droplets) VALUES (FROM_UNIXTIME('${escapedQueueStart}'), '${escapedDropletType}', '${escapedNumCPUs}', '${escapedSimultaneousEncodes}', '${escapedHourlyCost}', '${escapedNumDroplets}');" &&


# Create droplets if we have at least one remote task in queue
if [[ ${numRemoteTasks} -gt 0 ]]
then

	# Double-check that we didn't leave any droplets running earlier
	# otherwise we get an error when we try to create a droplet with an existing droplet name

	# Destroy all droplets with the "fitzflix-transcoder" tag
	python3 /fitzflix.py delete --apikey=${DO_API_KEY} &&

	# Delete our list of remote nodes
	rm /sshloginfile.txt

	# Re-enable StrictHostKeyChecking
	mv /root/.ssh/config.backup /root/.ssh/config

	# Submit SSH key fingerprint to DigitalOcean
	submit_ssh_key &&
	
	# Get our SSH key fingerprint so we can add our SSH key to our transcoding droplets for passwordless login
	current_fingerprint=$(ssh-keygen -E md5 -lf /root/.ssh/id_rsa.pub | cut -f2 -d \ | cut -c 5-) &&
	
	# Prevent asking for each host's SSH key by temporarily disabling StrictHostKeyChecking
	# (We'll re-enable it when we destroy the droplets we just created)
	touch /root/.ssh/config &&
	cp /root/.ssh/config /root/.ssh/config.backup &&
	(echo "Host *" ; echo "StrictHostKeyChecking no") >> /root/.ssh/config &&
	
	
	# Create ${numDroplets} of ${dropletType}, each with 100GB of attached storage per ${simultaneousEncodes}.
	# e.g. 5 droplets of c-4 (High CPU, 4 CPU / 6 GB RAM) type, with 2 simultaneous encodes (meaning 200 GB of attached block storage) per droplet
	
	# Store each droplet's IP address in sshloginfile.txt
	# (We create them using parallel so we can create them all at once, rather than waiting 1+ min for each droplet to create in sequence)
	
	# We also check each droplet every 5 seconds until we see that the last application we install is available
	# (In this case, we check until we see that parallel is installed)
	
	# We also use GNU parallel with --no-notice throughout this script as the parallel application is quite chatty,
	# interactively prompting on first run to be run again with a --bibtex flag and a typed "will cite" promise,
	# but this script is meant to run on a headless NAS with as little manual intervention as possible!
	# See also: https://www.gnu.org/licenses/gpl-faq.html#RequireCitation
	
	parallel --no-notice -j0 'python3 /fitzflix.py create --apikey={1} --id={2} --size={3} --fingerprint={4} --simultaneous={5} --region={6} | tail -n1 | ( read dropletIP ; parallelStatus="1" ; while [ ${parallelStatus} -eq 1 ] ; do ssh -q ${dropletIP} [[ ! -f /usr/local/bin/parallel ]] && sleep 5 || parallelStatus="0" ; done && echo ${dropletIP} | tee -a /sshloginfile.txt ; )' ::: ${DO_API_KEY} ::: $(seq 1 ${numDroplets}) ::: ${dropletType} ::: ${current_fingerprint} ::: ${simultaneousEncodes} ::: ${DO_REGION:="nyc3"}

fi &&


# Keep processing tasks until we have nothing left in any queue
while [[ $(($(wc -l < /queue_archive.tsv) + $(wc -l < /queue_encode.tsv) + $(wc -l < /queue_local.tsv) )) -gt 0 ]]
do

	# archive:	can be done on local and remote machines (preferably remote, due to the overhead needed to encrypt each file before uploading to S3)
	#         	this parallel command doesn't need a --return variable since there's nothing to be returned from the remote host
	if [[ $(wc -l < /queue_archive.tsv) -gt 0 ]]
	then
		echo "Archiving files..." &&
		/usr/local/bin/parallel --no-notice -a /queue_archive.tsv --colsep '\t' --use-cpus-instead-of-cores --jobs ${simultaneousEncodes} --env DEFAULT_HANDBRAKE_PRESET --env MYSQL_DB --env MYSQL_HOST --env MYSQL_PASSWORD --env MYSQL_PORT --env MYSQL_USER --env NATIVE_LANGUAGE --env S3_ACCESS_KEY --env S3_BUCKET --env S3_GPG_PASSPHRASE --env S3_SECRET_KEY --sshloginfile /sshloginfile.txt --workdir /mnt/storage --basefile /mnt/storage/tasks.sh --basefile /mnt/storage/dropletSpecs.txt --transferfile /mnt/storage/Originals{1} --cleanup /mnt/storage/tasks.sh &&
		cat /recipient.txt <(echo "${queueSubject}") <(awk -F '\t' '{printf ("%s\t%s\n", $2, $1) }' /queue_archive.tsv) | /usr/sbin/sendmail -t
	fi &&
	
	# encode:	can be done on local and remote machines (preferably remote, as the built-in CPU on my NAS isn't very powerful)
	#			is separate from the archive task as it needs a --return variable to return the transcoded video to our library
	if [[ $(wc -l < /queue_encode.tsv) -gt 0 ]]
	then
		echo "Encoding files..." &&
		/usr/local/bin/parallel --no-notice -a /queue_encode.tsv --colsep '\t' --use-cpus-instead-of-cores --jobs ${simultaneousEncodes} --env DEFAULT_HANDBRAKE_PRESET --env MYSQL_DB --env MYSQL_HOST --env MYSQL_PASSWORD --env MYSQL_PORT --env MYSQL_USER --env NATIVE_LANGUAGE --env S3_ACCESS_KEY --env S3_BUCKET --env S3_GPG_PASSPHRASE --env S3_SECRET_KEY --sshloginfile /sshloginfile.txt --workdir /mnt/storage --basefile /mnt/storage/tasks.sh --basefile /mnt/storage/dropletSpecs.txt --transferfile /mnt/storage/Originals{1} --return /mnt/storage/Plex"{3}/{4}.m4v" --cleanup /mnt/storage/tasks.sh &&
		cat /recipient.txt <(echo "${queueSubject}") <(awk -F '\t' '{printf ("%s\t%s\n", $2, $1) }' /queue_encode.tsv) | /usr/sbin/sendmail -t
	fi &&
	
	# local:	items that can ONLY be done on a local machine, or simple tasks that don't need much CPU that can be done anywhere (so we prefer to process on the local machine - no need to spin up a droplet)
	#			e.g. we can only delete files on the host by the host, we can request files to be restored from Glacier from any machine as it's just a webservice call, etc.
	if [[ $(wc -l < /queue_local.tsv) -gt 0 ]]
	then
		echo "Processing local tasks..." &&
		/usr/local/bin/parallel --no-notice -a /queue_local.tsv --colsep '\t' --jobs 0 /mnt/storage/tasks.sh &&
		cat /recipient.txt <(echo "${queueSubject}") <(awk -F '\t' '{printf ("%s\t%s\n", $2, $1) }' /queue_local.tsv) | /usr/sbin/sendmail -t
	fi &&
	
	create_queues
	
done &&

# Destroy all droplets with the "fitzflix-transcoder" tag
python3 /fitzflix.py delete --apikey=${DO_API_KEY} &&

# Calculate how long the queue took
queueEnd=$(date +%s) &&
escapedQueueEnd=$(printf %q "${queueEnd}") &&

# Convert the seconds to hours
queueDuration=$(( ${queueEnd} - ${queueStart} )) &&
queueDuration=$(echo "((${queueDuration} / 60) + 59) / 60" | bc) &&

# Estimate queue cost
estimatedCost=$(echo "${hourlyCost} * ${queueDuration} * ${numDroplets}" | bc) &&

# Send an email when all droplets have been destroyed
cat /recipient.txt <(echo "${queueSubject}") <(echo "Estimated cost: \$`printf \"%.02f\n\" ${estimatedCost}`") | /usr/sbin/sendmail -t &&

# Delete our list of remote nodes
rm /dropletSpecs.txt &&

# Close out the queue history
mysql -h ${MYSQL_HOST:-${MYSQL_PORT_3306_TCP_ADDR}} -P ${MYSQL_PORT:-${MYSQL_PORT_3306_TCP_PORT:=3306}} -u ${MYSQL_USER} -p${MYSQL_PASSWORD} ${MYSQL_DB:="fitzflix_db"} -e "UPDATE history_queue SET queue_end = FROM_UNIXTIME('${queueEnd}') WHERE queue_start = FROM_UNIXTIME('${escapedQueueStart}');" &&

# If there was a need to spin up a droplet, eliminate all traces of the remote nodes
if [[ ${numRemoteTasks} -gt 0 ]]
then
	
	# Delete the list of nodes we could log in to
	rm /sshloginfile.txt &&
	
	# Re-enable StrictHostKeyChecking
	mv /root/.ssh/config.backup /root/.ssh/config
	
fi