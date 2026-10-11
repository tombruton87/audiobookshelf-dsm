# Audiobookshelf's actions, validated by the CGI before they become a request file.
# Free text (a library's name, a folder) travels base64url, so nothing in it reaches the setup container as anything but data.
b64u() { printf '%s' "$1" | base64 -w0 | tr '+/' '-_' | tr -d '='; }
abs_id() { [[ "$1" =~ ^[A-Za-z0-9_-]{4,64}$ ]]; }
app_cgi_post() {   # action body → sets $lines, or error
  local a=$1 body=$2 u id role v name dir type bad='[[:cntrl:]$"\`,]'
  case "$a" in
    absupdate) lines="ACTION='absupdate'" ;;
    libadd) name=$(decode "$(param name "$body")"); dir=$(decode "$(param dir "$body")"); type=$(param type "$body")
      [[ -n "$name" && ${#name} -le 64 && "$name" =~ ^[^[:cntrl:]]+$ ]] || error "400 Bad Request" "Give the library a name, up to 64 characters."
      [[ "$type" =~ ^(book|podcast)$ ]] || error "400 Bad Request" "Audiobooks or podcasts."
      [[ "$dir" =~ ^/volume(USB)?[0-9]+(-[0-9]+)?/[^@/] && "$dir" != */ && "$dir" != *..* && "$dir" != *//* && ${#dir} -le 300 && ! "$dir" =~ $bad ]] \
        || error "400 Bad Request" "A shared folder on the NAS, like /volume1/audiobooks."
      lines="ACTION='libadd'
LIB_NAME_B64='$(b64u "$name")'
LIB_TYPE='$type'
LIB_DIR_B64='$(b64u "$dir")'" ;;
    libdel) id=$(param id "$body"); abs_id "$id" || error "400 Bad Request" "Pick a library."; lines="ACTION='libdel'
LIB_ID='$id'" ;;
    scan) id=$(param id "$body"); v=$(param full "$body"); [[ "${v:-0}" =~ ^[01]$ ]] || error "400 Bad Request" "Quick or full."
      [[ -z "$id" ]] || abs_id "$id" || error "400 Bad Request" "Pick a library."
      lines="ACTION='scan'
FULL='${v:-0}'"; [[ -n "$id" ]] && lines="$lines
LIB_ID='$id'" ;;
    useradd) u=$(param user "$body"); role=$(param role "$body")
      [[ "$u" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$ ]] || error "400 Bad Request" "A username: letters, digits, dot, dash, underscore — up to 32."
      [[ "$role" =~ ^(user|admin)$ ]] || error "400 Bad Request" "Listener or administrator."
      lines="ACTION='useradd'
NUSER='$u'
ROLE='$role'" ;;
    userpw|setadmin|userdel) id=$(param id "$body"); abs_id "$id" || error "400 Bad Request" "Pick a user."
      lines="ACTION='$a'
USER_ID='$id'"
      if [[ "$a" == setadmin ]]; then role=$(param role "$body"); [[ "$role" =~ ^(user|admin)$ ]] || error "400 Bad Request" "Listener or administrator."; lines="$lines
ROLE='$role'"; fi ;;
  esac
}
