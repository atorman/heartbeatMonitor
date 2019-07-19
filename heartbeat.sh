#!/bin/bash

#Bash shell script for DIY Salesforce monitoring with real-time SMS
#
#@atorman, July 2014
#
#This script is designed to monitor salesforce and send real-time SMS messages when an error is encountered. 
#It works in conjunction with one minute CRON job intervals which will make 1440 API Calls per day. This will count against your daily limit. 
#
#As a result, you should evaluate the frequency with which you want to run this script and decrease the CRON interval or add a loop in the shell script to get more granular than a minute.
#
#This script uses salesforce.com, sparkfun.com, and sendhub.com
#Optionally, Keen.io and Twilio is also included as a substitute
#for sparkfun.com and sendhub.com
#
#view results in real-time at: http://bit.ly/rtheartbeat

#--------------------configurations below-------------------
#everywhere there is a '<changeme>' you will need to enter your own configuration data

username=${username:-<changeme>} #username: e.g. user@company.com
password=${password:-<changeme>} #password e.g. password
instance=${instance:-<changeme>} #pod instance - production/sandbox/other
clientid=${clientid:-<changeme>} #salesforce connected app client id
clientsecret=${clientsecret:-<changeme>} #salesforce connected app client secret
version=${version:-<changeme>} #salesforce API version
sobject=${sobject:-<changeme>} #salesforce sobject to query
sparkfunid=${sparkfunid:-<changeme>} #sparkfun public key id
sparkfunkey=${sparkfunkey:-<changeme>} #sparkfun private key id
twilioid=${twilioid:-<changeme>} #twilio id
twilioTo=${twilioTo:-<changeme>} #twilio to sms phone number
twilioFrom=${twillioFrom:-<changeme>} #twilio from sms phone number
twiliotoken=${twiliotoken:-<changeme>} #twilio authorization token
sendhubid=${sendhubid:-<changeme>} #sendhub contactid [required]
sendhubkey=${sendhubkey:-<changeme>} #sendhub API key
sendhubuser=${sendhubuser:-<changeme>} #sendhub username 
keenproject=${keenproject:-<changeme>} #keen.io project id
keencollection=${keencollection:-<changeme>} #keen.io collection
keenkey=${keenkey:-<changeme>} #keen.io write API key
testMode=${testMode:-false} #use to test - change to false for production

#---------------------------start script---------------------------

#get the oauth2 response and store it (create your own connected app to get a new client id and secret - https://na1.salesforce.com/help/pdfs/en/salesforce_identity_implementation_guide.pdf)
response=`curl https://${instance}.salesforce.com/services/oauth2/token -d "grant_type=password" -d "client_id=${clientid}" -d "client_secret=${clientsecret}" -d "username=${username}" -d "password=${password}"`

#for debugging purposes: uncomment the following line to check response json
#echo "response: {$response}"

#test regular expression for a connected app access token
if [[ "$response" =~ (\"access_token\"):\"(.+)\" ]]; then
	
	#use some BASH_REMATCH magic to pull the access token substring out and store it - see http://robots.thoughtbot.com/the-unix-shells-humble-if for examples
	access_token="${BASH_REMATCH[2]}"
	
	#for debugging purposes: uncomment the following line to check token results
	#echo "token: ${access_token}"

	#echo "testmode: ${testMode}"
	if [[ "$testMode" == true ]]; then

		#testMode - will fail if count doesn't explicity define a field e.g. Id
		objectCount=`curl -X GET https://${instance}.salesforce.com/services/data/v${version}/query?q=Select+count\(\)+From+${sobject} -H "Authorization: Bearer ${access_token}"`
		#echo "objectCount: ${objectCount}"
	else

		#Query for sobject count - LoginEvent available in API v 31.0 for select orgs
		objectCount=`curl -X GET https://${instance}.salesforce.com/services/data/v${version}/query?q=Select+count\(Id\)+From+${sobject} -H "Authorization: Bearer ${access_token}"` 

		#for debugging purposes: uncomment the following line to check query results
		#echo "objectCount: ${objectCount}"
	fi

	if [[ "$objectCount" =~ (\"expr0\"):([:0-9:]+) ]]; then

		newCount="${BASH_REMATCH[2]}"
		#for debugging purposes: uncomment the following line to check BASH_REMATCH results
		#echo "newCount: ${newCount}"

		#Insert success data into data.sparkfun.com using Phant (https://data.sparkfun.com/)
		curl -X POST "http://data.sparkfun.com/input/${sparkfunid}?private_key=${sparkfunkey}&count={$newCount}&errMsg=null&success=1"

		#Insert success data into keen.io
		curl -X POST "https://api.keen.io/3.0/projects/${keenproject}/events/${keencollection}?api_key=${keenkey}" -H "Content-Type: application/json" -d '{"count":'${newCount}',"errMsg":"null","success":1}'

	#if it's not successful, capture error message
	else
	
		if [[ "$objectCount" =~ (\"message\"):(\"[A-Z,a-z,0-9].+\") ]]; then
			
			#store error message using BASH_REMATCH
			errMsg="${BASH_REMATCH[2]}" 

			#for debugging purposes: uncomment the following line to check error message results
			#echo "errMsg: ${errMsg}"

			#store just the error id (e.g. 1269525282-126416(-773985176))
			gack=( $(echo "${errMsg}" | sed 's/[^0-9()-]//g' ) )

			#for debugging purposes: uncomment the following line to check gack message results
			#echo "gack: ${gack}"

			#for debugging purposes: uncomment the following line to check when something goes wrong with the API call
			#echo "something went terribly wrong while counting ${sobject} :("
			
			#Insert error data into data.sparkfun.com
			curl -X POST "http://data.sparkfun.com/input/${sparkfunid}?private_key=${sparkfunkey}&count=null&errMsg={$gack}&success=0"

			#Insert error data into keen.io
			#TODO: InvalidJSONError when passing ${gack} - e.g. 306428624-222412(-1321472047); hardcoding gack for now
			curl -X POST "https://api.keen.io/3.0/projects/${keenproject}/events/${keencollection}?api_key=${keenkey}" -H "Content-Type: application/json" -d '{"count":"null","errMsg": "gack","success":0}'

			#SMS error notification using Sendhub - http://apidocs.sendhub.com/GettingStarted.html#sending-a-message
			curl -H "Content-Type: application/json" -X POST "https://api.sendhub.com/v1/messages/?username=${sendhubuser}\&api_key=${sendhubkey}" --data '{"contacts" : ['${sendhubid}'],"text" : "'${sobject}' Query Failure '${gack}'"}'


			#SMS error notification using Twilio - http://www.twilio.com/sms/api
			curl -X POST "https://api.twilio.com/2010-04-01/Accounts/${twilioid}/Messages.json" \
				--data-urlencode "To=${twilioTo}"  \
				--data-urlencode "From=+${twilioFrom}"  \
				--data-urlencode "Body=${sobjec} Query Failure: ${errMsg}" \
				-u ${twiliotoken}
		fi
	fi			
else
	#for debugging purposes: uncomment the following line to check when something goes completely wrong with the access token during authentication
	#echo "something went terribly wrong authenticating :("
	
	#Insert error data into data.sparkfun.com
	curl -X POST "http://data.sparkfun.com/input/${sparkfunid}?private_key=${sparkfunkey}&count=null&errMsg=accessTokenFailure&success=0"

	#Insert error data into keen.io
		curl -X POST "https://api.keen.io/3.0/projects/${keenproject}/events/${keencollection}?api_key=${keenkey}" -H "Content-Type: application/json" -d '{"count":"null","errMsg":"accessTokenFailure","success":0}'
fi
