"""Fitzflix

Usage:
  fitzflix.py choose --apikey=TOKEN [--remotetasks=NUM] [--maxdroplets=NUM] [--region=REGION] [--cpu=NUM] [--ram=NUM]
  fitzflix.py create --apikey=TOKEN --id=ID --size=SIZE (--sshid=ID... | --fingerprint=ID...) [--simultaneous=NUM] [--region=REGION]
  fitzflix.py delete --apikey=TOKEN [--orphans-only]
  fitzflix.py keycheck --apikey=TOKEN --fingerprint=ID --sshkey=KEY

Options:
  -h, --help          Show this help.
  --cpu=NUM           Minimum number of CPUs required per encoder task. [default: 1]
  --fingerprint=ID    SSH public key fingerprint.
  --id=NUM            ID of droplet being created.
  --maxdroplets=NUM   Maximum number of droplets to run. [default: 5]
  --orphans-only      Find and delete only unattached block storage volumes.
  --ram=NUM           Minimum required number of gigabytes of RAM per droplet. [default: 1]
  --region=REGION     Region where this droplet should be created. [default: nyc3]
  --simultaneous=NUM  Number of tasks to perform in parallel. [default: 1]
  --size=SIZE         DigitalOcean droplet slug identifier.
  --sshid=ID          DigitalOcean SSH key identification number.
  --sshkey=KEY        SSH public key string.
  --remotetasks=NUM   Total number of remote tasks to perform. [default: 0]

"""

import datetime, json, math, os, pprint, requests, sys, time
from operator import itemgetter
from docopt import docopt

p = pprint.PrettyPrinter()
now = datetime.datetime.now()

BASEURL = "https://api.digitalocean.com"

# We show each volume as:
# fitzflix-storage-01, fitzflix-storage-02, fitzflix-storage-03, etc.
STORAGENAME = "fitzflix-storage"

# Each volume will be attached to a corresponding droplet:
# fitzflix-transcoder-01, fitzflix-transcoder-02, fitzflix-transcoder-03, etc.
DROPLETNAME = "fitzflix-transcoder"


def droplet_choose(token, numTasks=0, maxDroplets=5, region="nyc3", minCPU=1, minRAM=1):

	if numTasks > 0:

		# Count how many droplets currently exist, and subtract that number from the max number of droplets we can create
	
		try:
			response = requests.get(BASEURL + "/v2/droplets", headers = {'Authorization': 'Bearer ' + token})
			response.raise_for_status()
		
		except requests.exceptions.HTTPError as err:
	
			print(err)
		
			sys.exit(1)
		
		numExistingDroplets = response.json()['meta']['total']
	
		maxDroplets = maxDroplets - numExistingDroplets
		
		if maxDroplets == 0:
		
			print("Maximum number of droplets are currently running!")
			
			sys.exit(1)

		# Review available droplet types and find the most economical type to use
		# for the number of videos we have to process
	
		availableDroplets = []
	
		response = requests.get(BASEURL + "/v2/sizes", headers = {'Authorization': 'Bearer ' + token})

		# print(response.url)
		# print("HTTP status code: {}".format(response.status_code))
		# p.pprint(response.json())
		# print()
	
		for droplet in response.json()['sizes']:
	
			# Select only those droplet types that are available in our requested region
			# and have at least the number of CPUs and memory we want
			if droplet['available'] == True and region in droplet['regions'] and droplet['vcpus'] >= minCPU and droplet['memory'] >= (minRAM * 1024):
				
				simultaneousEncodes = math.floor(droplet['vcpus'] / minCPU)
				
				# Check to be sure we have at least the minimum requested RAM per encoder task
				# If not, move to the next droplet type
				if int(droplet['memory'] / simultaneousEncodes) < (minRAM * 1024):
				
					continue
					
				# Estimate the number of possible encodes per hour
			
				# TODO: Improve this with statistical analysis of how different resolutions
				# (e.g. SD / 720p / 1080p) and encoder tuning (animation / grain / film) affect
				# encoding times
			
				# High-CPU droplet types can process more encodes per hour
				#
				# "Customers in our early access period have seen up to four times
				#  the performance of Standard Droplet CPUs, and on average see
				#  about 2.5 times the performance"
				#   - https://blog.digitalocean.com/introducing-high-cpu-droplets/
				#
				# Let's conservatively estimate 2x performance gains
			
				if droplet['slug'].startswith('c-'):
			
					encodesPerHour = droplet['vcpus'] * 2
				
				else:
			
					encodesPerHour = droplet['vcpus']
				
				dropletHours = numTasks / encodesPerHour
			
				# Limit the number of droplets we can spin up to the max number we can use
				if math.ceil(dropletHours) > maxDroplets:
			
					numDroplets = maxDroplets
				
				else:
			
					# We spin up one droplet per calculated droplethour
					numDroplets = math.ceil(dropletHours)
				
				# droplethours / number of droplets = number of hours it will take to process
				# e.g. 10 droplethours / 10 droplets = 1 hour
				#      10 droplethours /  5 droplets = 2 hours
				hours = math.ceil(dropletHours / numDroplets)
			
				# Estimate how much it will cost to run x droplets for y hours
				dropletCost = droplet['price_hourly']
				storageCost = 0.015 * simultaneousEncodes
				estimatedCost = (dropletCost + storageCost) * numDroplets * hours
			
				# Add a tuple with data for this droplet type to our list of available droplets	
				availableDroplets.append((droplet['slug'], droplet['vcpus'], droplet['memory'], encodesPerHour, simultaneousEncodes, dropletCost, storageCost, dropletHours, numDroplets, hours, estimatedCost))
				
		# Exit if we weren't able to find any droplets that match our needs
		if len(availableDroplets) == 0:
		
			print("No droplets satisfied the minimum requirements!")
			
			sys.exit(1)
			
		# Determine which droplet type is the most cost efficient
		# It can be more efficient to spin up many slower droplets over few faster ones

		# First we will sort all droplets by their cost from lowest to highest
		availableDroplets = sorted(availableDroplets, key=itemgetter(10))
	
		# Finally we sort the sorted droplets by how long they will take to process
		# Result: a list sorted first by how fast it will take, then by estimated cost
		# (This sort can be commented out if you only care about choosing the least expensive option
		#  and not about choosing the fastest option that costs the least)
		availableDroplets = sorted(availableDroplets, key=itemgetter(9))
	
		# The first entry in the sorted list will be the droplet type that will take the least
		# amount of time, and will cost the least among all that will take that same length of time
	
		# p.pprint(availableDroplets)
	
		print(availableDroplets[0][0])
		print("CPU:", availableDroplets[0][1])
		print("RAM:", availableDroplets[0][2])
	#  	print("Encodes per hour:", availableDroplets[0][3])
		print("Simultaneous jobs:", availableDroplets[0][4])
		print("Droplet cost:", availableDroplets[0][5])
		print("Storage cost:", availableDroplets[0][6])
	#  	print("Droplet hours:", availableDroplets[0][7])
		print("Number of droplets:", availableDroplets[0][8])
	#  	print("Hours:", availableDroplets[0][9])
	#  	print("Estimated cost:", availableDroplets[0][10])
		print()
	
		queueStart = int(time.time())
		dropletType = availableDroplets[0][0]
		numCPUs = availableDroplets[0][1]
		simultaneousEncodes = availableDroplets[0][4]
		hourlyCostPerDroplet = availableDroplets[0][5] + availableDroplets[0][6]
		numDroplets = availableDroplets[0][8]
	
		print("{0}\t{1}\t{2}\t{3}\t{4}\t{5}".format("Queue Start", "Droplet Type", "CPUs", "Simultaneous", "Hourly Cost", "Droplets", ))
		print("{0}\t{1}\t\t{2}\t{3}\t\t{4}\t\t{5}".format(queueStart, dropletType, numCPUs, simultaneousEncodes, hourlyCostPerDroplet, numDroplets))
		
	else:

		print("local")
		print("CPU: 0")
	# 	print("Encodes per hour: 0")
		print("Simultaneous jobs: 0")
		print("Droplet cost: 0")
		print("Storage cost: 0")
	#  	print("Droplet hours: 0")
		print("Number of droplets: 0")
	#  	print("Hours: 0")
	#  	print("Estimated cost: 0")
		print()

		queueStart = int(time.time())
		dropletType = "local"
		numCPUs = 0
		simultaneousEncodes = 0
		hourlyCostPerDroplet = 0
		numDroplets = 0

		print("{0}\t{1}\t{2}\t{3}\t{4}\t{5}".format("Queue Start", "Droplet Type", "CPUs", "Simultaneous", "Hourly Cost", "Droplets", ))
		print("{0}\t{1}\t\t{2}\t{3}\t\t{4}\t\t{5}".format(queueStart, dropletType, numCPUs, simultaneousEncodes, hourlyCostPerDroplet, numDroplets))

	return


def droplet_create(token, identifier, dropletType, volumeID, sshKeys, region="nyc3"):

	storageIdentifier = "{}-{}".format(STORAGENAME, identifier.zfill(2))
	dropletIdentifier = "{}-{}".format(DROPLETNAME, identifier.zfill(2))

	dropletStatus = None
	
	# potential droplet statuses are "new", "active", "off", "archive"
	#
	# new		= being initialized
	# active	= on
	# off		= off
	# archive	= destroyed
	
	while dropletStatus != 'completed':
	
		# create the droplet
		
		payload = {
			"name": dropletIdentifier,
			"region": region,
			"size": dropletType,
			"image": "ubuntu-16-04-x64",
			"volumes": [volumeID],
			"ssh_keys": sshKeys,
			"user_data": """#!/bin/bash

				sudo mkfs.ext4 -F /dev/disk/by-id/scsi-0DO_Volume_{0} &&
				sudo mkdir -p /mnt/storage &&
				sudo mount -o discard,defaults /dev/disk/by-id/scsi-0DO_Volume_{0} /mnt/storage &&
				echo /dev/disk/by-id/scsi-0DO_Volume_{0} /mnt/storage ext4 defaults,nofail,discard 0 0 | sudo tee -a /etc/fstab &&

				apt-get -y update &&
				apt-get install software-properties-common &&
				apt-key adv --recv-keys --keyserver hkp://keyserver.ubuntu.com:80 0xF1656F24C74CD1D8 &&
				add-apt-repository 'deb [arch=amd64,i386,ppc64el] http://nyc2.mirrors.digitalocean.com/mariadb/repo/10.2/ubuntu xenial main' &&
				add-apt-repository -y ppa:stebbins/handbrake-releases &&

				apt-get -y update &&
				apt-get -y install handbrake-cli make mariadb-client mediainfo perl python python-pip python3 python3-pip &&
				
				pip2 install --upgrade pip &&
				
				pip2 install s3cmd &&
		
				pip3 install --upgrade pip &&

				curl -o /tmp/parallel-20171022.tar.bz2 -L http://ftpmirror.gnu.org/parallel/parallel-20171022.tar.bz2 &&
				tar -xjf /tmp/parallel-20171022.tar.bz2 -C /tmp &&
				/tmp/parallel-20171022/configure && make && make install &&
		
				apt-get clean &&
				rm -rf /tmp/* /var/lib/apt/lists/* /var/tmp/*""".format(storageIdentifier),
			"tags": ["fitzflix-transcoder"]
		}
		
		try:
			# send POST request to '/v2/droplets' to create the droplet
			response = requests.post(BASEURL + "/v2/droplets", headers = {'Authorization': 'Bearer ' + token}, json = payload)
			response.raise_for_status()
		
		except requests.exceptions.HTTPError as err:

			print(err)
			print()
			
			p.pprint(payload)
			print(response.text)
			
			# The volume was created, but our attempt to create a droplet failed,
			# so before we exit we attempt to destroy the volume if we can
			
			volume_orphans(token)
					
			sys.exit(1)
		
		print("Droplet creation:")
		print(response.url)
		print("HTTP status code: {}".format(response.status_code))
		p.pprint(response.json())
		print()
		
		dropletID = str(response.json()['droplet']['id'])
		actionID = response.json()['links']['actions'][0]['id']
		
		# wait for the droplet to be created
		time.sleep(60)
		
		try:
			# send GET request to '/v2/actions/$ACTION_ID' to check the creation status
			response = requests.get(BASEURL + "/v2/actions/{}".format(actionID), headers = {'Authorization': 'Bearer ' + token})
			response.raise_for_status()
		
		except requests.exceptions.HTTPError as err:

			print(err)
			print()
			
			# The volume was created, but our attempt to check the droplet status failed,
			# so before we exit we attempt to destroy the droplet and the volume if we can
			
			volume_detach(token, [dropletID])
			
			volume_delete(token, [volumeID])
			
			print("Destroying droplet {}...".format(dropletID))
			response = requests.delete(BASEURL + "/v2/droplets/" + dropletID, headers = {'Authorization': 'Bearer ' + token})
	
			print(response.url)
			print("HTTP status code: {}".format(response.status_code))
			print()
			
			sys.exit(1)
		
		print("Droplet creation status:")
		print(response.url)
		print("HTTP status code: {}".format(response.status_code))
		p.pprint(response.json())
		print()
		
		dropletStatus = response.json()['action']['status']
		
		# keep checking the droplet status until it's ready
		while dropletStatus == 'in-progress':
		
			time.sleep(10)
			
			try:
				# send GET request to '/v2/actions/$ACTION_ID' to check the creation status
				response = requests.get(BASEURL + "/v2/actions/{}".format(actionID), headers = {'Authorization': 'Bearer ' + token})
				response.raise_for_status()
		
			except requests.exceptions.HTTPError as err:

				print(err)
				print()

				# The volume was created, but our attempt to check the droplet status failed,
				# so before we exit we attempt to destroy the droplet and the volume if we can

				volume_detach(token, [dropletID])
			
				volume_delete(token, [volumeID])
			
				print("Destroying droplet {}...".format(dropletID))
				response = requests.delete(BASEURL + "/v2/droplets/" + dropletID, headers = {'Authorization': 'Bearer ' + token})
	
				print(response.url)
				print("HTTP status code: {}".format(response.status_code))
				print()

				sys.exit(1)
			
			print("HTTP status code: {}".format(response.status_code))
			
			print("Droplet creation status: {}".format(response.json()['action']['status']))
			print()
		
			dropletStatus = response.json()['action']['status']
			
		if dropletStatus == "errored":
		
			print("Failed to create {}! Trying again...".format(dropletIdentifier))
			print()
	
	try:
		response = requests.get(BASEURL + "/v2/droplets/" + dropletID, headers = {'Authorization': 'Bearer ' + token})
		
		print("Droplet specifications:")	
		print(response.url)
		print("HTTP status code: {}".format(response.status_code))
		p.pprint(response.json())
		print()
	
		print("{} created!".format(dropletIdentifier))
			
		return response.json()['droplet']['networks']['v4'][0]['ip_address']
	
	except requests.exceptions.HTTPError as err:
	
		print(err)
		print()
		
		# The volume was created, and the droplet was created, but our attempt to get the
		# droplet IP address failed. We either need to keep trying to get the IP address,
		# or we need to detach the volume, destroy the droplet, and create a new droplet
		# with the existing storage volume.

		volume_detach(token, [dropletID])
	
		print("Destroying droplet {}...".format(dropletID))
		response = requests.delete(BASEURL + "/v2/droplets/" + dropletID, headers = {'Authorization': 'Bearer ' + token})

		print(response.url)
		print("HTTP status code: {}".format(response.status_code))
		print()
		
		
def droplet_delete(token):
		
	# Get a list of transcoder droplets
	try:
		response = requests.get(BASEURL + "/v2/droplets", headers = {'Authorization': 'Bearer ' + token}, params = {'tag_name': DROPLETNAME})
		response.raise_for_status()
		
	except requests.exceptions.HTTPError as err:
	
		print(err)
		
		sys.exit(1)
	
	if response.json()['meta']['total'] == 0:
	
		print("No droplets to destroy!")
		
		sys.exit()
		
	else:
	
		if response.json()['meta']['total'] == 1:
		
			print("1 droplet to destroy.")
			
		else:
			
			print("{} droplets to destroy.".format(response.json()['meta']['total']))
			
		print("Now witness the firepower of this fully-armed and operational Python script!")
		print()
		
	droplets = response.json()['droplets']
	volumes = []

	# Detach volumes from all of the droplets
	volumes = volume_detach(token, droplets)
	
	# For each now-detached volume, delete it
	volume_delete(token, volumes)
	
	print("Destroying droplets...")
	
	# Delete all droplets with the DROPLETNAME tag
	response = requests.delete(BASEURL + "/v2/droplets", headers = {'Authorization': 'Bearer ' + token}, data = {"tag_name": DROPLETNAME})
	
	print(response.url)
	print("HTTP status code: {}".format(response.status_code))
	print()
	
	time.sleep(2)
	
	counter = 0
	
	# If the delete request was not successful, resubmit the delete request
	while response.status_code != 204 and counter < 10:
	
		response = requests.delete(BASEURL + "/v2/droplets", headers = {'Authorization': 'Bearer ' + token}, data = {"tag_name": DROPLETNAME})
		
		print("Droplet destruction status:")
		print(response.url)
		print("HTTP status code: {}".format(response.status_code))
		print()
	
		counter = counter + 1
		
		time.sleep(2)
		
	time.sleep(5)
	
	# Check the number of transcoders left, if it's 0 then all transcoders have been deleted
	
	response = requests.get(BASEURL + "/v2/droplets", headers = {'Authorization': 'Bearer ' + token}, data = {"tag_name": DROPLETNAME})
	
	print("Droplet destruction confirmation:")
	print(response.url)
	print("HTTP status code: {}".format(response.status_code))
	p.pprint(response.json())
	print()
	
	if response.json()['meta']['total'] == 0:
	
		print("Droplets destroyed.")
		
	else:
	
		print("Droplets still provisioned!!")
		
		sys.exit(1)
		
		
def ssh_key_check(token, current_fingerprint, current_key):

	try:
	
		# Get a list of existing SSH keys at DigitalOcean
		response = requests.get(BASEURL + "/v2/account/keys", headers = {'Authorization': 'Bearer ' + token})
		response.raise_for_status()
		
	except requests.exceptions.HTTPError as err:
		print(err)
		sys.exit(1)
		
	print("Key response:")
	print(response.url)
	print("HTTP status code: {}".format(response.status_code))
	p.pprint(response.json())
	print()
	
	
	# Check to see if the existing SSH key is already in our DigitalOcean account.
	# If it is, then get the key's ID -- we need to submit the key ID when
	# we deploy droplets so we can log in to those droplets without needing a
	# username or password.
	
	for key in response.json()['ssh_keys']:
	
		# If the key is already at Digitalocean, print the key ID and exit
		if key['fingerprint'] == current_fingerprint:
		
			print(key['id'])
			sys.exit()
	
	# If we reach this point, we haven't exited, which means the SSH key has not yet
	# been submitted to DigitalOcean
	
	# Prepare the key's name and the key itself for submission
	# We'll name the with today's date to differentiate between keys created for different
	# container deployments, so older inactive ones can be found and deleted
	# (e.g. "fitzflix-2017-11-08")
	
	key_data = {
		"name": "fitzflix-{}".format(now.strftime("%Y-%m-%d")),
		"public_key": current_key
	}
	
	try:
	
		# Submit the current key to DigitalOcean
		response = requests.post(BASEURL + "/v2/account/keys", headers = {'Authorization': 'Bearer ' + token}, json = key_data)
		response.raise_for_status()
		
	except requests.exceptions.HTTPError as err:
		print(err)
		sys.exit(1)
		
	print("Key creation:")
	print(response.url)
	print("HTTP status code: {}".format(response.status_code))
	p.pprint(response.json())
	print()
	
	# Print the submitted key's ID
	print(response.json()['ssh_key']['id'])


def volume_create(token, identifier, simultaneousEncodes=1, region="nyc3"):

	storageIdentifier = "{}-{}".format(STORAGENAME, identifier.zfill(2))
	dropletIdentifier = "{}-{}".format(DROPLETNAME, identifier.zfill(2))

	# create the block storage

	payload = {
		"size_gigabytes": 100 * simultaneousEncodes,
		"name": storageIdentifier,
		"description": "Storage for {}".format(dropletIdentifier),
		"region": region
	}
	
	try:
		# send POST request to '/v2/volumes' to create the block storage
		response = requests.post(BASEURL + "/v2/volumes", headers = {'Authorization': 'Bearer ' + token}, data = payload)
		response.raise_for_status()
		
	except requests.exceptions.HTTPError as err:
	
		print(err)
		print()
		
		# The attempt to create the volume immediately failed,
		# so there would likely be no volume for us to destroy before we exit.
		sys.exit(1)
	
	print("Block storage creation:")
	print(response.url)
	print("HTTP status code: {}".format(response.status_code))
	p.pprint(response.json())
	print()
	
	volumeID = response.json()['volume']['id']
	
	# wait for block storage volume to be created
	time.sleep(10)
	
	try:
		# send GET request to '/v2/volumes/${VOLUME_ID}' to check the creation status
		response = requests.get(BASEURL + "/v2/volumes/{}".format(volumeID), headers = {'Authorization': 'Bearer ' + token})
		response.raise_for_status()
		
	except requests.exceptions.HTTPError as err:
	
		print(err)
		print()
		
		# The volume may have been created, but our attempt to check the status failed
		# so before we exit we attempt to destroy the volume if we can
		
		volume_orphans(token)
		
		sys.exit(1)
	
	print("Block storage creation status:")
	print(response.url)
	print("HTTP status code: {}".format(response.status_code))
	p.pprint(response.json())
	print()
	
	return volumeID
	
	
# volume_delete()
#
# Input: array of volume IDs
# Returns: none
#
# Iterates through array of volume IDs and submits delete requests for each volume provided
def volume_delete(token, volumes):

	print("Deleting volumes...")
	
	for volumeID in volumes:
		
		# Submit a delete request for this volume
		try:
			response = requests.delete(BASEURL + "/v2/volumes/" + volumeID, headers = {'Authorization': 'Bearer ' + token})
			response.raise_for_status()
			
		except requests.exceptions.HTTPError as err:

			print(err)
			print()
			
			print(response.text)
		
		print(response.url)
		print("HTTP status code: {}".format(response.status_code))
		
		time.sleep(2)
		
		# If the delete request was unsuccessful, resubmit the delete request a limited number of times until we succeed
		#
		# "No response body will be sent back, but the response code will indicate success.
		#  Specifically, the response code will be a 204, which means that the action
		#  was successful with no returned body data."
		#  - https://developers.digitalocean.com/documentation/v2/#delete-a-block-storage-volume
		
		counter = 0
		
		while response.status_code != 204 and counter < 10:
		
			try:
				response = requests.delete(BASEURL + "/v2/volumes/" + volumeID, headers = {'Authorization': 'Bearer ' + token})
				
			except requests.exceptions.HTTPError as err:

				print(err)
				print()
			
				print(response.text)
			
			print()
			print("Volume delete status:")
			print(response.url)
			print("HTTP status code: {}".format(response.status_code))
		
			counter = counter + 1
			
			time.sleep(2)
			
		if response.status_code == 204:
		
			print("Deleted {}".format(volumeID))
			print()
		
		else:
			
			print("Failed to delete a volume and droplets are still provisioned!!")
			
			sys.exit(1)
			
			
# volume_detach()
#
# Input: array of droplet IDs
# Returns: array of volume IDs
#
# Iterates through array of droplet IDS and submits detach requests for each attached volume
def volume_detach(token, droplets):

	volumes = []
	
	for droplet in droplets:

		# Detach each volume from this droplet
		print("Detaching volumes from {}...".format(droplet['name']))
	
		for volumeID in droplet['volume_ids']:
	
			volumes.append(volumeID)
		
			payload = {
				"type": "detach",
				"droplet_id": droplet['id']
			}
		
			try:
		
				response = requests.post(BASEURL + "/v2/volumes/" + volumeID + "/actions", headers = {'Authorization': 'Bearer ' + token}, json = payload)
				response.raise_for_status()
			
			except requests.exceptions.HTTPError as err:
		
				print(err)
				print()
				
				print("UNABLE TO DETACH VOLUME {}!".format(volumeID))
			
				sys.exit(1)
				
			print(response.url)
			print("HTTP status code: {}".format(response.status_code))
			p.pprint(response.json())
			print()
			
			actionID = str(response.json()['action']['id'])
			detach_status = "in-progress"
		
			# Keep checking to see if the detach action is still in progress
			while detach_status == "in-progress" or detach_status == "errored":
		
				try:
				
					time.sleep(2)
					response = requests.get(BASEURL + "/v2/volumes/" + volumeID + "/actions/" + actionID, headers = {'Authorization': 'Bearer ' + token})
					response.raise_for_status()
			
				except requests.exceptions.HTTPError as err:
		
					print(err)
					print()
			
					print("UNABLE TO DETACH VOLUME {}!".format(volumeID))
			
					sys.exit(1)
					
				print("Detach status:")
				print(response.url)
				print("HTTP status code: {}".format(response.status_code))
				p.pprint(response.json())
				print()
					
				detach_status = response.json()['action']['status']
				
				# We weren't able to detach the volume, so we'll try again
				if detach_status == "errored":
			
					print("Failed to detach volume {} from {}! Trying again...".format(volumeID, droplet['name']))
				
			print("Detached {}".format(volumeID))
		
		print()
		
	return volumes
	

# volume_orphans()
#
# Input: none
# Returns: none
#
# Checks for any block storage volumes containing STORAGENAME (e.g. "fitzflix-storage") and
# passes a list of those volume IDs for deletion, as Digital Ocean will complain if we try
# to create a second volume with the same name.
def volume_orphans(token):

	print("Checking for any orphaned storage volumes...")
	print()
		
	orphanedVolumes = []
	
	# Get a list of the storage volumes
	try:
		response = requests.get(BASEURL + "/v2/volumes", headers = {'Authorization': 'Bearer ' + token})
		response.raise_for_status()
		
	except requests.exceptions.HTTPError as err:

		print(err)
		print()
		
		print(response.text)
		
		sys.exit(1)
		
	# Check each storage volume
	for volume in response.json()['volumes']:
	
		# Create a list any volumes that contain STORAGENAME and are not attached to any droplets
		if STORAGENAME in volume['name'] and len(volume['droplet_ids']) == 0:
		
			orphanedVolumes.append(volume['id'])
			
	# If we have 1 or more volumes containing STORAGENAME, pass to volume_delete() for deletion
	if len(orphanedVolumes) > 0:
	
		volume_delete(token, orphanedVolumes)


if __name__ == "__main__":

	# Get command line arguments
	arguments = docopt(__doc__, version="Fitzflix 1.0")
	
	p.pprint(arguments)
	
	# Check each variable to make sure it's valid
	# (number variables are numbers, text variables are text, etc.)
	
	# TODO: check variables
	
	
	# Process tasks based on the command line arguments given
	
	# Choose droplet type based on number of tasks to process
	if arguments['choose']:

		droplet_choose(arguments['--apikey'], int(arguments['--remotetasks']), int(arguments['--maxdroplets']), arguments['--region'], int(arguments['--cpu']), int(arguments['--ram']))
	
	# Create a volume, create a droplet, and attach them together
	elif arguments['create']:

		volumeID = volume_create(arguments['--apikey'], arguments['--id'], int(arguments['--simultaneous']), arguments['--region'])
		
		sshkeys = []
		sshkeys = arguments['--sshid'] + arguments['--fingerprint']
	
		dropletIP = droplet_create(arguments['--apikey'], arguments['--id'], arguments['--size'], volumeID, sshkeys, arguments['--region'])
	
		print("root@{}".format(dropletIP))
	
	# Delete the droplet
	elif arguments['delete']:
	
		if arguments['--orphans-only']:
		
			# Remove any orphaned volumes
			volume_orphans(arguments['--apikey'])
			
		else:
		
			# Remove any orphaned volumes
			volume_orphans(arguments['--apikey'])
	
			# Delete any active droplets
			droplet_delete(arguments['--apikey'])
			
	elif arguments['keycheck']:
	
		ssh_key_check(arguments['--apikey'], arguments['--fingerprint'][4:], arguments['--sshkey'])