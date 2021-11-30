#!/usr/bin/env bash

set -euo pipefail

source config.sh

api='https://api.momentum-mod.org/api'

log() {
  echo "$(date -Iseconds) | $*"
}

isAccessTokenExpired() {
  echo "$accessToken" \
  | cut -d '.' -f 2 \
  | base64 -d 2> /dev/null \
  | jq -e '.exp < now' > /dev/null
}

fetchAccessToken() {
  curl 'https://auth.momentum-mod.org/auth/refresh' \
    --silent \
    -X POST \
    -H 'Content-Type: application/json' \
    --data "{\"refreshToken\": \"$refreshToken\"}" \
  | jq -er '.accessToken'
}

fetchRecentActivity() {
  curl "$api/user/activities/followed" \
    --silent \
    -H "Authorization: Bearer $accessToken" \
  | jq \
    --argjson last "$lastActivity" \
    ' .activities[] | select(.id > $last and .type == 4) | .id, .data '
}

sendRunToDiscord() {
  curl "$api/runs/$1?expand=user,map,rank" \
    --silent \
    -H "Authorization: Bearer $accessToken" \
  | jq -e '
    def fmt: strftime("`%H:%M:%S.\(. * 1000 % 1000 + 1000 | tostring[1:])`");
    def field($name; $value): { $name, value: $value | tostring };
    . as $run
    | {}
    | .title = "\($run.user.alias) has improved their personal best on \($run.map.name)"
    | .url = "https://momentum-mod.org/dashboard/runs/\($run.id)"
    | .color = if $run.rank.rank == 1 then 16312092 else 4886754 end
    | .timestamp = $run.createdAt
    | .footer.text = "Momentum Mod"
    | .footer.icon_url = "https://momentum-mod.org/favicon.png"
    | .thumbnail.url = $run.user.avatarURL
    | .fields += [ field("Rank"; "#\($run.rank.rank)") ]
    | .fields += [ field("Run time"; $run.time | fmt) | .inline = true ]
    | .fields += [ field("Run ticks"; $run.ticks) | .inline = true ]
    | { embeds: [ . ] }
  ' \
  | curl "$webhook" \
    --silent \
    -X POST \
    -H 'Content-Type: application/json' \
    --data '@-'
}

lastActivity=$(cat ./last-activity)

# exp is ~60 minutes
accessToken=$(fetchAccessToken)

log "I'm running now. The last activity ID I know of is $lastActivity"

while true; do
  if isAccessTokenExpired; then
    log "I'm renewing my access token which has expired"
    accessToken=$(fetchAccessToken)
  fi

  fetchRecentActivity \
  | while read -r id && read -r data; do 
      log "I got a new activity ($id) about run #$data"
      sendRunToDiscord "$data"

      if (( id > lastActivity )); then
        log "I'm saving that activity ID for later"
        lastActivity=$id
        echo "$lastActivity" > ./last-activity
      fi
    done

  sleep 60
done
