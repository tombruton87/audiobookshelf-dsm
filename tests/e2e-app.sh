# Audiobookshelf's steps for the chassis harness (chassis/tests/e2e.sh <appdir> act).
# The library folders hold a few one-second MP3s made with Audiobookshelf's own ffmpeg.
BOOKS=$E2E/books; PODS=$E2E/podcasts; BOOKS2=$E2E/more-books
ABS_IMG=ghcr.io/advplyr/audiobookshelf:2.37.1
make_audio() {   # dir/relative/file.mp3 title album artist
  docker run --rm -v "$(dirname "$1"):/m" --entrypoint sh "$ABS_IMG" -c "ffmpeg -loglevel error -f lavfi -i sine=frequency=440:duration=1 -metadata title=\"$2\" -metadata album=\"$3\" -metadata artist=\"$4\" -y \"/m/$(basename "$1")\"" >/dev/null 2>&1
}
make_book() { mkdir -p "$1/$2/$3"; make_audio "$1/$2/$3/01.mp3" "$3, part 1" "$3" "$2"; make_audio "$1/$2/$3/02.mp3" "$3, part 2" "$3" "$2"; }
as_root() { docker run --rm -v "$E2E:$E2E" alpine sh -c "$1"; }   # the folders' files are root's (made in containers)
b64u() { printf '%s' "$1" | base64 -w0 | tr -d '=' | tr '+/' '-_'; }
app_e2e_answers() {
  [[ -d "$BOOKS/Ann Author/First Book" ]] || { make_book "$BOOKS" "Ann Author" "First Book"; make_book "$BOOKS" "Ben Writer" "Second Book"; }
  [[ -d "$PODS/Garden Hour" ]] || { mkdir -p "$PODS/Garden Hour"; make_audio "$PODS/Garden Hour/episode-1.mp3" "Episode 1" "Garden Hour" "Garden Hour"; make_audio "$PODS/Garden Hour/episode-2.mp3" "Episode 2" "Garden Hour" "Garden Hour"; }
  # ABS_E2E_LATER=1: the audiobooks folder isn't there at the first start (no shared folder made yet).
  [[ "${ABS_E2E_LATER:-0}" == 1 ]] && { printf "ADMIN_USER='ada'\nBOOKS_DIR_B64='%s'\n" "$(b64u "$E2E/later-books")"; return; }
  printf "ADMIN_USER='ada'\nBOOKS_DIR_B64='%s'\nPODCASTS_DIR_B64='%s'\n" "$(b64u "$BOOKS")" "$(b64u "$PODS")"
}
wait_for() { local i; for i in $(seq 1 "$2"); do touch "$VAR/watching"; jq -e "$1" "$VAR/status.json" >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }
secret() { local s; s=$(jq -r 'select(.kind == "users") | .password' "$VAR/secret.json" 2>/dev/null); rm -f "$VAR/secret.json"; printf '%s' "$s"; }
login_ok() { [[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$URL/login" -H 'Content-Type: application/json' -d "$(jq -cn --arg u "$1" --arg p "$2" '{username: $u, password: $p}')")" == 200 ]]; }
key() { docker run --rm -v "$APP:/s" alpine sh -c 'grep "^ABS_KEY=" /s/.env | cut -d= -f2-'; }
api() { curl -s -X "$1" "$URL/api/$2" -H "Authorization: Bearer $(key)" -H 'Content-Type: application/json' ${3:+-d "$3"}; }
lib_id() { jq -r --arg n "$1" '.app.libraries[] | select(.name == $n) | .id' "$VAR/status.json"; }
progress_of() { api GET "me/progress/$1" | jq -r '.currentTime // empty' | cut -d. -f1; }
app_e2e_act() {
  local fail=0 pw pw2 id bid sid item bk rel
  URL="http://127.0.0.1:$PORT"
  log "audiobookshelf"
  echo "  (healthcheck: HTTP $(curl -s -o /dev/null -w '%{http_code}' "$URL/healthcheck"), version $(jq -r .version "$VAR/status.json"))"
  # Your account: made at the first start, shown once.
  pw=$(secret)
  [[ ${#pw} -ge 20 ]] && echo "  ok   a one-time password was left for the window" || { echo "  FAIL no password secret"; fail=1; }
  login_ok ada "$pw" && echo "  ok   your account (ada, the server's main account) signs in" || { echo "  FAIL sign-in"; fail=1; }
  wait_for '.app.key_ok == true and (.app.users | map(select(.user == "ada" and .type == "root")) | length == 1)' 30 && echo "  ok   the package's API key works; ada is root" || { echo "  FAIL key/users: $(jq -c '{k: .app.key_ok, u: .app.users}' "$VAR/status.json")"; fail=1; }
  [[ "$(api GET api-keys | jq -r '[.apiKeys[].name] | index("DSM package") != null')" == true ]] && echo "  ok   …listed in Audiobookshelf as \"DSM package\"" || { echo "  FAIL key not listed"; fail=1; }
  # The wizard's folders became libraries and were read.
  wait_for '(.app.libraries | map(select(.name == "Audiobooks" and .type == "book" and .items == 2 and .files == 4)) | length == 1) and (.app.libraries | map(select(.name == "Podcasts" and .type == "podcast" and .items == 1 and .files == 2)) | length == 1)' 90 \
    && echo "  ok   libraries from the wizard: Audiobooks (2 books, 4 files), Podcasts (1 show, 2 episodes)" || { echo "  FAIL libraries: $(jq -c '[.app.libraries[] | {name, type, items, files, folders}]' "$VAR/status.json")"; fail=1; }
  jq -e '[.app.libraries[].folders[].state] | all(. == "there")' "$VAR/status.json" >/dev/null && echo "  ok   both folders mounted at their own paths" || { echo "  FAIL folder states"; fail=1; }
  docker exec audiobookshelf-server sh -c "touch '$BOOKS/x' 2>/dev/null" && { echo "  FAIL the audiobooks folder is writable"; fail=1; } || echo "  ok   the audiobooks folder is read-only to Audiobookshelf"
  docker exec audiobookshelf-server sh -c "touch '$PODS/x' && rm '$PODS/x'" && echo "  ok   the podcasts folder is writable (for new episodes)" || { echo "  FAIL podcasts not writable"; fail=1; }
  jq -e '.app.qr | length > 100' "$VAR/status.json" >/dev/null && echo "  ok   a QR code of the address" || { echo "  FAIL no qr"; fail=1; }
  # A new book: a scan finds it.
  make_book "$BOOKS" "Cara Teller" "Third Book"; id=$(lib_id Audiobooks)
  request "ACTION='scan'" "LIB_ID='$id'" "FULL='0'" || fail=1
  wait_for '.app.libraries[] | select(.name == "Audiobooks") | .items == 3' 60 && echo "  ok   a scan found the new book: 3 books" || { echo "  FAIL rescan: $(jq -c '[.app.libraries[] | {name, items}]' "$VAR/status.json")"; fail=1; }
  request "ACTION='scan'" "FULL='1'" || fail=1
  # Another library, in a folder new to Audiobookshelf: a new place, mounted read-only.
  make_book "$BOOKS2" "Dee Narrator" "Fourth Book"
  request "ACTION='libadd'" "LIB_NAME_B64='$(b64u 'Kids & "Family"')'" "LIB_TYPE='book'" "LIB_DIR_B64='$(b64u "$BOOKS2")'" || fail=1
  wait_for '.app.libraries[] | select(.name == "Kids & \"Family\"") | .items == 1' 60 && echo "  ok   a library added from the window, name intact: 1 book" || { echo "  FAIL libadd: $(jq -c '[.app.libraries[] | {name, items}]' "$VAR/status.json")"; fail=1; }
  docker exec audiobookshelf-server sh -c "touch '$BOOKS2/x' 2>/dev/null" && { echo "  FAIL the new folder is writable"; fail=1; } || echo "  ok   …read-only"
  # A folder that goes away and comes back (a USB disk, a renamed share): placeholder, then the folder again.
  as_root "mv '$BOOKS2' '$BOOKS2.away'"; rm -f "$VAR/.folders-check"
  wait_for '.app.libraries[] | select(.name == "Kids & \"Family\"") | .folders[0].state == "waiting"' 90 && echo "  ok   a missing folder shows as waiting (and wasn't created)" || { echo "  FAIL waiting: $(jq -c '.app.libraries' "$VAR/status.json")"; fail=1; }
  [[ ! -e "$BOOKS2" ]] || { echo "  FAIL $BOOKS2 was created"; fail=1; }
  as_root "mv '$BOOKS2.away' '$BOOKS2'"; rm -f "$VAR/.folders-check"
  wait_for '.app.libraries[] | select(.name == "Kids & \"Family\"") | .folders[0].state == "there" and .items == 1' 120 && echo "  ok   …and when it's back, Audiobookshelf reads it again" || { echo "  FAIL back: $(jq -c '.app.libraries' "$VAR/status.json")"; fail=1; }
  # Refused: a folder that isn't there (and isn't created), and podcasts in the read-only audiobooks folder.
  request "ACTION='libadd'" "LIB_NAME_B64='$(b64u Nope)'" "LIB_TYPE='book'" "LIB_DIR_B64='$(b64u /volume9/nope)'" >/dev/null && { echo "  FAIL accepted a missing folder"; fail=1; } || echo "  ok   a folder that isn't there is refused"
  [[ ! -e /volume9/nope ]] && echo "  ok   …and isn't created by asking" || { echo "  FAIL /volume9/nope was created"; fail=1; }
  request "ACTION='libadd'" "LIB_NAME_B64='$(b64u Pods)'" "LIB_TYPE='podcast'" "LIB_DIR_B64='$(b64u "$BOOKS2")'" >/dev/null && { echo "  FAIL a library folder twice"; fail=1; } || echo "  ok   a folder that is already a library's is refused"
  request "ACTION='libdel'" "LIB_ID='$(lib_id 'Kids & "Family"')'" || fail=1
  wait_for '(.app.libraries | length == 2) and (.app.places | length == 2)' 30 && ! docker inspect audiobookshelf-server --format '{{range .Mounts}}{{.Source}} {{end}}' | grep -q "$BOOKS2" \
    && echo "  ok   removing the library unmounts its folder (the files stay)" || { echo "  FAIL libdel: $(jq -c '.app.places' "$VAR/status.json")"; fail=1; }
  [[ -f "$BOOKS2/Dee Narrator/Fourth Book/01.mp3" ]] || { echo "  FAIL files removed"; fail=1; }
  # Users.
  request "ACTION='useradd'" "NUSER='sam'" "ROLE='user'" || fail=1; pw2=$(secret)
  login_ok sam "$pw2" && echo "  ok   sam can listen" || { echo "  FAIL sam"; fail=1; }
  wait_for '.app.users | map(.user) | index("sam")' 20; sid=$(jq -r '.app.users[] | select(.user == "sam") | .id' "$VAR/status.json")
  request "ACTION='setadmin'" "USER_ID='$sid'" "ROLE='admin'" || fail=1
  wait_for '.app.users[] | select(.user == "sam") | .type == "admin"' 20 && echo "  ok   sam made an administrator" || { echo "  FAIL setadmin"; fail=1; }
  request "ACTION='setadmin'" "USER_ID='$sid'" "ROLE='user'" || fail=1
  wait_for '.app.users[] | select(.user == "sam") | .type == "user"' 20 && echo "  ok   …and a listener again" || { echo "  FAIL setadmin back"; fail=1; }
  request "ACTION='userpw'" "USER_ID='$sid'" || fail=1; pw=$(secret)
  login_ok sam "$pw" && ! login_ok sam "$pw2" && echo "  ok   new password works, old doesn't" || { echo "  FAIL password change"; fail=1; }
  local rid; rid=$(jq -r '.app.users[] | select(.user == "ada") | .id' "$VAR/status.json")
  request "ACTION='userdel'" "USER_ID='$rid'" >/dev/null && { echo "  FAIL removed the main account"; fail=1; } || echo "  ok   the main account can't be removed"
  request "ACTION='userdel'" "USER_ID='$sid'" || fail=1
  login_ok sam "$pw" && { echo "  FAIL removed user still signs in"; fail=1; } || echo "  ok   sam removed"
  # Listening progress survives a backup and restore; Audiobookshelf's own backups are left alone.
  item=$(api GET "libraries/$(lib_id Audiobooks)/items?limit=1" | jq -r '.results[0].id')
  api PATCH "me/progress/$item" '{"currentTime": 600, "duration": 3600, "progress": 0.25, "isFinished": false}' >/dev/null
  [[ "$(progress_of "$item")" == 600 ]] && echo "  ok   listening progress set (10 minutes in)" || { echo "  FAIL progress: $(api GET "me/progress/$item")"; fail=1; }
  api POST backups >/dev/null; bk=$(api GET backups | jq '.backups | length')
  request "ACTION='backup'" || fail=1; local name; name=$(jq -r '.backups[0].name' "$VAR/status.json")
  grep -q 'absdatabase.sqlite' < <(tar -xOf "$APP/backups/$name" --wildcards '*/config.tar.gz' | tar -tzf -) && echo "  ok   the backup has the database" || { echo "  FAIL backup contents"; fail=1; }
  api PATCH "me/progress/$item" '{"currentTime": 1500, "duration": 3600, "progress": 0.6}' >/dev/null
  request "ACTION='restore'" "BACKUP='$name'" || fail=1
  [[ "$(progress_of "$item")" == 600 ]] && echo "  ok   restored: the progress is back to 10 minutes" || { echo "  FAIL restored progress: $(progress_of "$item")"; fail=1; }
  [[ "$(api GET backups | jq '.backups | length')" == "$bk" && "$bk" -ge 1 ]] && echo "  ok   Audiobookshelf's own backups were kept ($bk)" || { echo "  FAIL own backups: $bk → $(api GET backups | jq '.backups | length')"; fail=1; }
  wait_for '.app.key_ok == true and (.app.libraries | length == 2)' 30 && echo "  ok   after the restore: the key works, both libraries" || { echo "  FAIL after restore"; fail=1; }
  # The package's key removed in Audiobookshelf: the package makes itself a new one.
  id=$(api GET api-keys | jq -r '.apiKeys[] | select(.name == "DSM package") | .id' | head -1)
  api DELETE "api-keys/$id" >/dev/null; rm -f "$VAR/.key-check"
  local i; for i in $(seq 1 90); do touch "$VAR/watching"; grep -q "a new one was made" "$VAR/package.log" && break; sleep 1; done
  grep -q "a new one was made" "$VAR/package.log" && wait_for '.app.key_ok == true' 30 && echo "  ok   a removed key is replaced (signed with the server's own secret)" || { echo "  FAIL key repair"; tail -n 5 "$VAR/package.log"; fail=1; }
  # Updates: the pinned release against Audiobookshelf's newest.
  jq -e '.image_update.release != null and .image_update.release != "" and (.image_update.error | not)' "$VAR/status.json" >/dev/null && echo "  ok   the image is checked on ghcr.io: newest release $(jq -r .image_update.release "$VAR/status.json")" || { echo "  FAIL image check: $(jq -c .image_update "$VAR/status.json")"; fail=1; }
  rel=$(jq -r '.image_update.release' "$VAR/status.json")
  if [[ "$rel" == "${ABS_IMG##*:}" ]]; then
    request "ACTION='absupdate'" >/dev/null && { echo "  FAIL updated with nothing newer"; fail=1; } || echo "  ok   nothing newer: no update"
    # As if the package had pinned an older release: the window offers the newest, and updating keeps everything.
    docker run --rm -v "$APP:/s" alpine sed -i "s|^ABS_IMAGE=.*|ABS_IMAGE=ghcr.io/advplyr/audiobookshelf:2.37.0|" /s/.env
    request "ACTION='check'" || fail=1
    jq -e '.image_update.release_newer == true' "$VAR/status.json" >/dev/null && echo "  ok   an older pin is offered $rel" || { echo "  FAIL release_newer: $(jq -c .image_update "$VAR/status.json")"; fail=1; }
    request "ACTION='absupdate'" || fail=1
    [[ "$(docker run --rm -v "$APP:/s" alpine sh -c 'grep "^ABS_IMAGE=" /s/.env | cut -d= -f2-')" == "$ABS_IMG" && "$(progress_of "$item")" == 600 ]] && echo "  ok   updated to $rel, progress intact" || { echo "  FAIL absupdate"; fail=1; }
  fi
  (( fail )) && { echo "  audiobookshelf: something FAILED"; return 1; }; echo "  audiobookshelf: all passed"
}
