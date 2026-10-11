# Audiobookshelf's hooks for the chassis core (sourced by run-core.sh). The core
# gives: say, env_get/env_set, rand, compose, in_volume, cname, svc_up,
# leave_secret, fresh, now, qr_png_b64, make_backup, record_backup, wait_ready,
# MSG, VAR, APP, LOG, PKG_NAME, PKG_TITLE, IMAGE_UPDATE.
#
# Audiobookshelf's own API does the work: your account is made through its
# first-run /init, and the window then acts through an API key of that account
# ("DSM package" in Audiobookshelf → Settings → API Keys), kept in the
# root-only settings file. Your password is never stored. If the key is
# removed in Audiobookshelf, the package makes itself a new one with a
# short-lived token signed by the server's own secret.
#
# Library folders are shared folders mounted at their own paths into the
# container, in fixed places (four for audiobooks, read-only; four for
# podcasts, writable) that compose.yaml reads from .env.

ABS=""
ABS_REPO=advplyr/audiobookshelf
ABS_PINNED=ghcr.io/advplyr/audiobookshelf:2.37.1
PLACES="BOOKS_1 BOOKS_2 BOOKS_3 BOOKS_4 PODCASTS_1 PODCASTS_2 PODCASTS_3 PODCASTS_4"

app_validate() {   # key value → 0 if the value has the key's shape
  case "$1" in
    ADMIN_USER|NUSER) [[ "$2" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$ ]] ;;
    BOOKS_DIR_B64|PODCASTS_DIR_B64|LIB_DIR_B64) [[ "$2" =~ ^[A-Za-z0-9_-]+$ ]] && (( ${#2} <= 700 )) ;;
    LIB_NAME_B64) [[ "$2" =~ ^[A-Za-z0-9_-]+$ ]] && (( ${#2} <= 400 )) ;;
    LIB_ID|USER_ID) [[ "$2" =~ ^[A-Za-z0-9_-]{4,64}$ ]] ;;
    LIB_TYPE) [[ "$2" =~ ^(book|podcast)$ ]] ;;
    ROLE)     [[ "$2" =~ ^(user|admin)$ ]] ;;
    FULL)     [[ "$2" =~ ^[01]$ ]] ;;
    *) return 1 ;;
  esac
}

# ------------------------------------------------------------ small helpers
b64d() { local s=${1//-/+}; s=${s//_//}; while (( ${#s} % 4 )); do s="$s="; done; printf '%s' "$s" | base64 -d 2>/dev/null; }
b64url() { base64 -w0 | tr '+/' '-_' | tr -d '='; }
env_set_q() { local v=${2//\\/\\\\}; v=${v//\"/\\\"}; v=${v//\$/\$\$}; env_set "$1" "\"$v\""; }
env_get_q() { local v; v=$(env_get "$1"); v=${v#\"}; v=${v%\"}; v=${v//\$\$/\$}; v=${v//\\\"/\"}; printf '%s' "${v//\\\\/\\}"; }
abs_url() { echo "http://127.0.0.1:$(env_get HTTP_PORT)"; }
strong_password() { echo "$(rand 5)-$(rand 5)-$(rand 5)-$(rand 5)"; }
is_synology() { [[ -f /etc.defaults/VERSION ]]; }

# A folder the package may mount: an absolute path, nothing odd in it; on a Synology a shared
# folder on a volume (never one of DSM's own @ folders, never this package's own share).
path_ok() {
  local p=$1
  local bad='[[:cntrl:]$"\`,]'
  [[ "$p" == /?* && "$p" != */ && "$p" != *..* && "$p" != *//* && ${#p} -le 300 && ! "$p" =~ $bad ]] || return 1
  if is_synology; then [[ "$p" =~ ^/volume(USB)?[0-9]+(-[0-9]+)?/[^@/][^/]* && ! "$p" =~ ^/volume(USB)?[0-9]+(-[0-9]+)?/$PKG_NAME(/|$) ]] || return 1; fi
  return 0
}
# Is it there? Asked of Docker, which sees the NAS's own folders. --mount, not -v: -v would quietly create it.
folder_there() { docker run --rm --mount "type=bind,source=$1,target=/m,readonly" --entrypoint sh "$PKG_NAME-setup:local" -c 'test -d /m' >/dev/null 2>&1; }

# ------------------------------------------------------------ talking to Audiobookshelf
abs_api() {   # method path [json] → body (HTTP code in ABS_CODE), with the package's API key
  local key out; key=$(env_get ABS_KEY); [[ -n "$key" ]] || { ABS_CODE=0; return 1; }
  out=$(curl -s --max-time 30 -X "$1" "$(abs_url)/api/$2" -H "Authorization: Bearer $key" -H 'Content-Type: application/json' ${3:+--data-binary "$3"} -w '\n%{http_code}' 2>/dev/null)
  ABS_CODE=${out##*$'\n'}; out=${out%$'\n'*}
  printf '%s' "$out"; [[ "$ABS_CODE" =~ ^2 ]]
}
abs_status() { curl -s --max-time 10 "$(abs_url)/status" 2>/dev/null; }   # {serverVersion, isInit, …}, no sign-in needed
abs_sql() {   # SQL on stdin → rows, read-only from the database (the volume is mounted rw only so SQLite can check its journal)
  in_volume config rw -- 'sqlite3 -readonly -separator "|" /vol/absdatabase.sqlite' 2>/dev/null
}
mint_token() {   # → a five-minute token for the main (root) account, signed with the server's own secret, as Audiobookshelf signs its own
  local secret row uid uname h p
  secret=$(abs_sql <<< "SELECT json_extract(value, '\$.tokenSecret') FROM settings WHERE key = 'server-settings';")
  row=$(abs_sql <<< "SELECT id || '|' || username FROM users WHERE type = 'root' LIMIT 1;")
  uid=${row%%|*}; uname=${row#*|}
  [[ -n "$secret" && "$uid" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  h=$(printf '%s' '{"alg":"HS256","typ":"JWT"}' | b64url)
  p=$(jq -cn --arg u "$uid" --arg n "$uname" --arg j "$(rand 24)" --argjson t "$(now)" '{userId: $u, username: $n, jti: $j, type: "access", iat: $t, exp: ($t + 300)}' | b64url)
  printf '%s.%s.%s' "$h" "$p" "$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -hmac "$secret" -binary | b64url)"
}
make_key() {   # token-of-root → a new API key for the package in .env (Audiobookshelf → Settings → API Keys → "DSM package")
  local tok=$1 uid out key
  uid=$(curl -s --max-time 15 "$(abs_url)/api/me" -H "Authorization: Bearer $tok" 2>/dev/null | jq -r '.id // empty' 2>/dev/null)
  [[ -n "$uid" ]] || return 1
  out=$(curl -s --max-time 15 -X POST "$(abs_url)/api/api-keys" -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' \
        -d "$(jq -cn --arg u "$uid" '{name: "DSM package", userId: $u, isActive: true}')" 2>/dev/null)
  key=$(jq -r '.apiKey.apiKey // empty' <<< "$out" 2>/dev/null)
  [[ "$key" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  env_set ABS_KEY "$key"
}
repair_key() {   # the package's key stopped working (removed or turned off in Audiobookshelf): make another
  local tok; tok=$(mint_token) || { say "✗ the package's key for Audiobookshelf doesn't work, and a new one couldn't be made (the database wasn't readable)"; return 1; }
  if make_key "$tok" && abs_api GET me >/dev/null; then say "the package's key for Audiobookshelf had stopped working (removed or turned off there) — a new one was made (\"DSM package\" in Settings → API Keys)"; return 0; fi
  say "✗ the package's key for Audiobookshelf doesn't work, and Audiobookshelf didn't accept a new one"; return 1
}

# ------------------------------------------------------------ library folders: the places in compose.yaml
place_kind() { echo "${1%_*}"; }                                # BOOKS_2 → BOOKS
place_of() {   # path kind → the place whose folder already holds it (the same folder or a parent); podcasts need a writable one
  local p s; for s in $PLACES; do p=$(env_get_q "$s"); [[ -n "$p" ]] || continue
    [[ "$1" == "$p" || "$1" == "$p"/* ]] || continue
    [[ "$2" == PODCASTS && "$s" == BOOKS_* ]] && continue
    echo "$s"; return 0; done; return 1
}
free_place() { local s; for s in $PLACES; do [[ "$(place_kind "$s")" == "$1" && -z "$(env_get_q "$s")" ]] && { echo "$s"; return 0; }; done; return 1; }
mount_srcs() {   # every place: its folder if it's there, else the empty placeholder → 0 when something changed
  local s p want changed=1
  mkdir -p "$APP/no-folder"
  for s in $PLACES; do p=$(env_get_q "$s"); want=""
    [[ -n "$p" ]] && path_ok "$p" && folder_there "$p" && want=$p
    [[ "$(env_get_q "${s}_SRC")" == "$want" ]] && continue
    if [[ -n "$want" ]]; then env_set_q "${s}_SRC" "$want"; env_set_q "${s}_DST" "$want"
    else env_set "${s}_SRC" ""; env_set "${s}_DST" ""; [[ -n "$p" ]] && say "the library folder $p isn't there — Audiobookshelf sees it as empty until it is"; fi
    changed=0
  done
  return $changed
}
places_json() {
  local s p out="[]"
  for s in $PLACES; do p=$(env_get_q "$s"); [[ -n "$p" ]] || continue
    out=$(jq -c --arg s "$s" --arg k "$(place_kind "$s")" --arg p "$p" --argjson t "$([[ -n "$(env_get_q "${s}_SRC")" ]] && echo true || echo false)" '. + [{place: $s, kind: ($k | ascii_downcase), path: $p, there: $t}]' <<< "$out"); done
  echo "$out"
}
restart_for_folders() { compose up -d >> "$LOG" 2>&1 && wait_ready 180; }
new_library() {   # name kind(book|podcast) path → id; Audiobookshelf starts reading it
  local out id
  out=$(abs_api POST libraries "$(jq -cn --arg n "$1" --arg t "$2" --arg p "$3" '{name: $n, mediaType: $t, icon: (if $t == "podcast" then "podcast" else "audiobookshelf" end), folders: [{fullPath: $p}]}')") \
    || { MSG="Audiobookshelf didn't add the library (HTTP $ABS_CODE): $(head -c 160 <<< "$out")"; return 1; }
  id=$(jq -r '.id // empty' <<< "$out"); [[ -n "$id" ]] || { MSG="Audiobookshelf didn't say which library it made."; return 1; }
  abs_api POST "libraries/$id/scan" >/dev/null || true
  echo "$id"
}
first_libraries() {   # the folders from the install wizard, once there's a key — unless Audiobookshelf has libraries already
  [[ -f "$VAR/.first-libraries" ]] || return 0
  local n p; n=$(abs_api GET libraries | jq '.libraries | length' 2>/dev/null) || return 0
  if [[ "$n" == 0 ]]; then
    p=$(env_get_q BOOKS_1); [[ -n "$p" ]] && new_library Audiobooks book "$p" >/dev/null && say "the Audiobooks library reads $p$([[ -z "$(env_get_q BOOKS_1_SRC)" ]] && echo " (once it's there)")"
    p=$(env_get_q PODCASTS_1); [[ -n "$p" ]] && new_library Podcasts podcast "$p" >/dev/null && say "the Podcasts library reads $p$([[ -z "$(env_get_q PODCASTS_1_SRC)" ]] && echo " (once it's there)")"
  fi
  rm -f "$VAR/.first-libraries"
}

# ------------------------------------------------------------ lifecycle hooks
app_first_env() {
  local b p
  env_set ABS_IMAGE "$ABS_PINNED"; env_set ADMIN_USER "${ADMIN_USER:-admin}"
  b=$(b64d "${BOOKS_DIR_B64:-}"); p=$(b64d "${PODCASTS_DIR_B64:-}")
  if [[ -n "$b" ]]; then if path_ok "$b"; then env_set_q BOOKS_1 "$b"; else say "✗ the audiobooks folder from the wizard ($b) isn't a shared folder the package can use — add a library in the window instead"; fi; fi
  if [[ -n "$p" ]]; then
    if ! path_ok "$p"; then say "✗ the podcasts folder from the wizard ($p) isn't a shared folder the package can use — add a library in the window instead"
    elif [[ "$p" == "$b" ]]; then say "✗ the podcasts folder is the audiobooks folder — podcasts need a folder of their own (add one in the window)"
    else env_set_q PODCASTS_1 "$p"; fi
  fi
  touch "$VAR/.needs-root" "$VAR/.first-libraries"
}
app_load_env() { ABS=$(cname server); }
app_before_up() {
  mount_srcs || true
  qr_png_b64 "$(env_get APP_URL)" > "$VAR/qr.b64.tmp" && mv "$VAR/qr.b64.tmp" "$VAR/qr.b64"; env_get APP_URL > "$VAR/qr.url"
}
app_health() { [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$(abs_url)/healthcheck" 2>/dev/null)" == 200 ]]; }
app_version() { abs_status | jq -r '.serverVersion // empty' 2>/dev/null | tr -cd '0-9A-Za-z.-' | head -c 30; }
app_after_up() { make_root 60; }
make_root() {   # [tries] — the first time: your account (Audiobookshelf's /init), the package's key, the wizard's libraries
  [[ -f "$VAR/.needs-root" ]] || return 0
  local i pw user code tok
  for i in $(seq 1 "${1:-1}"); do app_health && break; sleep 2; done
  app_health || { say "Audiobookshelf isn't answering yet — your account is made when it does"; return 0; }
  user=$(env_get ADMIN_USER)
  if [[ "$(abs_status | jq -r '.isInit' 2>/dev/null)" == false ]]; then
    pw=$(strong_password)
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 -X POST "$(abs_url)/init" -H 'Content-Type: application/json' \
           -d "$(jq -cn --arg u "$user" --arg p "$pw" '{newRoot: {username: $u, password: $p}}')" 2>/dev/null) || true
    [[ "$code" == 200 ]] || { say "✗ Audiobookshelf didn't make your account (HTTP $code) — trying again shortly"; return 0; }
    leave_secret "Audiobookshelf ($user)" "$pw" users
    say "first start: your Audiobookshelf account $user was made (the server's main account); the password is shown once in the window"
    tok=$(curl -s --max-time 15 -X POST "$(abs_url)/login" -H 'Content-Type: application/json' -d "$(jq -cn --arg u "$user" --arg p "$pw" '{username: $u, password: $p}')" 2>/dev/null | jq -r '.user.accessToken // empty' 2>/dev/null) || true
    [[ -n "$tok" ]] && make_key "$tok" || say "the package's key couldn't be made by signing in — trying with the server's own secret"
  elif [[ -z "$(env_get ABS_KEY)" ]]; then say "Audiobookshelf already has its main account — the package didn't make one"; fi
  abs_api GET me >/dev/null || repair_key || { say "✗ the package can't reach Audiobookshelf's API yet — the window can't manage libraries and users until it can; trying again shortly"; return 0; }
  rm -f "$VAR/.needs-root"
  first_libraries
  say "the package's key for Audiobookshelf works (\"DSM package\" in Settings → API Keys)"
}

# ------------------------------------------------------------ what the window shows
progress_json() {   # per user: books and episodes in progress and finished, and when they last listened (Audiobookshelf's users API), kept a minute
  local f="$VAR/.abs-progress.json" id out="{}" u
  if fresh "$f" 60 && [[ -s "$f" ]]; then cat "$f"; return 0; fi
  for id in $(jq -r '.[]?.id' <<< "$1" 2>/dev/null); do u=$(abs_api GET "users/$id") || continue
    out=$(jq -c --arg id "$id" --argjson u "$u" '. + {($id): {listening: ([$u.mediaProgress[]? | select((.isFinished | not) and (.currentTime // 0) > 0)] | length),
      finished: ([$u.mediaProgress[]? | select(.isFinished)] | length), last_listened: (([$u.mediaProgress[]?.lastUpdate // 0] | max // 0) / 1000 | floor)}}' <<< "$out" 2>/dev/null || echo "$out")
  done
  printf '%s' "$out" > "$f"; echo "$out"
}
app_status() {
  svc_up server || { echo '{"up": false}'; return 0; }
  local users libs tasks key_ok=true progress url
  users=$(abs_api GET users) || key_ok=false
  [[ "$key_ok" == true ]] && users=$(jq -c '[.users[] | {id, user: .username, type, active: .isActive, last_seen: ((.lastSeen // 0) / 1000 | floor)}]' <<< "$users" 2>/dev/null) || users="[]"
  libs=$(abs_api GET "libraries?include=stats" | jq -c '[.libraries[] | {id, name, type: .mediaType, folders: [.folders[].fullPath], items: (.stats.totalItems // 0),
      files: (.stats.numAudioFiles // 0), size: (.stats.totalSize // 0), hours: (((.stats.totalDuration // 0) / 360 | floor) / 10), last_scan: ((.lastScan // 0) / 1000 | floor)}]' 2>/dev/null) || libs="[]"
  tasks=$(abs_api GET tasks | jq -c '[.tasks[] | select(.action == "library-scan" and (.isFinished | not)) | .data.libraryId]' 2>/dev/null) || tasks="[]"
  progress=$([[ "$key_ok" == true ]] && progress_json "$users" || echo "{}"); [[ "$progress" == \{* ]] || progress="{}"
  url=$(env_get APP_URL)
  [[ -s "$VAR/qr.b64" && "$(cat "$VAR/qr.url" 2>/dev/null)" == "$url" ]] || { qr_png_b64 "$url" > "$VAR/qr.b64"; printf '%s\n' "$url" > "$VAR/qr.url"; }
  jq -n -c --argjson users "${users:-[]}" --argjson libs "${libs:-[]}" --argjson scanning "${tasks:-[]}" --argjson places "$(places_json)" --argjson progress "$progress" \
     --arg url "$url" --arg admin "$(env_get ADMIN_USER)" --arg qr "$(cat "$VAR/qr.b64" 2>/dev/null)" --argjson key_ok "$key_ok" --arg image "$(env_get ABS_IMAGE)" \
     'def place($f): ([$places[] | select(.path as $pp | $f == $pp or ($f | startswith($pp + "/")))] | sort_by(-(.path | length)) | .[0]);
      {up: true, url: $url, qr: $qr, admin_user: $admin, key_ok: $key_ok, image: $image, places: $places,
       users: [$users[] | . + ($progress[.id] // {listening: null, finished: null, last_listened: 0})],
       libraries: [$libs[] | . + {scanning: (.id as $i | $scanning | index($i) != null),
                                  folders: [.folders[] | {path: ., state: (place(.) as $p | if $p == null then "outside" elif $p.there then "there" else "waiting" end)}]}],
       free: {book: ([$places[] | select(.kind == "books")] | 4 - length), podcast: ([$places[] | select(.kind == "podcasts")] | 4 - length)}}' 2>/dev/null || echo '{"up": true}'
}

# ------------------------------------------------------------ updates: the image is a pinned release on GitHub's registry
abs_check_image() {   # the core checks Docker Hub only: this checks ghcr.io, and Audiobookshelf's newest release
  local img repo tag token remote local_digest latest newer=false
  img=$(env_get ABS_IMAGE); [[ "$img" == ghcr.io/*:* ]] || return 0
  repo=${img#ghcr.io/}; repo=${repo%:*}; tag=${img##*:}
  token=$(curl -fsS --max-time 15 "https://ghcr.io/token?scope=repository:$repo:pull" 2>/dev/null | jq -r '.token // ""' 2>/dev/null)
  remote=$(curl -fsSI --max-time 15 -H "Authorization: Bearer $token" -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json" \
    "https://ghcr.io/v2/$repo/manifests/$tag" 2>/dev/null | tr -d '\r' | awk -F': ' 'tolower($1) == "docker-content-digest" {print $2}' | grep -oE 'sha256:[0-9a-f]{64}' | head -1)
  local_digest=$(docker image inspect "$img" --format '{{range .RepoDigests}}{{.}} {{end}}' 2>/dev/null | grep -oE 'sha256:[0-9a-f]{64}' | head -1)
  latest=$(curl -fsS --max-time 15 "https://api.github.com/repos/$ABS_REPO/releases/latest" 2>/dev/null | jq -r '.tag_name // ""' 2>/dev/null | sed -E 's/^v//')
  [[ "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || latest=""
  [[ -n "$latest" && "$tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$latest" != "$tag" && "$(printf '%s\n%s\n' "$tag" "$latest" | sort -V | tail -1)" == "$latest" ]] && newer=true
  if [[ -z "$remote" && -z "$latest" ]]; then IMAGE_UPDATE='{"error":"the registry could not be reached"}'
  else IMAGE_UPDATE=$(jq -n -c --arg img "$img" --arg remote "$remote" --arg local "$local_digest" --argjson at "$(now)" --arg latest "$latest" --argjson newer "$newer" \
    '{checked: $at, image: $img, available: ($local != "" and $remote != "" and $remote != $local), remote: $remote[:19], local: $local[:19], release: $latest, release_newer: $newer}'); fi
  touch "$VAR/.image-check"
}
app_check_updates() { abs_check_image; }
abs_update() {   # to Audiobookshelf's newest release: a backup first, then the new image
  local latest old new
  latest=$(jq -r 'if .release_newer == true then .release else "" end' <<< "$IMAGE_UPDATE" 2>/dev/null)
  [[ "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { MSG="There's no newer Audiobookshelf release to install — look for updates first."; return 1; }
  old=$(env_get ABS_IMAGE); new="ghcr.io/$ABS_REPO:$latest"
  say "updating Audiobookshelf to $latest — first, a backup"
  make_backup pre-update || { MSG="Couldn't back up first, so Audiobookshelf wasn't updated."; return 1; }
  record_backup true "$MADE"
  say "pulling $new"; docker pull "$new" 2>&1 | grep -vE '^\s*$' | tail -n 20 | tee -a "$LOG" >/dev/null || true
  docker image inspect "$new" >/dev/null 2>&1 || { MSG="Audiobookshelf $latest couldn't be downloaded; it stays as it was."; return 1; }
  env_set ABS_IMAGE "$new"
  compose up -d --remove-orphans 2>&1 | tee -a "$LOG" >/dev/null || { MSG="Audiobookshelf $latest didn't start — see the log. The state from before is in $MADE."; return 1; }
  wait_ready 900 || { MSG="Audiobookshelf was updated to $latest but hasn't answered yet — see the log. The state from before is in $MADE."; return 1; }
  [[ "$old" != "$new" && "$old" == ghcr.io/$ABS_REPO:* ]] && docker image rm "$old" >> "$LOG" 2>&1 && say "removed the old image $old"
  abs_check_image
  MSG="Audiobookshelf is updated to $(app_version). The state from before is in $MADE."
}

# ------------------------------------------------------------ the loop, settings, storage, backups, report
app_tick() {
  make_root 1
  svc_up server || return 0
  # Library folders that came or went (a shared folder made later, a USB disk): Audiobookshelf is restarted with them.
  if ! fresh "$VAR/.folders-check" 600; then touch "$VAR/.folders-check"
    if mount_srcs; then say "a library folder came or went — Audiobookshelf restarts with what's there"
      restart_for_folders && { abs_api GET libraries | jq -r '.libraries[].id' 2>/dev/null | while read -r id; do abs_api POST "libraries/$id/scan" >/dev/null; done; true; }; fi
  fi
  # The package's key removed or turned off in Audiobookshelf: a new one (at most every ten minutes).
  if [[ ! -f "$VAR/.needs-root" ]] && ! fresh "$VAR/.key-check" 600; then touch "$VAR/.key-check"
    abs_api GET me >/dev/null || { [[ "$ABS_CODE" == 401 || "$ABS_CODE" == 403 ]] && repair_key; }; fi
  # The core's image check is for Docker Hub; after its own update it leaves an error the ghcr.io check replaces.
  if jq -e '.error // "" | test("Docker Hub")' <<< "$IMAGE_UPDATE" >/dev/null 2>&1 && ! fresh "$VAR/.image-check" 600; then abs_check_image; fi
  return 0
}
app_after_settings() { qr_png_b64 "$(env_get APP_URL)" > "$VAR/qr.b64"; env_get APP_URL > "$VAR/qr.url"; }
app_logs() { :; }
app_storage() {
  local db meta
  db=$(in_volume config ro -- 'du -sm /vol/absdatabase.sqlite 2>/dev/null | cut -f1; true' </dev/null 2>/dev/null | tr -cd '0-9')
  meta=$(in_volume metadata ro -- 'cd /vol && for d in items authors cache backups logs; do [ -e "$d" ] && printf "%s\t%s\n" "$d" "$(du -sm "$d" 2>/dev/null | cut -f1)"; done; true' </dev/null 2>/dev/null \
    | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {key: .[0], value: (.[1] | tonumber? // 0)}) | from_entries' 2>/dev/null)
  jq -n -c --arg db "${db:-0}" --argjson meta "${meta:-"{}"}" '$meta + {database: ($db | tonumber? // 0)}' 2>/dev/null || echo "{}"
}
# A backup: a consistent copy of the database (sqlite3 .backup — everyone's listening progress,
# users, settings) with the rest of /config, and /metadata without what Audiobookshelf makes again
# (cache, streams, logs) and without its own backups (Settings → Backups), which would double it.
app_backup() {   # dir
  in_volume config rw -- 'set -e; mkdir -p /tmp/b; cd /vol; tar -cf - --exclude=./absdatabase.sqlite --exclude="./absdatabase.sqlite-*" . | tar -C /tmp/b -xf -
    sqlite3 -readonly absdatabase.sqlite ".backup /tmp/b/absdatabase.sqlite"; tar -C /tmp/b -czf - .' > "$1/config.tar.gz" 2>>"$LOG" </dev/null \
    && grep -q 'absdatabase.sqlite' < <(tar -tzf "$1/config.tar.gz" 2>/dev/null) || { say "✗ Audiobookshelf's database didn't copy"; return 1; }   # not a pipe: under pipefail, grep -q stopping early fails tar
  in_volume metadata ro -- 'tar -C /vol -czf - --exclude="./cache/*" --exclude="./streams/*" --exclude="./logs/*" --exclude="./backups/*" --exclude="./tmp/*" .' > "$1/metadata.tar.gz" 2>>"$LOG" </dev/null \
    && tar -tzf "$1/metadata.tar.gz" >/dev/null 2>&1 || { say "✗ Audiobookshelf's metadata didn't tar"; return 1; }
}
app_restore() {   # dir — the core has stopped the containers
  local s v
  [[ -s "$1/config.tar.gz" && -s "$1/metadata.tar.gz" ]] || { MSG="That backup has no Audiobookshelf database or metadata."; return 1; }
  in_volume config rw -- 'find /vol -mindepth 1 -delete && tar -C /vol -xzf -' < "$1/config.tar.gz" 2>>"$LOG" || { MSG="The database didn't unpack."; return 1; }
  # Audiobookshelf's own backups (Settings → Backups) aren't in the package's; they stay as they are.
  in_volume metadata rw -- 'find /vol -mindepth 1 -maxdepth 1 ! -name backups -exec rm -rf {} + && tar -C /vol -xzf -' < "$1/metadata.tar.gz" 2>>"$LOG" || { MSG="The metadata didn't unpack."; return 1; }
  # The library folders as they were then, so the restored libraries find theirs.
  if [[ -f "$1/env" ]]; then for s in $PLACES; do
      v=$(grep -E "^$s=" "$1/env" | tail -1 | cut -d= -f2-); v=${v#\"}; v=${v%\"}; v=${v//\$\$/\$}
      if [[ -z "$v" ]] || path_ok "$v"; then [[ -n "$v" ]] && env_set_q "$s" "$v" || env_set "$s" ""; fi
    done; fi
  mount_srcs || true
  rm -f "$VAR/.abs-progress.json" "$VAR/.needs-root" "$VAR/.first-libraries"
}
app_report() {
  echo "== libraries"; abs_api GET "libraries?include=stats" | jq -r '.libraries[]? | "\(.name)  \(.mediaType)  \(.stats.totalItems // 0) items, \(.stats.numAudioFiles // 0) audio files  folders: \([.folders[].fullPath] | join(", "))  last scan \(if .lastScan then (.lastScan / 1000 | floor | todate) else "never" end)"' 2>/dev/null
  echo; echo "== library folder places"; places_json | jq -r '.[] | "\(.place)  \(.path)  \(if .there then "mounted" else "MISSING" end)"'
  echo; echo "== users"; abs_api GET users | jq -r '.users[]? | .username + "  " + .type + (if .isActive then "" else "  (inactive)" end)' 2>/dev/null
  echo; echo "== the package's key: $(abs_api GET me >/dev/null && echo works || echo "doesn't work (HTTP $ABS_CODE)"); image $(env_get ABS_IMAGE)"
  :
}

# ------------------------------------------------------------ the window's actions
app_act() {   # action (request vars are set)
  local pw out user kind name dir place id lib was
  case "$1" in
    libadd)
      name=$(b64d "${LIB_NAME_B64:-}"); dir=$(b64d "${LIB_DIR_B64:-}"); kind=$([[ "${LIB_TYPE:-book}" == podcast ]] && echo PODCASTS || echo BOOKS)
      [[ -n "$name" && ${#name} -le 64 && "$name" =~ ^[^[:cntrl:]]+$ ]] || { MSG="A library needs a name (up to 64 characters)."; return 1; }
      path_ok "$dir" || { MSG="$dir isn't a folder the package can use: a shared folder on this Synology, like /volume1/audiobooks."; return 1; }
      folder_there "$dir" || { MSG="There's no folder $dir on this Synology."; return 1; }
      abs_api GET libraries | jq -e --arg p "$dir" '[.libraries[].folders[].fullPath] | index($p)' >/dev/null 2>&1 && { MSG="$dir is already one of Audiobookshelf's library folders."; return 1; }
      if ! place=$(place_of "$dir" "$kind"); then
        for place in $PLACES; do [[ "$(env_get_q "$place")" == "$dir" ]] && { MSG="$dir is already an audiobook folder (read-only); podcasts need a folder of their own, since new episodes are downloaded into it."; return 1; }; done
        place=$(free_place "$kind") || { MSG="All four places for $([[ "$kind" == BOOKS ]] && echo audiobook || echo podcast) folders are in use — remove a library first, or add the folder to an existing library in Audiobookshelf."; return 1; }
        env_set_q "$place" "$dir"; mount_srcs || true
        say "mounting $dir for Audiobookshelf ($([[ "$kind" == BOOKS ]] && echo read-only || echo writable))"
        restart_for_folders || { MSG="Audiobookshelf didn't come back with the new folder — see the log."; return 1; }
      fi
      id=$(new_library "$name" "${LIB_TYPE:-book}" "$dir") || return 1
      rm -f "$VAR/.abs-progress.json"
      MSG="The library $name reads $dir$([[ "$kind" == BOOKS ]] && echo " (read-only)") — Audiobookshelf is looking through it now." ;;
    libdel)
      lib=$(abs_api GET "libraries/$LIB_ID") || { MSG="There's no such library."; return 1; }
      name=$(jq -r .name <<< "$lib")
      abs_api DELETE "libraries/$LIB_ID" >/dev/null || { MSG="Audiobookshelf didn't remove it (HTTP $ABS_CODE)."; return 1; }
      # Places no library uses any more are let go (unmounted).
      out=$(abs_api GET libraries | jq -c '[.libraries[].folders[].fullPath]' 2>/dev/null) || out=""
      was=0
      if [[ "$out" == \[* ]]; then for place in $PLACES; do dir=$(env_get_q "$place"); [[ -n "$dir" ]] || continue
          jq -e --arg p "$dir" 'any(.[]; . == $p or startswith($p + "/"))' <<< "$out" >/dev/null && continue
          env_set "$place" ""; env_set "${place}_SRC" ""; env_set "${place}_DST" ""; say "$dir is no longer mounted for Audiobookshelf"; was=1; done; fi
      (( was )) && { restart_for_folders || { MSG="$name was removed, but Audiobookshelf didn't come back — see the log."; return 1; }; }
      MSG="The library $name was removed from Audiobookshelf. Its files are untouched." ;;
    scan)
      if [[ -n "${LIB_ID:-}" ]]; then
        lib=$(abs_api GET "libraries/$LIB_ID") || { MSG="There's no such library."; return 1; }
        abs_api POST "libraries/$LIB_ID/scan$([[ "${FULL:-0}" == 1 ]] && echo "?force=1")" >/dev/null || { MSG="The scan didn't start (HTTP $ABS_CODE)."; return 1; }
        MSG="Audiobookshelf is $([[ "${FULL:-0}" == 1 ]] && echo "reading all of $(jq -r .name <<< "$lib") again" || echo "looking through $(jq -r .name <<< "$lib") for new and changed files")."
      else
        out=$(abs_api GET libraries | jq -r '.libraries[].id' 2>/dev/null); [[ -n "$out" ]] || { MSG="There are no libraries to scan yet."; return 1; }
        for id in $out; do abs_api POST "libraries/$id/scan" >/dev/null || { MSG="The scan didn't start (HTTP $ABS_CODE)."; return 1; }; done
        MSG="Audiobookshelf is looking through every library for new and changed files."
      fi ;;
    useradd)
      pw=$(strong_password)
      out=$(abs_api POST users "$(jq -cn --arg u "$NUSER" --arg p "$pw" --arg t "${ROLE:-user}" '{username: $u, password: $p, type: $t, isActive: true}')") \
        || { MSG="Audiobookshelf didn't add $NUSER (HTTP $ABS_CODE): $(head -c 160 <<< "$out")"; return 1; }
      leave_secret "Audiobookshelf ($NUSER)" "$pw" users; rm -f "$VAR/.abs-progress.json"; MSG="$NUSER was added — the password is shown once, below." ;;
    userpw|setadmin|userdel)
      user=$(abs_api GET "users/$USER_ID") || { MSG="There's no such user."; return 1; }
      name=$(jq -r .username <<< "$user")
      if [[ "$(jq -r .type <<< "$user")" == root && "$1" != userpw ]]; then MSG="$name is the server's main account (yours) — it stays an administrator and can't be removed."; return 1; fi
      case "$1" in
        userpw) pw=$(strong_password)
          abs_api PATCH "users/$USER_ID" "$(jq -cn --arg p "$pw" '{password: $p}')" >/dev/null || { MSG="Audiobookshelf didn't take it (HTTP $ABS_CODE)."; return 1; }
          leave_secret "Audiobookshelf ($name)" "$pw" users; MSG="A new password for $name is ready — it's shown once, below. Their phone apps sign in again with it." ;;
        setadmin)
          abs_api PATCH "users/$USER_ID" "$(jq -cn --arg t "${ROLE:-user}" '($t == "admin") as $a | {type: $t, permissions: {download: true, update: $a, delete: false, upload: $a, createEreader: $a, accessExplicitContent: $a}}')" >/dev/null \
            || { MSG="Audiobookshelf didn't take it (HTTP $ABS_CODE)."; return 1; }
          MSG="$name is $([[ "${ROLE:-user}" == admin ]] && echo "now an administrator" || echo "no longer an administrator")." ;;
        userdel)
          abs_api DELETE "users/$USER_ID" >/dev/null || { MSG="Audiobookshelf didn't remove it (HTTP $ABS_CODE)."; return 1; }
          rm -f "$VAR/.abs-progress.json"; MSG="$name was removed, with their listening progress and playlists." ;;
      esac ;;
    absupdate) abs_update || return 1 ;;
    *) MSG="Unknown request."; return 1 ;;
  esac
}
