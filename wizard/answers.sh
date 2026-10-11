    echo "ADMIN_USER='$(printf '%s' "${wizard_admin_user:-admin}" | tr -cd 'A-Za-z0-9._-' | head -c 32)'"
    echo "BOOKS_DIR_B64='$(printf '%s' "${wizard_books_dir:-}" | base64 | tr -d '\n=' | tr '+/' '-_')'"
    echo "PODCASTS_DIR_B64='$(printf '%s' "${wizard_podcasts_dir:-}" | base64 | tr -d '\n=' | tr '+/' '-_')'"
