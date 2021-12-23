#!/usr/bin/env bash

set -euo pipefail

source config.sh

api='https://api.momentum-mod.org/api'

log() {
  echo "$(date -Iseconds) | $*"
}

api() {
  curl "$api/$1" \
    --fail --silent --show-error \
    -H "Authorization: Bearer $accessToken" \
    "${@:2}"
  return
}

isAccessTokenExpired() {
  echo "$accessToken" \
  | jq -Re 'split(".")[1] | @base64d | fromjson.exp < now' > /dev/null
  return
}

fetchAccessToken() {
  curl 'https://auth.momentum-mod.org/auth/refresh' \
    --fail --silent --show-error \
    -X POST \
    -H 'Content-Type: application/json' \
    --data "{\"refreshToken\": \"$refreshToken\"}" \
  | jq -er '.accessToken'
  return
}

fetchRecentActivity() {
  cat <(api "user/activities/followed") <(api "users/$uid/activities") \
  | jq \
    --argjson last "$(cat ./last-activity)" \
    ' .activities[] | select(.id > $last and .type == 4) | .id, .data '
  return
}

sendRunToDiscord() {
  run=$(api "runs/$1?expand=user,rank")

  map=$(api "maps/$(jq '.mapID' <<< "$run")?expand=images,stats")

  jq -ne \
    --argjson run "$run" \
    --argjson map "$map" \
    --argjson rand "$RANDOM" \
    --arg funny "$(cat ./funny-message)" \
    '
      def fmt: strftime("`%H:%M:%S.\(. * 1000 % 1000 + 1000 | tostring[1:])`");
      def field($name; $value): { $name, value: $value | tostring };
      def colors: [15673641, 8948357, 15658732, 9101876, 7512015, 11370408];
      def rankedColor: colors[0 | until(. + 1 >= (colors | length) or ($run.rank.rank / $map.stats.totalUniqueCompletions) >= 1 / pow(2; .); . + 1)];
      {}
      | .title = "\($run.user.alias) achieved a \(if $run.rank.rank == 1 then "world record" else "personal best" end) on \($map.name)"
      | if $rand % 1000 == 0 then .description = $funny else . end
      | .url = "https://momentum-mod.org/dashboard/runs/\($run.id)"
      | .color = if $run.rank.rank == 1 then 16559934 else rankedColor end
      | .timestamp = $run.createdAt
      | .footer.text = "Momentum Mod"
      | .footer.icon_url = "https://momentum-mod.org/favicon.png"
      | .thumbnail.url = $run.user.avatarURL
      | .image.url = $map.images[$rand % ($map.images | length)].large
      | .fields += [ field("Rank"; "#\($run.rank.rank) / \($map.stats.totalUniqueCompletions)") ]
      | .fields += [ field("Run time"; $run.time | fmt) | .inline = true ]
      | .fields += [ field("Run ticks"; $run.ticks) | .inline = true ]
      | { embeds: [ . ] }
    ' \
  | curl "$webhook" \
    --fail --silent --show-error \
    -X POST \
    -H 'Content-Type: application/json' \
    --data '@-'
  return
}

# exp is ~60 minutes
accessToken=$(fetchAccessToken)

log "I'm running now. The last activity ID I know of is $(cat ./last-activity)"

while true; do
  if isAccessTokenExpired; then
    log "I'm renewing my access token which has expired"
    accessToken=$(fetchAccessToken)
  fi

  fetchRecentActivity \
  | while read -r id && read -r data; do 
      log "I got a new activity ($id) about run #$data"
      sendRunToDiscord "$data"

      lastActivity=$(cat ./last-activity)
      if (( id > lastActivity )); then
        log "I'm saving that activity ID for later"
        echo "$id" > ./last-activity
      fi
    done

  sleep 60
done
