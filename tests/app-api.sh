# Audiobookshelf's CGI checks (sourced by chassis/tests/test-api.sh).
expect "libadd good" 202 "$(post "$me" libadd 'action=libadd&name=H%C3%B6rb%C3%BCcher+%26+more&type=book&dir=%2Fvolume1%2FMy%20Books')"
grep -q "^LIB_DIR_B64='L3ZvbHVtZTEvTXkgQm9va3M'$" "$CHASSIS_VAR/request" && grep -q "^LIB_NAME_B64='SMO2cmLDvGNoZXIgJiBtb3Jl'$" "$CHASSIS_VAR/request" && grep -q "^LIB_TYPE='book'$" "$CHASSIS_VAR/request" \
  && { (( pass++ )); echo "  ok   a library's name and folder travel base64url"; } || { (( fail++ )); echo "  FAIL libadd request: $(tr '\n' ' ' < "$CHASSIS_VAR/request")"; }; rm -f "$CHASSIS_VAR/request"
expect "libadd relative folder" 400 "$(post "$me" libadd 'action=libadd&name=x&type=book&dir=books')"
expect "libadd outside the volumes" 400 "$(post "$me" libadd 'action=libadd&name=x&type=podcast&dir=%2Fetc')"
expect "libadd DSM's own folders" 400 "$(post "$me" libadd 'action=libadd&name=x&type=podcast&dir=%2Fvolume1%2F%40docker')"
expect "libadd dots" 400 "$(post "$me" libadd 'action=libadd&name=x&type=book&dir=%2Fvolume1%2F..%2Fetc')"
expect "libadd a quote" 400 "$(post "$me" libadd 'action=libadd&name=x&type=book&dir=%2Fvolume1%2Fa%22b')"
expect "libadd a dollar" 400 "$(post "$me" libadd 'action=libadd&name=x&type=book&dir=%2Fvolume1%2F%24(id)')"
expect "libadd bad type" 400 "$(post "$me" libadd 'action=libadd&name=x&type=music&dir=%2Fvolume1%2Fbooks')"
expect "libadd no name" 400 "$(post "$me" libadd 'action=libadd&name=&type=book&dir=%2Fvolume1%2Fbooks')"
expect "libdel good" 202 "$(post "$me" libdel 'action=libdel&id=2f1c0b9e-5a1b-4c3d-9e8f-0a1b2c3d4e5f')"; rm -f "$CHASSIS_VAR/request"
expect "libdel bad id" 400 "$(post "$me" libdel "action=libdel&id=..%2Fx")"
expect "scan all" 202 "$(post "$me" scan 'action=scan&full=0')"; request_is "scan-all request" "ACTION='scan'
FULL='0'
BY='$me'"
expect "scan one, full" 202 "$(post "$me" scan 'action=scan&id=2f1c0b9e-5a1b-4c3d-9e8f-0a1b2c3d4e5f&full=1')"; rm -f "$CHASSIS_VAR/request"
expect "scan bad" 400 "$(post "$me" scan 'action=scan&full=2')"
expect "useradd good" 202 "$(post "$me" useradd 'action=useradd&user=sam&role=user')"; request_is "useradd request" "ACTION='useradd'
NUSER='sam'
ROLE='user'
BY='$me'"
expect "useradd bad name" 400 "$(post "$me" useradd 'action=useradd&user=%24(id)&role=user')"
expect "useradd bad role" 400 "$(post "$me" useradd 'action=useradd&user=sam&role=root')"
expect "setadmin" 202 "$(post "$me" setadmin 'action=setadmin&id=2f1c0b9e-5a1b-4c3d-9e8f-0a1b2c3d4e5f&role=admin')"; rm -f "$CHASSIS_VAR/request"
expect "setadmin to root" 400 "$(post "$me" setadmin 'action=setadmin&id=2f1c0b9e-5a1b-4c3d-9e8f-0a1b2c3d4e5f&role=root')"
expect "userdel bad id" 400 "$(post "$me" userdel "action=userdel&id=a'b")"
expect "absupdate" 202 "$(post "$me" absupdate 'action=absupdate')"; rm -f "$CHASSIS_VAR/request"
expect "viewer libadd → 403" 403 "$(CHASSIS_ADMINS=no-such-group post "$me" libadd 'action=libadd&name=x&type=book&dir=%2Fvolume1%2Fbooks')"
